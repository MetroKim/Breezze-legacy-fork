import 'package:flutter_test/flutter_test.dart';
import 'package:breezze/core/audio/playback_source_policy.dart';

void main() {
  group('Breezze provider action policy', () {
    test('discovery-only IDs never enter the native audio queue', () {
      for (final id in [
        'bz:youtube_music:abc',
        'bz:deezer:invalid',
        'bz:soundcloud:456',
        'bz:audius:retired',
        'bz:apple_catalog:789',
        'bzv:dQw4w9WgXcQ',
        '',
      ]) {
        expect(canQueueTrackId(id), isFalse, reason: id);
      }
    });

    test('local or backend tracks and approved Jamendo can request playback', () {
      expect(canQueueTrackId('catalog-uuid'), isTrue);
      expect(canQueueTrackId('bz:deezer:123'), isTrue);
      expect(canQueueTrackId('bz:deezer_preview:42'), isTrue);
      expect(canQueueTrackId('bz:deezer_preview:nope'), isFalse);
      expect(canRequestOfflineDownload('bz:deezer_preview:42'), isFalse);
      expect(canQueueTrackId('bz:jamendo:track-123'), isTrue);
      expect(isMetadataOnlyTrackId('bz:jamendo:track-123'), isFalse);
    });

    test('fallback requires an unambiguous preview of the selected recording', () {
      const duration = Duration(seconds: 210);
      final row = {'title': 'Song', 'artist': 'Artist', 'durationSec': 212,
          'providerTrackId': '42', 'previewUrl': 'https://example.org/test.mp3'};
      expect(matchingDeezerPreview([row], 'Song', 'Artist', duration), '42');
      expect(matchingDeezerPreview([row, {...row, 'providerTrackId': '43'}], 'Song', 'Artist', duration), isNull);
      expect(matchingDeezerPreview([row], 'Song (Live)', 'Artist', duration), isNull);
      expect(matchingDeezerPreview([row], 'Song', 'Artist', const Duration(seconds: 120)), isNull);
    });

    test('metadata and embedded videos never request offline downloads', () {
      expect(canRequestOfflineDownload('bz:jamendo:123'), isFalse);
      expect(canRequestOfflineDownload('bz:deezer:123'), isFalse);
      expect(canRequestOfflineDownload('bzv:dQw4w9WgXcQ'), isFalse);
      expect(canRequestOfflineDownload('catalog-uuid'), isTrue);
    });

    test('YouTube song IDs can request native playback', () {
      const id = 'bz:youtube_music:dQw4w9WgXcQ';
      expect(isYouTubeSongId(id), isTrue);
      expect(canQueueTrackId(id), isTrue);
      expect(canRequestOfflineDownload(id), isFalse);
      expect(isYouTubeSongId('bz:youtube_music:invalid'), isFalse);
      expect(isYouTubeSongId('bz:deezer:dQw4w9WgXcQ'), isFalse);
    });
  });
}
