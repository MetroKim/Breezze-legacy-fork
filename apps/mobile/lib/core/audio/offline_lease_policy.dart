/// Local offline files are playable only while the backend-issued lease
/// remains valid. A legacy metadata row without an expiry has no grant.
bool hasValidOfflineLease(DateTime? expiresAtUtc, {DateTime? nowUtc}) {
  if (expiresAtUtc == null) return false;
  final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
  return expiresAtUtc.toUtc().isAfter(now);
}
