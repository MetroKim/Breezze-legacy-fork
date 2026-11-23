import 'package:flutter/foundation.dart' show kIsWeb;

final _deezerPreview = RegExp(r'^bz:deezer_preview:[0-9]{1,20}$');
bool isDeezerPreview(String id) => _deezerPreview.hasMatch(id);

final _youtubeSongId = RegExp(r'^bz:youtube_music:[A-Za-z0-9_-]{11}$');

bool isYouTubeSongId(String id) => _youtubeSongId.hasMatch(id);

/// A queued song still needs a source from the session resolver.
bool isMetadataOnlyTrackId(String id) =>
    id.startsWith('bzv:') ||
    (id.startsWith('bz:') && !id.startsWith('bz:jamendo:') && !isYouTubeSongId(id) && !isDeezerPreview(id));

bool canQueueTrackId(String id) => id.trim().isNotEmpty && !isMetadataOnlyTrackId(id);

/// Offline media requires an explicit download grant. Generic catalogue
/// metadata (including Jamendo) cannot be downloaded by a discovery URL.
bool canRequestOfflineDownload(String id) =>
    !kIsWeb &&
    id.trim().isNotEmpty &&
    !id.startsWith('bz:') &&
    !id.startsWith('bzv:');

/// Fallbacks must identify the same performance. Reject ambiguous editions.
String? matchingDeezerPreview(Object? rows, String title, String artist, Duration duration) {
  if (rows is! List) return null;
  String normalize(String value) => value.trim().toLowerCase();
  final candidates = rows.whereType<Map>().where((row) {
    final seconds = row['durationSec'];
    return row['title'] is String && normalize(row['title'] as String) == normalize(title) &&
        row['artist'] is String && normalize(row['artist'] as String) == normalize(artist) &&
        (duration == Duration.zero || seconds is num && (seconds - duration.inSeconds).abs() <= 3) &&
        row['previewUrl'] is String && isDeezerPreview('bz:deezer_preview:${row['providerTrackId']}');
  }).map((row) => row['providerTrackId'].toString()).toSet();
  return candidates.length == 1 ? candidates.first : null;
}
