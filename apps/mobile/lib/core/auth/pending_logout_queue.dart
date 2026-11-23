import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Pending server-side session revocations must survive a network outage
/// without keeping the token usable as Breezze's active local session.
abstract class PendingLogoutPersistence {
  Future<Map<String, String>> readAll();
  Future<void> put(String key, String value);
  Future<void> delete(String key);
}

class SecurePendingLogoutPersistence implements PendingLogoutPersistence {
  SecurePendingLogoutPersistence(this.storage);

  final FlutterSecureStorage storage;

  @override
  Future<Map<String, String>> readAll() => storage.readAll();

  @override
  Future<void> put(String key, String value) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

/// Stores refresh tokens *only* for future revocation in encrypted storage.
/// These tokens are never restored as active credentials, exposed to the UI,
/// exported, logged, or used to acquire new access tokens.
class PendingLogoutQueue {
  PendingLogoutQueue(this._storage);

  static const prefix = 'breezze.pending-logout.';
  final PendingLogoutPersistence _storage;
  int _sequence = 0;

  Future<void> enqueue(String refreshToken) async {
    if (refreshToken.isEmpty) return;
    final key = '$prefix${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    await _storage.put(key, refreshToken);
  }

  Future<int> flush(Future<void> Function(String token) revoke) async {
    final all = await _storage.readAll();
    var revokedCount = 0;
    for (final entry in all.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      try {
        if (entry.value.isNotEmpty) await revoke(entry.value);
        await _storage.delete(entry.key);
        revokedCount++;
      } catch (_) {
        // Preserve this token for a future retry when the network recovers.
      }
    }
    return revokedCount;
  }
}
