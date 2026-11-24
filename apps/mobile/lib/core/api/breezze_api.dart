import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kReleaseMode;

import 'package:http/http.dart' as http;

/// Breezze backend API client — thin transport for /api/v1.
///
/// No secrets: the backend is Breezze's own; JWT access + refresh tokens
/// are stored by the session controller, never hardcoded.
class BreezzeApi {
  BreezzeApi({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  String? accessToken;
  Future<bool> Function()? onUnauthorized;

  Uri _uri(String path) {
    final configured = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (configured.isEmpty) {
      throw const BreezzeApiException(
        code: 'API_URL_NOT_CONFIGURED',
        message: 'Breezze API URL is not configured. Set BREEZZE_API_URL to the HTTPS API edge URL.',
      );
    }
    final origin = Uri.tryParse(configured);
    if (origin == null || !origin.hasAuthority || origin.host.isEmpty
        || (origin.scheme != 'https' && origin.scheme != 'http')
        || origin.path.isNotEmpty || origin.query.isNotEmpty || origin.fragment.isNotEmpty) {
      throw const BreezzeApiException(
        code: 'API_URL_INVALID',
        message: 'Breezze API URL must be an absolute HTTP(S) origin without a path, query, or fragment.',
      );
    }
    if (kReleaseMode && origin.scheme != 'https') {
      throw const BreezzeApiException(
        code: 'API_URL_REQUIRES_HTTPS',
        message: 'Release builds require an HTTPS Breezze API URL.',
      );
    }
    if (kReleaseMode && (origin.host == 'localhost' || origin.host == '127.0.0.1')) {
      throw const BreezzeApiException(
        code: 'API_URL_LOCALHOST_IN_RELEASE',
        message: 'A release build cannot connect to localhost. Configure the public Breezze API URL.',
      );
    }
    // resolve() preserves query strings already embedded in API paths.
    return origin.resolve('/api/v1$path');
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      };

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    Future<http.Response> send() => _client.post(
          _uri(path),
          headers: _headers,
          body: jsonEncode(body),
        );
    var response = await send();
    if (response.statusCode == 401 &&
        path != '/auth/refresh' &&
        path != '/auth/login' &&
        path != '/auth/register' &&
        path != '/auth/supabase/exchange' &&
        path != '/auth/supabase/link-legacy' &&
        !path.startsWith('/auth/social/') &&
        !path.startsWith('/auth/mfa/') &&
        onUnauthorized != null &&
        await onUnauthorized!()) {
      response = await send();
    }
    return _decode(response);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    // Retrying an idempotent GET is safe after a transient edge/network
    // interruption. Never apply this retry to POST/PATCH/DELETE mutations.
    final originalToken = accessToken;
    Future<http.Response> send() =>
        _client.get(_uri(path), headers: _headers)
            .timeout(const Duration(seconds: 10));
    http.Response response;
    try {
      response = await send();
    } on Exception catch (error) {
      if ((error is! TimeoutException && error is! http.ClientException) ||
          accessToken != originalToken) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // An account switch during the backoff must never replay the old read
      // under a different listener's session.
      if (accessToken != originalToken) rethrow;
      response = await send(); // Exactly one retry; a second failure propagates.
    }
    if (response.statusCode == 401 &&
        onUnauthorized != null &&
        await onUnauthorized!()) {
      response = await send();
    }
    return _decode(response);
  }
  Future<Map<String, dynamic>> _patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    Future<http.Response> send() => _client.patch(
          _uri(path),
          headers: _headers,
          body: jsonEncode(body),
        );
    var response = await send();
    if (response.statusCode == 401 &&
        onUnauthorized != null &&
        await onUnauthorized!()) {
      response = await send();
    }
    return _decode(response);
  }

