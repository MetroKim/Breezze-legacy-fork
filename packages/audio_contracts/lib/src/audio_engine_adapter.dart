/// Breezze audio engine contract — spec §51.3 (AudioEngineAdapter).
///
/// Platform divergence is confined to adapters implementing this
/// interface (§37.3). The engine itself differs per OS (AVFoundation,
/// Media3, Web Audio); the Dart contract is one.
library;

import 'playback_state_machine.dart';

/// A resolved, authorized media source returned by the backend resolver.
class PlayableSource {
  final String trackId;
  final String streamUrl;

  /// Authenticated server playback session associated with this grant.
  final String? sessionId;

  /// Short-lived signed URL; the engine must never cache it (§29.9).
  final DateTime expiresAtUtc;

  /// Audio format metadata, shown only when verified (§53.7).
  final String? codec;
  final int? sampleRateHz;
  final int? bitDepth;

  /// Local app-private media is exempt from signed-URL expiry checks.
  final bool isLocal;

  PlayableSource({
    required this.trackId,
    required this.streamUrl,
    required this.expiresAtUtc,
    this.sessionId,
    this.codec,
    this.sampleRateHz,
    this.bitDepth,
    this.isLocal = false,
  });

  bool get isExpired =>
      !isLocal && DateTime.now().toUtc().isAfter(expiresAtUtc);
}

/// Commands the global PlayerController can issue to the engine.
abstract interface class AudioEngineAdapter {
  /// Prepares the given source for playback. Must not autoplay.
  Future<void> prepare(PlayableSource source);

  /// Starts or resumes playback.
  Future<void> play();

  /// Pauses playback, preserving position.
  Future<void> pause();

  /// Seeks to [position] within the current source.
  Future<void> seek(Duration position);

  /// Stops and releases the current source.
  Future<void> stop();

  /// Current position within the active source.
  Duration get position;

  /// Duration of the active source, zero when unknown.
  Duration get duration;

  /// Sets playback volume, 0.0–1.0.
  Future<void> setVolume(double volume);

  /// Sets playback rate where the content type supports it.
  Future<void> setSpeed(double rate);

  /// Streams high-frequency position ticks; consumers must throttle
  /// rebuilds (§51.6: isolate high-frequency player updates).
  Stream<Duration> get positionStream;

  /// Streams engine-side state changes (buffering, ended, error).
  Stream<PlaybackState> get engineStateStream;
}

/// Optional native playlist capability. This is deliberately separate from
/// AudioEngineAdapter: licensed remote streams still require per-track
/// playback sessions, and cannot be speculatively stitched into a playlist.
abstract interface class GaplessLocalQueueEngine {
  /// All sources must be app-private/user-controlled local audio files.
  Future<void> prepareLocalPlaylist(
    List<PlayableSource> sources, {
    required int initialIndex,
  });

  /// Native sequence index changes without resetting the decoder.
  Stream<int?> get currentIndexStream;

  /// Seeks within an already prepared native playlist.
  Future<void> skipToIndex(int index);
}

/// Queue entries must have stable IDs, source context, version and
/// origin (§53.4) — they are NOT bare track references.
class QueueEntry {
  final String entryId;
  final String trackId;

  /// Where the entry came from: album, playlist, radio, search,
  /// recommendation or manual (§53.4).
  final String origin;

  /// Bounded context shown in "Playing From" (§9.4).
  final String sourceContext;
  final String? sourceCollectionId;

  final int insertedAtMs;
  final String trackVersion;

  QueueEntry({
    required this.entryId,
    required this.trackId,
    required this.origin,
    required this.sourceContext,
    this.sourceCollectionId,
    required this.insertedAtMs,
    required this.trackVersion,
  });

  QueueEntry copyWith({int? insertedAtMs}) => QueueEntry(
        entryId: entryId,
        trackId: trackId,
        origin: origin,
        sourceContext: sourceContext,
        sourceCollectionId: sourceCollectionId,
        insertedAtMs: insertedAtMs ?? this.insertedAtMs,
        trackVersion: trackVersion,
      );
}
