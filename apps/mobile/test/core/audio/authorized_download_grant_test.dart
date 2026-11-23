import 'package:breezze/core/audio/authorized_download_grant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 23, 10);
  final signedExpiry = now.add(const Duration(minutes: 5));
  final leaseExpiry = now.add(const Duration(hours: 6));
  final rightsExpiry = now.add(const Duration(hours: 8));

  Map<String, dynamic> grant() => {
    'allowed': true,
    'url': 'https://media.example.org/download?sig=redacted',
    'expiresAt': signedExpiry.toIso8601String(),
    'offlineLeaseExpiresAt': leaseExpiry.toIso8601String(),
    'rightsExpiresAt': rightsExpiry.toIso8601String(),
    'assetVersion': 'master-42:aac256',
  };

  test('accepts short lived URL with bounded offline lease', () {
    final result = AuthorizedDownloadGrant.fromResponse(
      grant(), nowUtc: now,
    );
    expect(result, isNotNull);
    expect(result!.offlineLeaseExpiresAtUtc, leaseExpiry);
    expect(result.assetVersion, 'master-42:aac256');
  });

  test('rejects missing, expired or overly long offline lease', () {
    final missing = grant()..remove('offlineLeaseExpiresAt');
    expect(AuthorizedDownloadGrant.fromResponse(missing, nowUtc: now), isNull);
    final expired = grant()..['offlineLeaseExpiresAt'] =
        now.subtract(const Duration(seconds: 1)).toIso8601String();
    expect(AuthorizedDownloadGrant.fromResponse(expired, nowUtc: now), isNull);
    final excessive = grant()..['offlineLeaseExpiresAt'] =
        now.add(const Duration(days: 4)).toIso8601String();
    expect(AuthorizedDownloadGrant.fromResponse(excessive, nowUtc: now), isNull);
  });

  test('rejects expired signed URL or lease beyond rights end', () {
    final stale = grant()..['expiresAt'] =
        now.subtract(const Duration(seconds: 1)).toIso8601String();
    expect(AuthorizedDownloadGrant.fromResponse(stale, nowUtc: now), isNull);
    final overRights = grant()..['rightsExpiresAt'] =
        now.add(const Duration(minutes: 20)).toIso8601String();
    expect(AuthorizedDownloadGrant.fromResponse(overRights, nowUtc: now), isNull);
  });

  test('rejects untrusted or preview-only sources', () {
    final preview = grant()..['previewOnly'] = true;
    expect(AuthorizedDownloadGrant.fromResponse(preview, nowUtc: now), isNull);
    final denied = grant()..['allowed'] = false;
    expect(AuthorizedDownloadGrant.fromResponse(denied, nowUtc: now), isNull);
    for (final url in [
      'http://media.example.org/download',
      'https://user:pass@media.example.org/download',
      'https://media.example.org/download#fragment',
      'file:///tmp/download',
    ]) {
      expect(AuthorizedDownloadGrant.fromResponse(
        grant()..['url'] = url, nowUtc: now,
      ), isNull, reason: url);
    }
  });

  test('untrusted asset version does not enable partial resume', () {
    final data = grant()..['assetVersion'] = 'https://other.invalid/media?token=secret';
    final result = AuthorizedDownloadGrant.fromResponse(data, nowUtc: now);
    expect(result, isNotNull);
    expect(result!.assetVersion, isNull);
  });
}
