import 'dart:async';
import 'dart:math';

import 'package:breezze_audio_contracts/audio_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/recent_store.dart';
import '../../core/auth/auth_session.dart';
import '../../core/audio/playback_source_policy.dart';
import '../../core/database/database_providers.dart';
import '../../core/database/playback_heartbeat_outbox_dao.dart';
import 'playback_session_client.dart';

/// Global PlayerController — spec §51.3, §53.1.
///
/// THE one application-wide playback authority. All screens dispatch
/// commands to it; a screen must never instantiate its own player for
/// catalog playback. Navigation never resets audio (§26.3).
class PlayerController extends Notifier<PlayerState> {
  late final PlaybackStateMachine _machine = PlaybackStateMachine(
    onTransition: (prev, next) {
      state = state.copyWith(playbackState: next);
    },
  );

  late final QueueManager _queue = QueueManager(
    onQueueChanged: () {
      state = state.copyWith(queueVersion: state.queueVersion + 1);
    },
  );

  late final ScrobbleBus _scrobbles = ScrobbleBus();
  final RecentStore _recent = RecentStore();

  AudioEngineAdapter? _engine;
  PlayableSource? _activeSource;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlaybackState>? _engineStateSub;
  int _requestGeneration = 0;
  String? _autoAdvancedTrackId;
  Future<void> _engineOperations = Future<void>.value();
  GaplessLocalQueueEngine? _gaplessEngine;
  List<QueueEntry>? _gaplessEntries;
  int? _gaplessIndex;
  StreamSubscription<int?>? _gaplessIndexSub;

  String? _playbackSessionId;
  PlaybackSessionClient? _activeSessionClient;
  Timer? _heartbeatTimer;
  int _heartbeatSequence = 1;
  String? _pendingHeartbeatEventId;
  bool _heartbeatInFlight = false;
  bool _heartbeatRecoveryInFlight = false;

  PlaybackHeartbeatOutboxDao get _heartbeatOutbox =>
      PlaybackHeartbeatOutboxDao(ref.read(breezzeDatabaseProvider));

  PlaybackSessionClient get _sessionClient =>
      ref.read(playbackSessionClientProvider);

