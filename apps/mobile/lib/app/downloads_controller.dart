import 'dart:convert';
import 'dart:io';

import 'package:breezze_api_client/breezze_api_client.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../core/api/breezze_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/audio/authorized_download_grant.dart';
import '../core/audio/playback_source_policy.dart';
import '../core/auth/auth_session.dart';
import '../core/database/database_providers.dart';
import '../core/database/outbox_sync_service.dart';
import 'bootstrap.dart';
import 'download_preferences.dart';

/// Live transfer progress and queue state, keyed by track ID.
final downloadJobStatusProvider = StateProvider<Map<String, String>>((ref) => {});

/// Live download progress, keyed by track id: 0.0–1.0, removed on finish.
final downloadProgressProvider =
    StateNotifierProvider<DownloadsController, Map<String, double>>(
        DownloadsController.new);

/// Downloads only short-lived URLs authorized by the Breezze backend.
/// Provider metadata/search adapters are never allowed to grant download
/// rights or expose a raw stream URL.
class DownloadsController extends StateNotifier<Map<String, double>> {
  DownloadsController(this.ref) : super({}) { _restoreJobs(); }

  final Ref ref;
  final Map<String, DownloadCancellation> _cancellations = {};
  final Map<String, BzTrack> _tracks = {};

  Future<File> _jobsFile() async {
    final dir = await getApplicationSupportDirectory();
    final folder = Directory('${dir.path}/Breezze/Downloads');
    await folder.create(recursive: true);
    return File('${folder.path}/jobs.json');
  }

