import 'package:breezze/core/audio/offline_lease_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 23, 12);

  test('missing offline lease is never a perpetual entitlement', () {
    expect(hasValidOfflineLease(null, nowUtc: now), isFalse);
  });

  test('expired or exact-boundary lease cannot play', () {
    expect(
      hasValidOfflineLease(now.subtract(const Duration(milliseconds: 1)),
          nowUtc: now), isFalse,
    );
    expect(hasValidOfflineLease(now, nowUtc: now), isFalse);
  });

  test('future server-issued lease permits local playback', () {
    expect(
      hasValidOfflineLease(now.add(const Duration(hours: 4)), nowUtc: now),
      isTrue,
    );
  });

  test('offset-aware lease comparison always uses UTC', () {
    final withOffset = DateTime.parse('2026-11-23T15:00:01+03:00');
    expect(hasValidOfflineLease(withOffset, nowUtc: now), isTrue);
  });
}
