import 'dart:convert';
import 'dart:io';

import 'package:breezze_api_client/breezze_api_client.dart';
import 'package:breezze_audio_contracts/audio_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/api/breezze_api.dart';
import '../core/audio/playback_source_policy.dart';
import 'download_preferences.dart';
import '../core/auth/auth_session.dart';
import '../core/database/database_providers.dart';
import '../core/database/db_instance.dart';
import '../core/database/favorites_dao.dart';
import '../features/player/player_controller.dart';

/// Composition root for Breezze app services.
///
/// Resolve full recordings through backend sessions and label Deezer previews.
/// Downloads remain rights-gated. Lyrics
/// lookup remains keyless through LRCLIB.

/// package:http impl of the lyrics HTTP seam.
class HttpLyrics implements LyricsHttp {
  final http.Client _client = http.Client();

  @override
  Future<String> getText(String url) async {
    final response = await _client.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw HttpException('lyrics_${response.statusCode}');
    }
    return response.body;
  }
}

/// Backend-backed federated catalog adapter. Search metadata comes from all
/// enabled providers; playback is still authorized separately by the API.
class BackendCatalogSourceAdapter implements ProviderAdapter {
  BackendCatalogSourceAdapter(this._ref);

  final Ref _ref;

  @override
  String get providerId => 'federated_catalog';

  @override
  String get adapterVersion => '1.0.0';

  ProviderTrack _trackFromJson(Map value, {String providerId = 'youtube_music'}) {
    final trackId = value['providerTrackId'] as String? ?? '';
    final duration = value['durationSec'];
    return ProviderTrack(
      breezzeTrackId: 'bz:$providerId:$trackId',
      hasPreview: providerId == 'deezer' && value['previewUrl'] is String,
      providerTrackId: '$providerId:$trackId',
      title: value['title'] as String? ?? '',
      artist: value['artist'] as String? ?? 'Unknown artist',
      artworkUrl: value['artworkUrl'] as String?,
      duration: Duration(seconds: duration is num ? duration.toInt() : 0),
    );
  }

  ProviderTrack _localTrackFromJson(Map value) {
    final id = value['id'] as String? ?? '';
    final artistData = value['artist'];
    final artist = artistData is Map
        ? artistData['name'] as String? ?? 'Unknown artist'
        : 'Unknown artist';
    final duration = value['duration'];
    return ProviderTrack(
      breezzeTrackId: id,
      providerTrackId: value['externalId'] as String? ?? id,
      title: value['title'] as String? ?? '',
      artist: artist,
      artworkUrl: value['artworkUrl'] as String?,
      duration: Duration(seconds: duration is num ? duration.toInt() : 0),
    );
  }

  @override
  Future<ProviderOp<List<ProviderTrack>>> search(String query) async {
    try {
      final data = await _ref.read(authSessionProvider.notifier).api
          .searchAllProviders(query);
      final rawProviders = data['providers'];
      if (rawProviders is! List) return ProviderError('invalid_catalog_response');

      final tracks = <ProviderTrack>[];
      final seen = <String>{};
      var successfulProviders = 0;
      for (final providerEntry in rawProviders.whereType<Map>()) {
        final providerId = providerEntry['providerId'] as String? ?? '';
        final envelope = providerEntry['result'];
        if (providerId.isEmpty || envelope is! Map || envelope['kind'] != 'ok') {
          // One provider's error/unsupported response does not discard the
          // successful results returned by other providers.
          continue;
        }
        final rawTracks = envelope['value'];
        if (rawTracks is! List) continue;
        successfulProviders++;
        for (final rawTrack in rawTracks.whereType<Map>()) {
          final providerTrackId = rawTrack['providerTrackId'] as String? ?? '';
          final title = rawTrack['title'] as String? ?? '';
          final artist = rawTrack['artist'] as String? ?? '';
          if (providerTrackId.isEmpty || title.isEmpty || artist.isEmpty) continue;

          // The internal catalog already returns canonical Breezze IDs.
          // External provider IDs are namespaced to avoid cross-provider
          // collisions and are converged by the backend before playback.
          final track = providerId == 'breezze_internal'
              ? _localTrackFromJson({
                  'id': providerTrackId,
                  'title': title,
                  'artist': {'name': artist},
                  'duration': rawTrack['durationSec'],
                  'artworkUrl': rawTrack['artworkUrl'],
                })
              : _trackFromJson(rawTrack, providerId: providerId);
          if (track.breezzeTrackId.isNotEmpty &&
              track.title.isNotEmpty &&
              seen.add(track.breezzeTrackId)) {
            tracks.add(track);
          }
        }
      }
      if (successfulProviders == 0) return ProviderError('all_providers_unavailable');
      // A successful empty catalogue query is not a network failure.
      if (tracks.isEmpty) return ProviderOk(<ProviderTrack>[]);
      return ProviderOk(tracks);
    } catch (_) {
      return ProviderError('network_error');
    }
  }