  Future<Map<String, dynamic>> _delete(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    Future<http.Response> send() => _client.delete(
          _uri(path),
          headers: _headers,
          body: body == null ? null : jsonEncode(body),
        );
    var response = await send();
    if (response.statusCode == 401 &&
        onUnauthorized != null &&
        await onUnauthorized!()) {
      response = await send();
    }
    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    final body = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      final error = body['error'];
      // Nest HttpExceptions return a top-level machine-readable message.
      final rawCode = body['message'];
      final canonical = rawCode is String &&
              RegExp(r'^[A-Z][A-Z0-9_]{2,80}$').hasMatch(rawCode)
          ? rawCode
          : null;
      throw BreezzeApiException(
        code: error is Map && error['code'] is String
            ? error['code'] as String
            : canonical ?? 'HTTP_${response.statusCode}',
        message: error is Map && error['message'] is String
            ? error['message'] as String
            : 'Request failed',
      );
    }
    final data = body['data'];
    return data is Map<String, dynamic> ? data : body;
  }


  Future<Map<String, dynamic>> searchMusic(String query) =>
      _get('/search?q=${Uri.encodeQueryComponent(query)}');

  /// Federated catalog search. Each provider returns its own result envelope;
  /// a single provider outage must not hide results from the other catalogs.
  Future<Map<String, dynamic>> searchAllProviders(String query) =>
      _get('/providers/search?q=${Uri.encodeQueryComponent(query)}');

  Future<Map<String, dynamic>> searchDeezer(String query) =>
      _get('/providers/deezer/search?q=${Uri.encodeQueryComponent(query)}');

  Future<Map<String, dynamic>> getProviderTrack(
    String providerId,
    String providerTrackId,
  ) =>
      _get('/providers/${Uri.encodeComponent(providerId)}/tracks/${Uri.encodeComponent(providerTrackId)}');


  // ---- public catalog discovery (metadata only; never playback grants) ----
  Future<Map<String, dynamic>> discoveryDailyTop100({String country = 'us'}) =>
      _get('/discovery/charts/daily-top-100?country=${Uri.encodeQueryComponent(country)}');

  Future<Map<String, dynamic>> discoverySongsChart({String country = 'us'}) =>
      _get('/discovery/charts/songs?country=${Uri.encodeQueryComponent(country)}');

  Future<Map<String, dynamic>> discoveryNewReleases({String country = 'us'}) =>
      _get('/discovery/releases/albums?country=${Uri.encodeQueryComponent(country)}');

  Future<Map<String, dynamic>> discoveryLatestSongs({required String country}) =>
      _get('/discovery/releases/songs?country=${Uri.encodeQueryComponent(country)}');

  Future<Map<String, dynamic>> musicVideoForSong(String id) =>
      _get('/discovery/songs/${Uri.encodeComponent(id)}/music-video');

  Future<Map<String, dynamic>> discoveryMusicVideos({String query = 'official music video'}) =>
      _get('/discovery/videos?q=${Uri.encodeQueryComponent(query)}');

  Future<Map<String, dynamic>> discoveryConcerts({String country = 'TZ', String? city}) =>
      _get('/discovery/concerts?country=${Uri.encodeQueryComponent(country)}${city == null || city.trim().isEmpty ? '' : '&city=${Uri.encodeQueryComponent(city)}'}');

  Future<Map<String, dynamic>> discoveryTrackSearch(String query) =>
      _get('/discovery/tracks/search?q=${Uri.encodeQueryComponent(query)}');

  Future<Map<String, dynamic>> discoveryArtistSearch(String query) =>
      _get('/discovery/artists/search?q=${Uri.encodeQueryComponent(query)}');

  Future<Map<String, dynamic>> getFollowedArtists() =>
      _get('/library/artists');

  Future<bool> artistFollowing(String key) async {
    final data = await _get('/library/artists/${Uri.encodeComponent(key)}');
    return data['following'] as bool;
  }

  Future<void> followArtist(
    String key, bool following, {String? displayName}
  ) async {
    final path = '/library/artists/${Uri.encodeComponent(key)}';
    if (following) {
      await _post(path, {
        if (displayName != null) 'displayName': displayName,
      });
    } else {
      await _delete(path);
    }
  }

  Future<void> pinArtist(String key, bool pinned) async {
    await _patch('/library/artists/${Uri.encodeComponent(key)}/pin', {
      'pinned': pinned,
    });
  }

  Future<Map<String, dynamic>> discoveryArtistAlbums(String artistId) =>
      _get('/discovery/artists/${Uri.encodeComponent(artistId)}/albums');

  Future<Map<String, dynamic>> discoveryAlbumTracks(String albumId) =>
      _get('/discovery/albums/${Uri.encodeComponent(albumId)}/tracks');

  // ---- signed-in saved album metadata (not playback/download grants) ----

  Future<Map<String, dynamic>> getSavedAlbums({String? cursor}) =>
      _get('/library/albums' +
          (cursor == null ? '' : '?cursor=${Uri.encodeQueryComponent(cursor)}'));

  Future<Map<String, dynamic>> upsertSavedAlbum({
    required String externalAlbumId,
    required String title,
    required String artist,
    String? artworkUrl,
    String? catalogUrl,
    List<String> genres = const [],
    bool isCompilation = false,
    bool? isPinned,
  }) =>
      _post('/library/albums', {
        'externalAlbumId': externalAlbumId,
        'title': title,
        'artist': artist,
        if (artworkUrl != null) 'artworkUrl': artworkUrl,
        if (catalogUrl != null) 'catalogUrl': catalogUrl,
        'genres': genres,
        'isCompilation': isCompilation,
        if (isPinned != null) 'isPinned': isPinned,
      });

  Future<void> deleteSavedAlbum(String externalAlbumId) async {
    await _delete('/library/albums/${Uri.encodeComponent(externalAlbumId)}');
  }

  Future<Map<String, dynamic>> onboardingPreferences() =>
      _get('/onboarding/preferences');

  Future<void> saveOnboardingPreferences({
    required String country,
    required List<String> genres,
    required List<String> favoriteArtists,
  }) async {
    await _post('/onboarding/preferences', {
      'country': country,
      'genres': genres,
      'favoriteArtists': favoriteArtists,
    });
  }

  // ---- auth ----

  /// Only the backend can verify the supplied Supabase access token.
  /// The returned Breezze session is transitional until API account IDs
  /// have migrated; no credentials are passed to Breezze from the UI.
  Future<AuthResponse> exchangeSupabaseAccessToken(String accessToken) async {
    final data = await _post('/auth/supabase/exchange', {
      'accessToken': accessToken,
    });
    return AuthResponse.fromJson(data);
  }


  /// Explicit ownership proof; neither credential is saved by this client.
  Future<AuthResponse> linkLegacySupabaseAccount({
    required String supabaseAccessToken,
    required String legacyEmail,
    required String legacyPassword,
  }) async {
    final data = await _post('/auth/supabase/link-legacy', {
      'accessToken': supabaseAccessToken,
      'legacyEmail': legacyEmail,
      'legacyPassword': legacyPassword,
    });
    return AuthResponse.fromJson(data);
  }

  Future<AuthResponse> register(
    String email,
    String password, {
    String? displayName,
  }) async {
    final data = await _post('/auth/register', {
      'email': email,
      'password': password,
      if (displayName != null) 'displayName': displayName,
    });
    return AuthResponse.fromJson(data);
  }

  /// Universal system-browser OAuth pairing: same backend on Android,
  /// iOS, macOS, Windows, Linux and web. The app never receives provider
  /// access tokens and the browser never receives Breezze session tokens.
  Future<Map<String, dynamic>> socialProviders() =>
      _get('/auth/social/providers');

  Future<Map<String, dynamic>> startSocialLogin(String provider) {
    if (provider != 'google' && provider != 'apple') {
      throw ArgumentError.value(provider, 'provider');
    }
    return _post('/auth/social/$provider/start', {});
  }

  Future<Map<String, dynamic>> pollSocialLogin({
    required String flowId,
    required String secret,
  }) => _post('/auth/social/poll', {
    'id': flowId,
    'secret': secret,
  });

  Future<AuthResponse> login(String email, String password) async {
    final data = await _post('/auth/login', {
      'email': email,
      'password': password,
    });
    return AuthResponse.fromJson(data);
  }

  Future<Map<String, dynamic>> resolveCatalogTrack({
    required String externalId,
    required String source,
    required String title,
    required String artistName,
    required int durationSec,
  }) =>
      _post('/catalog/resolve', {
        'externalId': externalId,
        'source': source,
        'title': title,
        'artistName': artistName,
        'durationSec': durationSec,
      });

  Future<Map<String, dynamic>> startPlaybackSession({
    String? trackId,
    String? externalTrackId,
    String? requestedQuality,
    String? providerId,
    String? providerTrackId,
    String? canonicalTrackId,
  }) =>
      _post('/playback/sessions', {
        if (externalTrackId != null) 'externalTrackId': externalTrackId,
        if (trackId != null) 'trackId': trackId,
        if (requestedQuality != null) 'requestedQuality': requestedQuality,
        if (providerId != null) 'providerId': providerId,
        if (providerTrackId != null) 'providerTrackId': providerTrackId,
        if (canonicalTrackId != null) 'canonicalTrackId': canonicalTrackId,
      });

  Future<Map<String, dynamic>> playbackHeartbeat({
    required String sessionId,
    required String eventId,
    required int sequence,
  }) =>
      _post('/playback/sessions/${Uri.encodeComponent(sessionId)}/heartbeat', {
        'eventId': eventId,
        'sequence': sequence,
      });

  Future<void> pausePlaybackSession(String sessionId) async {
    await _post('/playback/sessions/${Uri.encodeComponent(sessionId)}/pause', const {});
  }

  Future<void> resumePlaybackSession(String sessionId) async {
    await _post('/playback/sessions/${Uri.encodeComponent(sessionId)}/resume', const {});
  }

  Future<void> stopPlaybackSession(String sessionId) async {
    await _post('/playback/sessions/${Uri.encodeComponent(sessionId)}/stop', const {});
  }

  Future<Map<String, dynamic>> resolveProviderPlayback({
    required String providerId,
    required String providerTrackId,
    required String canonicalTrackId,
    required String territory,
  }) =>
      _post('/playback/provider/resolve', {
        'providerId': providerId,
        'providerTrackId': providerTrackId,
        'canonicalTrackId': canonicalTrackId,
        'territory': territory,
      });

  Future<Map<String, dynamic>> resolvePlayback({
    required String trackId,
    required String territory,
    String? requestedQuality,
  }) =>
      _post('/playback/resolve', {
        'trackId': trackId,
        'territory': territory,
        if (requestedQuality != null) 'requestedQuality': requestedQuality,
      });

  Future<Map<String, dynamic>> authorizeDownload({
    required String trackId,
    required String territory,
  }) =>
      // Territory is derived by the trusted Cloudflare edge. Keep the
      // parameter temporarily for caller compatibility, but never transmit it.
      _post('/downloads', {
        'trackId': trackId,
      });

  Future<Map<String, dynamic>> revalidateOfflineLease({
    required String trackId,
    required String territory,
  }) =>
      // Territory is derived by the trusted Cloudflare edge, not the client.
      _post('/downloads/$trackId/revalidate', {});

  Future<AuthResponse> refresh(String refreshToken) async {
    final data = await _post('/auth/refresh', {
      'refreshToken': refreshToken,
    });
    return AuthResponse.fromJson(data);
  }

  Future<Map<String, dynamic>> beginMfaSetup(String password) =>
      _post('/auth/mfa/setup', {'password': password});

  Future<Map<String, dynamic>> verifyMfaSetup(String code) =>
      _post('/auth/mfa/setup/verify', {'code': code});

  Future<Map<String, dynamic>> verifyMfa(String code) =>
      _post('/auth/mfa/verify', {'code': code});

  Future<void> logout(String refreshToken) async {
    await _post('/auth/logout', {'refreshToken': refreshToken});
  }

  Future<Map<String, dynamic>> me() async => _get('/auth/me');

  // ---- account and sessions ----

  Future<Map<String, dynamic>> profile() => _get('/users/me');

  Future<Map<String, dynamic>> updateProfile({
    required String displayName,
    bool includePreferences = false,
    String? country,
    String? language,
    List<String>? genres,
    List<String>? favoriteArtists,
  }) =>
      _patch('/users/me', {
        'displayName': displayName,
        if (includePreferences) 'country': country,
        if (includePreferences) 'language': language,
        if (includePreferences) 'genres': genres ?? const <String>[],
        if (includePreferences)
          'favoriteArtists': favoriteArtists ?? const <String>[],
      });

  Future<void> deleteAccount({required String password}) async {
    await _delete('/users/me', body: {'password': password});
  }

  Future<List<Map<String, dynamic>>> sessions() async {
    final data = await _get('/auth/sessions');
    return _asMapList(
      data['sessions'] ?? data['items'] ?? data['data'] ?? data,
    );
  }

  Future<void> revokeSession(String sessionId) async {
    await _delete('/auth/sessions/${Uri.encodeComponent(sessionId)}');
  }

  // ---- home and playlists ----

  Future<List<Map<String, dynamic>>> homeFeed() async =>
      _asMapList(await _get('/home'));

  /// Fetches canonical, territory-filtered track metadata for a home-feed item.
  /// Playback still requires a separate authorized playback session.
  Future<Map<String, dynamic>> catalogSong(String trackId) =>
      _get('/catalog/songs/${Uri.encodeComponent(trackId)}');

  Future<Map<String, dynamic>> recordRecent(String trackId) =>
      _post('/home/recent', {'trackId': trackId});

  /// Snapshot of this account's saved songs, with display metadata from the
  /// canonical catalog. The server owns tenant filtering and authorization.
  Future<List<Map<String, dynamic>>> fetchCloudFavorites() async {
    final response = await _get('/library/favorites');
    final data = response['data'];
    if (data is! List || data.any((item) => item is! Map)) {
      throw const BreezzeApiException(
        code: 'CLOUD_FAVORITES_INVALID',
        message: 'The cloud library returned an invalid favorites snapshot.',
      );
    }
    return _asMapList(data);
  }

  Future<Map<String, dynamic>> addFavorite(String trackId) =>
      _post('/library/favorites', {'trackId': trackId});

  Future<void> removeFavorite(String trackId) async {
    await _delete('/library/favorites/${Uri.encodeComponent(trackId)}');
  }

  /// Backwards-compatible history sync. It no longer submits a qualified
  /// ListeningEvent; those are recorded only by server-authorized sessions.
  @Deprecated('Use recordRecent; qualified plays require a playback session')
  Future<Map<String, dynamic>> recordPlay(String trackId) =>
      recordRecent(trackId);

  Future<Map<String, dynamic>> replaySummary() => _get('/replay');

  Future<List<Map<String, dynamic>>> playlists() async =>
      _asMapList(await _get('/playlists'));

  /// Client UUID supports retry-safe creation after an offline session.
  Future<Map<String, dynamic>> createPlaylist(String name, {String? id}) =>
      _post('/playlists', {
        'name': name,
        if (id != null) 'id': id,
      });

  Future<Map<String, dynamic>> getPlaylist(String playlistId) =>
      _get('/playlists/${Uri.encodeComponent(playlistId)}');

  Future<Map<String, dynamic>> addPlaylistTrack(
    String playlistId,
    String trackId,
  ) =>
      _post('/playlists/${Uri.encodeComponent(playlistId)}/tracks', {
        'trackId': trackId,
      });

  Future<Map<String, dynamic>> reorderPlaylistTracks(
    String playlistId,
    List<String> trackIds,
  ) =>
      _patch(
        '/playlists/${Uri.encodeComponent(playlistId)}/tracks/order',
        {'trackIds': trackIds},
      );

  Future<void> removePlaylistTrack(String playlistId, String trackId) async {
    await _delete(
      '/playlists/${Uri.encodeComponent(playlistId)}/tracks/'
      '${Uri.encodeComponent(trackId)}',
    );
  }

  Future<Map<String, dynamic>> pinPlaylist(String playlistId, bool pinned) =>
      _patch(
        '/playlists/${Uri.encodeComponent(playlistId)}/pin',
        {'pinned': pinned},
      );

  Future<Map<String, dynamic>> renamePlaylist(
    String playlistId,
    String name,
  ) =>
      _patch('/playlists/${Uri.encodeComponent(playlistId)}', {'name': name});

  Future<void> deletePlaylist(String playlistId) async {
    await _delete('/playlists/${Uri.encodeComponent(playlistId)}');
  }

  // ---- in-app support ----

  Future<Map<String, dynamic>> createSupportRequest({
    required String category,
    required String subject,
    required String message,
  }) =>
      _post('/support/requests', {
        'category': category,
        'subject': subject,
        'message': message,
      });

  Future<List<Map<String, dynamic>>> supportRequests() async =>
      _asMapList(await _get('/support/requests'));

  // ---- notifications ----

  Future<List<Map<String, dynamic>>> notifications() async =>
      _asMapList(await _get('/notifications'));

  Future<Map<String, dynamic>> markNotificationRead(String id) =>
      _post('/notifications/${Uri.encodeComponent(id)}/read', const {});

  List<Map<String, dynamic>> _asMapList(Object? value) {
    if (value is List) {
      return value.whereType<Map>().map((item) {
        return item.map((key, value) => MapEntry(key.toString(), value));
      }).toList();
    }
    if (value is Map && value['data'] is List) {
      return _asMapList(value['data']);
    }
    return const [];
  }
}

class AuthResponse {
  final String accessToken;
  final String refreshToken;
  final String userId;
  final String email;
  final bool mfaRequired;
  final bool mfaSetupRequired;

  const AuthResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.email,
    this.mfaRequired = false,
    this.mfaSetupRequired = false,
  });

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    final user = json['user'];
    return AuthResponse(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String,
      userId: user is Map ? (user['id'] as String? ?? '') : '',
      email: user is Map ? (user['email'] as String? ?? '') : '',
      mfaRequired: json['mfaRequired'] == true,
      mfaSetupRequired: json['mfaSetupRequired'] == true,
    );
  }
}

class BreezzeApiException implements Exception {
  final String code;
  final String message;
  const BreezzeApiException({required this.code, required this.message});

  @override
  String toString() => '$code: $message';
}