  Future<void> _persistJobs() async {
    try {
      final file = await _jobsFile();
      final records = <String, Object?>{};
      final statuses = ref.read(downloadJobStatusProvider);
      for (final entry in _tracks.entries) {
        final track = entry.value;
        records[entry.key] = {
          'title': track.title,
          'artist': track.artist,
          'album': track.album,
          'artworkUrl': track.artworkUrl,
          'durationMs': track.duration.inMilliseconds,
          'explicit': track.explicit,
          'status': statuses[entry.key] ?? 'queued',
        };
      }
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(records), flush: true);
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    } catch (_) {}
  }

  Future<void> _restoreJobs() async {
    try {
      final file = await _jobsFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final statuses = <String, String>{};
      for (final entry in decoded.entries) {
        final raw = entry.value;
        if (raw is! Map) continue;
        final item = raw.cast<String, dynamic>();
        final track = BzTrack(
          id: entry.key,
          title: item['title'] as String? ?? 'Unknown track',
          artist: item['artist'] as String? ?? 'Unknown artist',
          album: item['album'] as String?,
          artworkUrl: item['artworkUrl'] as String?,
          duration: Duration(milliseconds: (item['durationMs'] as num?)?.toInt() ?? 0),
          explicit: item['explicit'] == true,
        );
        _tracks[entry.key] = track;
        final saved = item['status'] as String? ?? 'failed';
        statuses[entry.key] = saved == 'downloading' ? 'paused' : saved;
      }
      if (mounted) ref.read(downloadJobStatusProvider.notifier).state = statuses;
    } catch (_) {}
  }

  void _setStatus(String id, String status) {
    if (!mounted) return;
    final next = Map<String, String>.of(ref.read(downloadJobStatusProvider));
    next[id] = status;
    ref.read(downloadJobStatusProvider.notifier).state = next;
    _persistJobs();
  }

  Future<void> pause(String trackId) async {
    _setStatus(trackId, 'paused');
    _cancellations[trackId]?.cancel();
  }

  Future<void> resume(String trackId) async {
    final track = _tracks[trackId];
    if (track != null) {
      final next = Map<String, double>.of(state)..remove(trackId);
      state = next;
      await download(track);
    }
  }

  Future<void> retry(String trackId) async {
    final track = _tracks[trackId];
    if (track != null) await download(track);
  }

  Future<void> cancel(String trackId) async {
    _setStatus(trackId, 'cancelled');
    _cancellations[trackId]?.cancel();
    final auth = ref.read(authSessionProvider);
    if (auth is AuthSignedIn) {
      final dir = await downloadsDirectory(userId: auth.userId);
      await DownloadsLibrary(root: dir, lyrics: ref.read(lyricsProvider)).removePartial(trackId);
    }
    if (mounted) {
      final next = Map<String, double>.of(state)..remove(trackId);
      state = next;
    }
  }

  Future<void> download(BzTrack track) async {
    if (!canRequestOfflineDownload(track.id)) {
      _setStatus(track.id, 'failed');
      return;
    }
    if (state.containsKey(track.id) || ['downloading', 'downloaded'].contains(ref.read(downloadJobStatusProvider)[track.id])) return;
    _tracks[track.id] = track;
    final cancellation = DownloadCancellation();
    _cancellations[track.id] = cancellation;
    _setStatus(track.id, 'downloading');

    try {
      final preferences = await DownloadPreferencesStore().load();
      final network = await Connectivity().checkConnectivity();
      final onWifi = network.contains(ConnectivityResult.wifi);
      final onMobile = network.contains(ConnectivityResult.mobile);
      if (!onWifi && (!onMobile || preferences.wifiOnly || !preferences.allowCellular)) {
        _setStatus(track.id, onMobile ? 'waiting_for_wifi' : 'waiting_for_network');
        return;
      }

      final auth = ref.read(authSessionProvider);
      if (auth is! AuthSignedIn) {
        _setStatus(track.id, 'failed');
        return;
      }

      final api = ref.read(authSessionProvider.notifier).api;
      if (api.accessToken == null) { _setStatus(track.id, 'failed'); return; }

      final catalogId = await _resolveCatalogId(api, track);
      if (cancellation.isCancelled) return;
      if (catalogId == null) { _setStatus(track.id, 'failed'); return; }

      final authorization = await api.authorizeDownload(
        trackId: catalogId,
        territory: ref.read(outboxTerritoryProvider),
      );
      if (cancellation.isCancelled) return;
      if (authorization['allowed'] != true) {
        _setStatus(track.id, 'failed');
        // ignore: avoid_print
        print('download_not_authorized: ${authorization['reason']}');
        return;
      }

      final grant = AuthorizedDownloadGrant.fromResponse(authorization);
      if (grant == null) {
        _setStatus(track.id, 'failed');
        return;
      }
      // The user may have signed out while the server was authorizing.
      final currentAuth = ref.read(authSessionProvider);
      if (currentAuth is! AuthSignedIn || currentAuth.userId != auth.userId) {
        _setStatus(track.id, 'cancelled');
        return;
      }

      state = {...state, track.id: 0.0};
      final dir = await downloadsDirectory(userId: auth.userId);
      final library = DownloadsLibrary(
        root: dir,
        lyrics: ref.read(lyricsProvider),
      );
      final ok = await library.download(
        track,
        downloadUrl: grant.downloadUrl.toString(),
        ownerId: auth.userId,
        catalogTrackId: catalogId,
        rightsExpiresAtUtc: grant.offlineLeaseExpiresAtUtc,
        assetVersion: grant.assetVersion,
        cancellation: cancellation,
        onProgress: (progress) {
          if (mounted) state = {...state, track.id: progress};
        },
      );

      final latestAuth = ref.read(authSessionProvider);
      if (latestAuth is! AuthSignedIn || latestAuth.userId != auth.userId ||
          cancellation.isCancelled) {
        // Never promote an old-account transfer into a downloaded job.
        // The old account's private file must not survive a race to logout.
        await library.remove(track.id);
        _setStatus(track.id, 'cancelled');
        return;
      }
      if (ok) {
        _setStatus(track.id, 'downloaded');
      } else if (!cancellation.isCancelled) {
        _setStatus(track.id, 'failed');
      }
    } catch (_) {
      if (!cancellation.isCancelled) _setStatus(track.id, 'failed');
    } finally {
      if (identical(_cancellations[track.id], cancellation)) _cancellations.remove(track.id);
      if (mounted) {
        if (ref.read(downloadJobStatusProvider)[track.id] != 'paused') {
          final next = Map<String, double>.of(state)..remove(track.id);
          state = next;
        }
      }
    }
  }

  Future<String?> _resolveCatalogId(
    BreezzeApi api,
    BzTrack track,
  ) async {
    if (!track.id.startsWith('bz:')) return track.id;

    final mapDao = ref.read(catalogIdMapDaoProvider);
    final cached = await mapDao.lookup(track.id);
    if (cached != null) return cached;

    final resolved = await api.resolveCatalogTrack(
      externalId: track.id,
      source: 'youtube',
      title: track.title,
      artistName: track.artist,
      durationSec: track.duration.inSeconds.clamp(1, 86400).toInt(),
    );
    final catalogId = resolved['id'] as String?;
    if (catalogId == null || catalogId.isEmpty) return null;
    await mapDao.save(track.id, catalogId);
    return catalogId;
  }
}