  @override
  Future<ProviderOp<ProviderTrack>> getTrack(String providerTrackId) async {
    try {
      final separator = providerTrackId.indexOf(':');
      if (separator <= 0 || separator == providerTrackId.length - 1) {
        return ProviderError('invalid_provider_track_id');
      }
      final source = providerTrackId.substring(0, separator);
      final sourceTrackId = providerTrackId.substring(separator + 1);
      final data = await _ref.read(authSessionProvider.notifier).api
          .getProviderTrack(source, sourceTrackId);
      final value = data['value'];
      if (data['kind'] != 'ok' || value is! Map) {
        return ProviderError('track_metadata_unavailable');
      }
      return ProviderOk(_trackFromJson(value, providerId: source));
    } catch (_) {
      return ProviderError('network_error');
    }
  }

}

/// The app-wide metadata/search adapter; it is not a playback authority.
final catalogSourceProvider =
    Provider<ProviderAdapter>((ref) => BackendCatalogSourceAdapter(ref));

/// The lyrics provider.
final lyricsProvider =
    Provider<LyricsProvider>((ref) => LyricsProvider(HttpLyrics()));

/// Metadata search chain. No source in this chain grants playback rights.
final sourceChainProvider = Provider<SourceChain>((ref) => SourceChain([
      ref.watch(catalogSourceProvider),
    ]));

/// The playback resolver. Catalog metadata is converged to a canonical
/// backend track ID, then full-stream playback is authorized by the backend.
/// The mobile client never turns catalogue metadata directly into a
/// playable stream URL.
class LiveResolver implements PlaybackResolver {
  final Ref _ref;

  LiveResolver(this._ref);

  @override
  Future<PlayableSource?> resolve(TrackInfo track) async {
    if (isDeezerPreview(track.id)) {
      try {
        final result = await _ref.read(authSessionProvider.notifier).api
            .getProviderTrack('deezer', track.id.split(':').last);
        final value = result['value'];
        final uri = value is Map && value['previewUrl'] is String
            ? Uri.tryParse(value['previewUrl'] as String) : null;
        if (uri == null || uri.scheme != 'https' || !uri.host.endsWith('.dzcdn.net')) return null;
        return PlayableSource(trackId: track.id, streamUrl: uri.toString(),
            expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)));
      } catch (_) {
        return null;
      }
    }
    final auth = _ref.read(authSessionProvider);
    if (auth is! AuthSignedIn) return null;

    final api = _ref.read(authSessionProvider.notifier).api;
    if (api.accessToken == null) return null;

    try {
      final externalRecording = isExternalRecordingId(track.id);
      final catalogId = externalRecording ? null : await _resolveCatalogId(api, track);
      if (!externalRecording && catalogId == null) return null;

      final providerIdentity = _providerIdentity(track.id);
      if (!externalRecording && providerIdentity != null) {
        final session = await api.startPlaybackSession(
          providerId: providerIdentity.$1,
          providerTrackId: providerIdentity.$2,
          canonicalTrackId: catalogId,
        );
        final sessionId = session['id'] as String?;
        final playback = session['playback'];
        final streamUrl = playback is Map ? playback['streamUrl'] as String? : null;
        final expiresAt = playback is Map
            ? DateTime.tryParse(playback['expiresAt'] as String? ?? '')
            : null;
        if (streamUrl == null || expiresAt == null || sessionId == null) {
          if (sessionId != null) {
            try { await api.stopPlaybackSession(sessionId); } catch (_) {}
          }
          return null;
        }
        return PlayableSource(
          trackId: track.id,
          streamUrl: streamUrl,
          expiresAtUtc: expiresAt.toUtc(),
          sessionId: sessionId,
          codec: playback['codec'] as String?,
        );
      }

      final preferences = await DownloadPreferencesStore().load();
      final session = await api.startPlaybackSession(
        trackId: catalogId,
        externalTrackId: externalRecording ? track.id : null,
        requestedQuality: preferences.streamingQuality,
      );
      final sessionId = session['id'] as String?;
      final playback = session['playback'];
      final streamUrl = playback is Map ? playback['streamUrl'] as String? : null;
      final expiresAt = playback is Map
          ? DateTime.tryParse(playback['expiresAt'] as String? ?? '')
          : null;
      if (streamUrl == null || expiresAt == null || sessionId == null) {
        if (sessionId != null) {
          try { await api.stopPlaybackSession(sessionId); } catch (_) {}
        }
        return null;
      }

      return PlayableSource(
        trackId: track.id,
        streamUrl: streamUrl,
        expiresAtUtc: expiresAt.toUtc(),
        sessionId: sessionId,
        codec: playback['codec'] as String?,
      );
    } catch (_) {
      // Rights denials and backend/network failures are unavailable playback,
      // not permission to fall back to an unlicensed provider URL.
      return null;
    }
  }

  (String, String)? _providerIdentity(String id) {
    if (!id.startsWith('bz:')) return null;
    final namespaced = id.substring(3);
    final separator = namespaced.indexOf(':');
    if (separator <= 0 || separator == namespaced.length - 1) return null;
    return (namespaced.substring(0, separator), namespaced.substring(separator + 1));
  }

  Future<String?> _resolveCatalogId(BreezzeApi api, TrackInfo track) async {
    if (!track.id.startsWith('bz:')) return track.id;

    final mapDao = _ref.read(catalogIdMapDaoProvider);
    final cached = await mapDao.lookup(track.id);
    if (cached != null) return cached;

    final title = track.title;
    final artist = track.artist;
    final provider = _providerIdentity(track.id);
    if (provider == null || title == null || title.trim().isEmpty ||
        artist == null || artist.trim().isEmpty) {
      return null;
    }

    final resolved = await api.resolveCatalogTrack(
      externalId: track.id,
      source: provider.$1,
      title: title,
      artistName: artist,
      durationSec: track.duration.inSeconds.clamp(1, 86400).toInt(),
    );
    final catalogId = resolved['id'] as String?;
    if (catalogId == null || catalogId.isEmpty) return null;
    await mapDao.save(track.id, catalogId);
    return catalogId;
  }
}

