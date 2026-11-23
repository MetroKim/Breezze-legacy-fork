import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Native session persistence for Supabase Auth.
///
/// Supabase still owns refresh and sign-out; this adapter only replaces the
/// default shared-preferences persistence with OS-backed secure storage.
/// Web keeps Supabase's standard browser storage implementation.
class BreezzeSecureSessionStorage extends LocalStorage {
  BreezzeSecureSessionStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = supabasePersistSessionKey;
  final FlutterSecureStorage _storage;

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> accessToken() => _storage.read(key: _key);

  @override
  Future<bool> hasAccessToken() => _storage.containsKey(key: _key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: _key);
}