  String _newEventId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void _startHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    if (_playbackSessionId == null) return;
    _heartbeatTimer = Timer.periodic(
      ref.read(playbackHeartbeatIntervalProvider),
      (_) {
        if (state.playbackState == PlaybackState.playing) {
          unawaited(_sendPlaybackHeartbeat());
        }
      },
    );
  }

  void _pauseHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _sendPlaybackHeartbeat() async {
    final sessionId = _playbackSessionId;
    if (sessionId == null ||
        _heartbeatInFlight ||
        state.playbackState != PlaybackState.playing) {
      return;
    }
    _heartbeatInFlight = true;
    final eventId = _pendingHeartbeatEventId ??= _newEventId();
    try {
      final client = _activeSessionClient;
      if (client == null) return;
      final auth = ref.read(authSessionProvider);
      if (auth is AuthSignedIn) {
        // Commit the exact idempotency key and sequence before sending. If
        // the process dies after the server commits but before the response
        // arrives, startup recovery can safely replay the same event.
        await _heartbeatOutbox.save(
          ownerId: auth.userId,
          sessionId: sessionId,
          eventId: eventId,
          sequence: _heartbeatSequence,
        );
      }
      final result = await client.heartbeat(
        sessionId: sessionId,
        eventId: eventId,
        sequence: _heartbeatSequence,
      );
      if (result['accepted'] == true && _playbackSessionId == sessionId) {
        if (auth is AuthSignedIn) {
          await _heartbeatOutbox.remove(sessionId: sessionId, eventId: eventId);
        }
        _pendingHeartbeatEventId = null;
        _heartbeatSequence++;
      }
    } catch (_) {
      // Keep the same event ID and sequence; the next timer tick retries it.
    } finally {
      _heartbeatInFlight = false;
    }
  }

  Future<void> _closePlaybackSession() async {
    _pauseHeartbeatTimer();
    final sessionId = _playbackSessionId;
    final client = _activeSessionClient;
    _playbackSessionId = null;
    _activeSessionClient = null;
    _pendingHeartbeatEventId = null;
    _heartbeatSequence = 1;
    if (sessionId == null) return;
    if (client == null) return;
    try {
      await client.stop(sessionId);
      final auth = ref.read(authSessionProvider);
      if (auth is AuthSignedIn) {
        await _heartbeatOutbox.removeSession(
          ownerId: auth.userId,
          sessionId: sessionId,
        );
      }
    } catch (_) {
      // Keep any pending event durable; startup recovery will replay it and
      // close the session. The server TTL is the final safety net.
    }
  }

  Future<void> _recoverPendingHeartbeats(String ownerId) async {
    if (_heartbeatRecoveryInFlight) return;
    _heartbeatRecoveryInFlight = true;
    try {
      final client = _sessionClient;
      final entries = await _heartbeatOutbox.pending(ownerId: ownerId);
      // A session can have multiple queued heartbeat events. Replay every
      // event in sequence before stopping that session; stopping after the
      // first row would invalidate later events and lose their credit.
      final sessions = <String, List<PlaybackHeartbeatOutboxEntry>>{};
      for (final entry in entries) {
        sessions.putIfAbsent(entry.sessionId, () => []).add(entry);
      }
      for (final session in sessions.entries) {
        final auth = ref.read(authSessionProvider);
        if (auth is! AuthSignedIn || auth.userId != ownerId) return;
        final pendingEvents = session.value
          ..sort((a, b) => a.sequence.compareTo(b.sequence));
        var replayFailed = false;
        for (final entry in pendingEvents) {
          final currentAuth = ref.read(authSessionProvider);
          if (currentAuth is! AuthSignedIn || currentAuth.userId != ownerId) {
            return;
          }
          try {
            // Replay the original key/sequence. The server treats an already
            // committed heartbeat as an acknowledged duplicate.
            final result = await client.heartbeat(
              sessionId: entry.sessionId,
              eventId: entry.eventId,
              sequence: entry.sequence,
            );
            if (result['accepted'] == true) {
              await _heartbeatOutbox.remove(
                sessionId: entry.sessionId,
                eventId: entry.eventId,
              );
            } else {
              replayFailed = true;
            }
          } catch (_) {
            replayFailed = true;
          }
        }
        // Close only after every queued event for this session was replayed.
        // If any event could not be acknowledged, retain its row and let the
        // server TTL expire rather than deleting uncredited retry evidence.
        if (!replayFailed) {
          try {
            await client.stop(session.key);
            await _heartbeatOutbox.removeSession(
              ownerId: ownerId,
              sessionId: session.key,
            );
          } catch (_) {
            // Retain the row for a later authenticated recovery attempt.
          }
        }
      }
    } catch (_) {
      // Local database/network failures must not block normal playback.
    } finally {
      _heartbeatRecoveryInFlight = false;
      final current = ref.read(authSessionProvider);
      if (current is AuthSignedIn && current.userId != ownerId) {
        unawaited(_recoverPendingHeartbeats(current.userId));
      }
    }
  }

  void _adoptPlaybackSession(PlayableSource source) {
    _playbackSessionId = source.sessionId;
    _activeSessionClient = source.sessionId == null ? null : _sessionClient;
    _heartbeatSequence = 1;
    _pendingHeartbeatEventId = null;
  }

  Future<void> _pauseServerSession() async {
    _pauseHeartbeatTimer();
    final sessionId = _playbackSessionId;
    final client = _activeSessionClient;
    if (sessionId == null || client == null) return;
    try {
      await client.pause(sessionId);
    } catch (_) {
      // Do not keep crediting an active server session after an unconfirmed
      // pause. A later resume obtains a fresh authorized session.
      await _closePlaybackSession();
    }
  }

  /// Track info remembered for the current queue, keyed by track id.
  final Map<String, TrackInfo> _trackInfos = {};

  @override
  PlayerState build() {
    ref.listen<AuthState>(authSessionProvider, (previous, next) {
      if (next is AuthSignedIn) {
        unawaited(_recoverPendingHeartbeats(next.userId));
      }
    });
    final auth = ref.read(authSessionProvider);
    if (auth is AuthSignedIn) {
      unawaited(_recoverPendingHeartbeats(auth.userId));
    }
    ref.onDispose(() {
      _requestGeneration++;
      unawaited(_closePlaybackSession());
      final currentTrackId = state.currentTrack?.id;
      if (currentTrackId != null) _scrobbles.onStop(currentTrackId);
      _positionSub?.cancel();
      _engineStateSub?.cancel();
      _gaplessIndexSub?.cancel();
      _disarmNativeGapless();
      _engine = null;
      _activeSource = null;
    });
    return PlayerState.initial();
  }

  QueueManager get queue => _queue;

  void attachEngine(AudioEngineAdapter engine) {
    _requestGeneration++;
    _positionSub?.cancel();
    _engineStateSub?.cancel();
    _gaplessIndexSub?.cancel();
    _disarmNativeGapless();
    _engine = engine;
    if (engine is GaplessLocalQueueEngine) {
      _gaplessIndexSub = engine.currentIndexStream.listen((index) {
        if (index != null && identical(_engine, engine) &&
            identical(_gaplessEngine, engine)) {
          _syncNativeGaplessIndex(index);
        }
      });
    }

    _positionSub = engine.positionStream.listen((pos) {
      if (!identical(_engine, engine)) return;
      state = state.copyWith(position: pos, duration: engine.duration);
      final currentTrackId = state.currentTrack?.id;
      if (currentTrackId != null &&
          state.playbackState == PlaybackState.playing) {
        _scrobbles.onTick(currentTrackId, DateTime.now().toUtc());
      }
    });
    _engineStateSub = engine.engineStateStream.listen((engineState) {
      if (!identical(_engine, engine)) return;

      // Ignore events emitted by the previous media item while the new
      // source is being resolved/prepared.
      if (state.playbackState == PlaybackState.idle ||
          state.playbackState == PlaybackState.resolving ||
          state.playbackState == PlaybackState.loading ||
          state.playbackState == PlaybackState.transitioning) {
        return;
      }
      // Keep the state machine authoritative when the OS pauses audio
      // because of a call, another exclusive session, or route removal.
      if (engineState == PlaybackState.interrupted &&
          _machine.state == PlaybackState.playing) {
        _machine.dispatch(InterruptionDetected());
        unawaited(_pauseServerSession());
        return;
      }
      if (engineState == PlaybackState.paused &&
          _machine.state == PlaybackState.interrupted) {
        _machine.dispatch(InterruptionEnded());
        return;
      }
      if (engineState == PlaybackState.paused &&
          _machine.state == PlaybackState.playing) {
        _machine.dispatch(PausePressed());
        unawaited(_pauseServerSession());
        return;
      }
      state = state.copyWith(playbackState: engineState);
      if (engineState == PlaybackState.ended ||
          engineState == PlaybackState.failed) {
        final currentTrackId = state.currentTrack?.id;
        if (currentTrackId != null) _scrobbles.onStop(currentTrackId);
        // just_audio reports completion on the engine stream. Advance the
        // single app-wide queue here so playback continues without requiring
        // the user to tap Next. The guard prevents duplicate completed events
        // from advancing more than once for the same item.
        if (engineState == PlaybackState.ended ||
            engineState == PlaybackState.failed) {
          unawaited(_closePlaybackSession());
        }
        if (engineState == PlaybackState.ended &&
            currentTrackId != null &&
            _autoAdvancedTrackId != currentTrackId) {
          _autoAdvancedTrackId = currentTrackId;
          unawaited(next());
        }
      }
    });
  }

  void detachEngine() {
    final currentTrackId = state.currentTrack?.id;
    if (currentTrackId != null) _scrobbles.onStop(currentTrackId);
    unawaited(_closePlaybackSession());
    _requestGeneration++;
    _positionSub?.cancel();
    _engineStateSub?.cancel();
    _gaplessIndexSub?.cancel();
    _positionSub = null;
    _engineStateSub = null;
    _gaplessIndexSub = null;
    _disarmNativeGapless();
    _engine = null;
    _activeSource = null;
  }


  // ----------------------------------------------------------------
  // Commands
  // ----------------------------------------------------------------

  Future<void> playTrack({
    required String trackId,
    String? title,
    String? artist,
    String? artworkUrl,
    String? localFilePath,
    Duration duration = Duration.zero,
    List<TrackInfo> queue = const [],
    int startIndex = 0,
    String origin = 'manual',
    String sourceContext = 'Breezze',
  }) async {
    if ((isMetadataOnlyTrackId(trackId) && localFilePath == null) ||
        queue.any((item) => isMetadataOnlyTrackId(item.id) && item.localFilePath == null)) {
      return;
    }
    if (queue.isNotEmpty) {
      final entries = [
        for (var i = 0; i < queue.length; i++)
          QueueEntry(
            entryId: 'qe-$trackId-$i-${DateTime.now().microsecondsSinceEpoch}',
            trackId: queue[i].id,
            origin: origin,
            sourceContext: sourceContext,
            insertedAtMs: DateTime.now().millisecondsSinceEpoch,
            trackVersion: 'v1',
          ),
      ];
      _queue.replaceWith(entries, startIndex: startIndex);
      for (final item in queue) {
        _trackInfos[item.id] = item;
      }
    } else {
      final entry = QueueEntry(
        entryId: 'qe-${DateTime.now().microsecondsSinceEpoch}',
        trackId: trackId,
        origin: origin,
        sourceContext: sourceContext,
        insertedAtMs: DateTime.now().millisecondsSinceEpoch,
        trackVersion: 'v1',
      );
      _queue.replaceWith([entry]);
    }

    final info = queue.isEmpty
        ? TrackInfo(
            id: trackId,
            title: title,
            artist: artist,
            artworkUrl: artworkUrl,
            localFilePath: localFilePath,
            duration: duration,
          )
        : queue[startIndex.clamp(0, queue.length - 1)];

    await _resolveAndPlay(info);
  }

  /// Stops playback and clears the current queue. Used on explicit user stop
  /// and account sign-out so one user's media cannot continue into another
  /// account session.
  Future<void> stop() async {
    final requestId = ++_requestGeneration;
    final engine = _engine;
    final currentTrackId = state.currentTrack?.id;
    if (currentTrackId != null) _scrobbles.onStop(currentTrackId);
    await _closePlaybackSession();
    _queue.clear(keepCurrent: false);
    _trackInfos.clear();
    _activeSource = null;
    _machine.dispatch(StopRequested(requestId: requestId));
    state = state.copyWith(
      clearCurrentTrack: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    if (engine == null) return;
    try {
      await _serializeEngineOperation(() => engine.stop());
    } catch (_) {
      // The logical player is already idle; native stop is best-effort.
    }
  }

  Future<void> pause() async {
    final engine = _engine;
    if (engine == null || state.playbackState != PlaybackState.playing) return;
    _machine.dispatch(PausePressed());
    _pauseHeartbeatTimer();
    try {
      await _serializeEngineOperation(() => engine.pause());
      await _pauseServerSession();
    } catch (_) {
      final currentTrackId = state.currentTrack?.id;
      if (currentTrackId != null) _scrobbles.onStop(currentTrackId);
      await _closePlaybackSession();
      _machine.dispatch(SourceResolutionFailed('PAUSE_FAILED', requestId: _machine.activeRequestId));
    }
  }

  Future<void> resume() async {
    final engine = _engine;
    if (engine == null || state.playbackState != PlaybackState.paused) return;
    final requestId = _requestGeneration;
    bool isCurrentResume() =>
        _isCurrentRequest(requestId) && identical(_engine, engine);
    final activeSource = _activeSource;
    final currentTrack = state.currentTrack;
    if (activeSource != null && activeSource.isExpired && currentTrack != null) {
      // Provider grants are short-lived. Resolve a fresh grant instead of
      // attempting to resume a stale URL after a long pause/background.
      await _resolveAndPlay(currentTrack, initialPosition: state.position);
      return;
    }
    final sessionId = _playbackSessionId;
    if (activeSource?.sessionId != null &&
        sessionId == null &&
        currentTrack != null) {
      await _resolveAndPlay(currentTrack, initialPosition: state.position);
      return;
    }
    if (sessionId != null) {
      try {
        await (_activeSessionClient ?? _sessionClient).resume(sessionId);
      } catch (_) {
        if (isCurrentResume()) await _closePlaybackSession();
        return;
      }
    }
    if (!isCurrentResume()) return;
    _machine.dispatch(PlayPressed());
    try {
      await _serializeEngineOperation(() async {
        if (!isCurrentResume()) return;
        unawaited(engine.play().catchError(
          (Object error, StackTrace stackTrace) {
            if (!isCurrentResume()) return;
            final currentTrackId = state.currentTrack?.id;
            if (currentTrackId != null) _scrobbles.onStop(currentTrackId);
            unawaited(_closePlaybackSession());
            _machine.dispatch(SourceResolutionFailed(
              'RESUME_FAILED',
              requestId: requestId,
            ));
          },
        ));
      });
      if (isCurrentResume() && sessionId != null &&
          state.playbackState == PlaybackState.playing) {
        _startHeartbeatTimer();
      }
    } catch (_) {
      if (!isCurrentResume()) return;
      await _closePlaybackSession();
      final currentTrackId = state.currentTrack?.id;
      if (currentTrackId != null) _scrobbles.onStop(currentTrackId);
      _machine.dispatch(SourceResolutionFailed(
        'RESUME_FAILED',
        requestId: requestId,
      ));
    }
  }

  Future<void> togglePlayPause() async {
    if (state.playbackState == PlaybackState.playing) {
      await pause();
    } else if (state.playbackState == PlaybackState.paused) {
      await resume();
    } else if (state.playbackState == PlaybackState.failed ||
        state.playbackState == PlaybackState.ended) {
      final track = state.currentTrack;
      if (track != null) await _resolveAndPlay(track);
    }
  }

  Future<void> seekTo(Duration position) async {
    final engine = _engine;
    final wasPlaying = state.playbackState == PlaybackState.playing;
    final wasPaused = state.playbackState == PlaybackState.paused;
    if (engine == null || (!wasPlaying && !wasPaused)) return;

    if (wasPlaying) _machine.dispatch(SeekRequested(position));
    try {
      await _serializeEngineOperation(() => engine.seek(position));
      state = state.copyWith(position: position);
      if (wasPlaying) _machine.dispatch(SeekCompleted());
    } catch (_) {
      final currentTrackId = state.currentTrack?.id;
      if (currentTrackId != null) _scrobbles.onStop(currentTrackId);
      _machine.dispatch(SourceResolutionFailed(
        'SEEK_FAILED',
        requestId: _machine.activeRequestId,
      ));
    }
  }

  Future<void> next() async {
    final entry = _queue.advance();
    if (entry == null) return;
    final info = _trackInfoFor(entry.trackId) ?? TrackInfo(id: entry.trackId);
    await _resolveAndPlay(info);
  }

  Future<void> previous() async {
    final entry = _queue.previous();
    if (entry == null) return;
    final info = _trackInfoFor(entry.trackId) ?? TrackInfo(id: entry.trackId);
    await _resolveAndPlay(info);
  }

  Future<bool> _tryDeezerPreview(TrackInfo track, int requestId) async {
    if (!_isCurrentRequest(requestId)) return false;
    if (isDeezerTrackId(track.id)) {
      await _playDeezerPreview(TrackInfo(
        id: 'bz:deezer_preview:${track.id.split(':').last}',
        title: track.title, artist: track.artist, artworkUrl: track.artworkUrl,
      ));
      return true;
    }
    if (!isYouTubeSongId(track.id)) return false;
    final title = track.title;
    final artist = track.artist;
    if (title == null || artist == null || title.isEmpty || artist.isEmpty) return false;
    try {
      final response = await ref.read(authSessionProvider.notifier).api
          .searchDeezer('$title $artist').timeout(const Duration(seconds: 5));
      final id = matchingDeezerPreview(response['value'], title, artist, track.duration);
      if (id == null || !_isCurrentRequest(requestId)) return false;
      await _playDeezerPreview(TrackInfo(id: 'bz:deezer_preview:$id',
          title: title, artist: artist, artworkUrl: track.artworkUrl));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _playDeezerPreview(TrackInfo preview) async {
    if (!isDeezerPreview(preview.id) || _queue.current == null) return;
    _trackInfos[preview.id] = preview;
    _queue.replaceCurrent(QueueEntry(
      entryId: _queue.current!.entryId, trackId: preview.id,
      origin: 'preview', sourceContext: 'Deezer preview',
      insertedAtMs: DateTime.now().millisecondsSinceEpoch, trackVersion: 'v1',
    ));
    await _resolveAndPlay(preview);
  }

  /// Inserts a track directly after the current item.
  void playNext(TrackInfo track, {
    String origin = 'manual',
    String sourceContext = 'Queue',
  }) {
    if (isMetadataOnlyTrackId(track.id) && track.localFilePath == null) return;
    _trackInfos[track.id] = track;
    if (state.currentTrack == null) {
      unawaited(playTrack(
        trackId: track.id,
        title: track.title,
        artist: track.artist,
        artworkUrl: track.artworkUrl,
        duration: track.duration,
        origin: origin,
        sourceContext: sourceContext,
      ));
      return;
    }
    _queue.playNext(QueueEntry(
      entryId: 'qe-${DateTime.now().microsecondsSinceEpoch}',
      trackId: track.id,
      origin: origin,
      sourceContext: sourceContext,
      insertedAtMs: DateTime.now().millisecondsSinceEpoch,
      trackVersion: 'v1',
    ));
  }

  /// Appends a track to the end of the current queue.
  void playLast(TrackInfo track, {
    String origin = 'manual',
    String sourceContext = 'Queue',
  }) {
    if (isMetadataOnlyTrackId(track.id) && track.localFilePath == null) return;
    _trackInfos[track.id] = track;
    if (state.currentTrack == null) {
      unawaited(playTrack(
        trackId: track.id,
        title: track.title,
        artist: track.artist,
        artworkUrl: track.artworkUrl,
        duration: track.duration,
        origin: origin,
        sourceContext: sourceContext,
      ));
      return;
    }
    _queue.playLast(QueueEntry(
      entryId: 'qe-${DateTime.now().microsecondsSinceEpoch}',
      trackId: track.id,
      origin: origin,
      sourceContext: sourceContext,
      insertedAtMs: DateTime.now().millisecondsSinceEpoch,
      trackVersion: 'v1',
    ));
  }

  /// Register a Last.fm/ListenBrainz-compatible scrobbling destination.
  void registerScrobbler(Scrobbler scrobbler) {
    _scrobbles.register(scrobbler);
  }

  void toggleShuffle() => _queue.toggleShuffle();
  void cycleRepeat() => _queue.cycleRepeat();

  TrackInfo? _trackInfoFor(String trackId) => _trackInfos[trackId];

  /// Read-only metadata lookup for queue and playlist surfaces.
  TrackInfo? trackInfoFor(String trackId) => _trackInfoFor(trackId);

  bool _isCurrentRequest(int requestId) =>
      requestId == _requestGeneration && _engine != null;

  /// Serializes native engine mutations. Resolution remains concurrent, but
  /// prepare/play operations execute in order so an older prepare cannot
  /// finish after and overwrite a newer selected track.
  Future<void> _serializeEngineOperation(
      Future<void> Function() operation) {
    final result = _engineOperations.then((_) => operation());
    _engineOperations = result.catchError((_) {});
    return result;
  }

  Future<void> _resolveAndPlay(
    TrackInfo info, {
    Duration initialPosition = Duration.zero,
  }) async {
    if (isMetadataOnlyTrackId(info.id) && info.localFilePath == null) return;
    final requestId = ++_requestGeneration;
    final previousTrackId = state.currentTrack?.id;
    if (previousTrackId != null && previousTrackId != info.id) {
      _scrobbles.onStop(previousTrackId);
    }
    _autoAdvancedTrackId = null;
    _trackInfos[info.id] = info;
    state = state.copyWith(
      currentTrack: info,
      position: initialPosition,
      duration: info.duration,
    );
    _machine.dispatch(StartRequested(info.id, requestId: requestId));

    try {
      // Detach the old session immediately. Source lookup and stopping the
      // previous item can proceed together. The engine queue orders prepare
      // after pause, including when two selections arrive back to back.
      unawaited(_closePlaybackSession());
      _activeSource = null;
      if (previousTrackId != null) {
        unawaited(_serializeEngineOperation(() async {
          if (_isCurrentRequest(requestId)) await _engine?.pause();
        }).catchError((Object _) {}));
      }
      final source = info.localFilePath != null
          ? PlayableSource(
              trackId: info.id,
              streamUrl: info.localFilePath!,
              expiresAtUtc: DateTime.utc(9999),
              isLocal: true,
            )
          : await ref.read(playbackResolverProvider).resolve(info);
      if (!_isCurrentRequest(requestId)) {
        if (source?.sessionId != null) {
          try { await _sessionClient.stop(source!.sessionId!); } catch (_) {}
        }
        return;
      }

      if (source == null) {
        if (await _tryDeezerPreview(info, requestId) || !_isCurrentRequest(requestId)) return;
        _activeSource = null;
        _machine.dispatch(SourceResolutionFailed(
          'NOT_AVAILABLE',
          requestId: requestId,
        ));
        return;
      }

      _activeSource = source;
      _adoptPlaybackSession(source);
      _machine.dispatch(SourceResolved(
        info.id,
        source.streamUrl,
        requestId: requestId,
      ));
      if (_machine.state != PlaybackState.loading) {
        await _closePlaybackSession();
        return;
      }

      final engine = _engine;
      if (engine == null) {
        await _closePlaybackSession();
        _machine.dispatch(SourceResolutionFailed(
          'AUDIO_ENGINE_UNAVAILABLE',
          requestId: requestId,
        ));
        return;
      }

      await _serializeEngineOperation(() async {
        if (!_isCurrentRequest(requestId) || !identical(_engine, engine)) {
          return;
        }

        await engine.prepare(source);
        if (!_isCurrentRequest(requestId) || !identical(_engine, engine)) {
          return;
        }
        if (initialPosition > Duration.zero) {
          await engine.seek(initialPosition);
          if (!_isCurrentRequest(requestId) || !identical(_engine, engine)) {
            return;
          }
        }

        _machine.dispatch(MediaReady(requestId: requestId));
        if (_machine.state != PlaybackState.buffering) return;
        _machine.dispatch(PlayPressed());
        if (_machine.state != PlaybackState.playing) return;

        // just_audio's play Future completes when playback stops, not when
        // playback first starts. Do not await the whole song here.
        unawaited(engine.play().catchError(
          (Object error, StackTrace stackTrace) {
            if (_isCurrentRequest(requestId)) {
              _scrobbles.onStop(info.id);
              unawaited(_closePlaybackSession());
              _machine.dispatch(SourceResolutionFailed(
                'PLAYBACK_FAILED',
                requestId: requestId,
              ));
            }
          },
        ));
      });

      if (!_isCurrentRequest(requestId)) return;
      if (_machine.state != PlaybackState.playing) {
        await _closePlaybackSession();
        return;
      }
      _startHeartbeatTimer();

      if (info.title != null && !info.id.startsWith('device:')) {
        final auth = ref.read(authSessionProvider);
        final ownerId = auth is AuthSignedIn ? auth.userId : 'guest';
        unawaited(_recent
            .record(
              ownerId,
              info.id,
              info.title!,
              info.artist ?? '',
              info.artworkUrl,
              info.duration,
            )
            .catchError((_) {}));
      }
      // Session stop is now the authoritative qualified-play event.
      // Keep the legacy reporter only for local/offline media, which has no
      // server playback session.
      if (source.sessionId == null && !info.id.startsWith('device:') &&
          !isDeezerPreview(info.id) && !isExternalRecordingId(info.id)) {
        unawaited(
          ref.read(playHistoryReporterProvider)(info).catchError((_) {}),
        );
      }
      _scrobbles.onPlay(info.id, DateTime.now().toUtc());
    } catch (_) {
      if (_isCurrentRequest(requestId)) {
        await _closePlaybackSession();
        if (await _tryDeezerPreview(info, requestId) || !_isCurrentRequest(requestId)) return;
        _machine.dispatch(SourceResolutionFailed(
          'PLAYBACK_SETUP_FAILED',
          requestId: requestId,
        ));
      }
    }
  }
}

/// Display info for a track — what Now Playing renders.
class TrackInfo {
  final String id;
  final String? title;
  final String? artist;
  final String? artworkUrl;
  final String? localFilePath;
  final Duration duration;

  const TrackInfo({
    required this.id,
    this.title,
    this.artist,
    this.artworkUrl,
    this.localFilePath,
    this.duration = Duration.zero,
  });
}

/// The backend playback resolver contract — platform-agnostic.
abstract interface class PlaybackResolver {
  Future<PlayableSource?> resolve(TrackInfo track);
}

/// Provider for the resolver; overridden in bootstrap with the real
/// implementation.
final playbackResolverProvider = Provider<PlaybackResolver>((ref) {
  throw UnimplementedError('Overridden in bootstrap');
});

/// Immutable player state exposed to the UI.
class PlayerState {
  final PlaybackState playbackState;
  final Duration position;
  final Duration duration;
  final TrackInfo? currentTrack;

  /// Bumped on queue mutations; UI listens to this to rebuild queue views.
  final int queueVersion;

  const PlayerState({
    required this.playbackState,
    required this.position,
    required this.duration,
    required this.currentTrack,
    required this.queueVersion,
  });

  factory PlayerState.initial() => const PlayerState(
        playbackState: PlaybackState.idle,
        position: Duration.zero,
        duration: Duration.zero,
        currentTrack: null,
        queueVersion: 0,
      );

  PlayerState copyWith({
    PlaybackState? playbackState,
    Duration? position,
    Duration? duration,
    TrackInfo? currentTrack,
    bool clearCurrentTrack = false,
    int? queueVersion,
  }) {
    return PlayerState(
      playbackState: playbackState ?? this.playbackState,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      currentTrack: clearCurrentTrack ? null : (currentTrack ?? this.currentTrack),
      queueVersion: queueVersion ?? this.queueVersion,
    );
  }
}

/// Reports successfully started plays to the backend for listening history
/// and artist analytics. The default is a no-op for isolated player tests.
typedef PlayHistoryReporter = Future<void> Function(TrackInfo track);

final playHistoryReporterProvider = Provider<PlayHistoryReporter>(
  (ref) => (track) async {},
);

/// The single global provider — one instance app-wide (§53.1).
final playerControllerProvider =
    NotifierProvider<PlayerController, PlayerState>(PlayerController.new);