/// Resolver override applied in main() via ProviderScope.
final liveResolverProvider =
    Provider<PlaybackResolver>((ref) => LiveResolver(ref));

// ---------------------------------------------------------------------------
// Storage (path_provider): app-private, survives restarts
// ---------------------------------------------------------------------------

/// App-private downloads directory — the real per-track offline library.
Future<Directory> downloadsDirectory({required String userId}) async {
  // Scope local media by authenticated account. Never share one account's
  // downloaded catalogue with another account on the same device.
  final safeUserId = userId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  if (safeUserId.isEmpty) {
    throw ArgumentError.value(userId, 'userId', 'must be non-empty');
  }
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/downloads/$safeUserId');
  await dir.create(recursive: true);
  return dir;
}

// ---------------------------------------------------------------------------
// Favorites — drift-backed store, JSON kept only as the legacy import
// source for the one-shot migration.
// ---------------------------------------------------------------------------

/// A favorited track with its display info.
class FavoriteTrack {
  final String id;
  final String title;
  final String artist;
  final String? artworkUrl;
  final int durationMs;

  const FavoriteTrack({
    required this.id,
    required this.title,
    required this.artist,
    this.artworkUrl,
    this.durationMs = 0,
  });

  TrackInfo toTrackInfo() => TrackInfo(
        id: id,
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
        duration: Duration(milliseconds: durationMs),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'artworkUrl': artworkUrl,
        'durationMs': durationMs,
      };

  static FavoriteTrack fromJson(Map<String, Object?> json) => FavoriteTrack(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        artworkUrl: json['artworkUrl'] as String?,
        durationMs: json['durationMs'] as int? ?? 0,
      );
}

/// Legacy JSON favorites reader — used ONLY by the one-shot migration.
class LegacyFavoritesJson {
  static const _fileName = 'breezze_favorites.json';

  Future<File> _file() async {
    final base = await getApplicationDocumentsDirectory();
    return File('${base.path}/$_fileName');
  }

  Future<List<FavoriteTrack>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return [];
      return [
        for (final item in raw)
          if (item is Map) FavoriteTrack.fromJson(item.cast<String, Object?>())
      ];
    } catch (_) {
      return [];
    }
  }
}

/// Favorites store — drift-backed (SQLite). Same public API as the
/// JSON version (load / toggle / isFavorite), so screens are unchanged.
class FavoritesStore {
  final FavoritesDao _dao = FavoritesDao(breezzeDb);

  Future<List<FavoriteTrack>> load({String ownerId = 'guest'}) async {
    final rows = await _dao.list(ownerId: ownerId);
    return [
      for (final r in rows)
        FavoriteTrack(
          id: r.id.value,
          title: r.title.value,
          artist: r.artist.value,
          artworkUrl: r.artworkUrl.value,
          durationMs: r.durationMs.value,
        )
    ];
  }

  /// Returns true when the track was added, false when removed.
  Future<bool> toggle(
    FavoriteTrack track, {
    String ownerId = 'guest',
  }) async {
    if (await _dao.contains(track.id, ownerId: ownerId)) {
      await _dao.remove(track.id, ownerId: ownerId);
      return false;
    }
    await _dao.add(
      id: track.id,
      title: track.title,
      artist: track.artist,
      artworkUrl: track.artworkUrl,
      durationMs: track.durationMs,
      ownerId: ownerId,
    );
    return true;
  }

  Future<bool> isFavorite(String id, {String ownerId = 'guest'}) =>
      _dao.contains(id, ownerId: ownerId);
}

/// App-wide favorites store provider.
final favoritesStoreProvider =
    Provider<FavoritesStore>((ref) => FavoritesStore());
