import 'dart:async';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/breezze_api.dart';
import 'pending_logout_queue.dart';
import 'supabase_auth_transport.dart';
import '../../features/player/player_controller.dart';

/// Auth session state — what the UI renders.
sealed class AuthState {
  const AuthState();
}

class AuthUninitialized extends AuthState {
  const AuthUninitialized();
}

class AuthSignedOut extends AuthState {
  const AuthSignedOut();
}

class AuthSigningIn extends AuthState {
  final bool social;
  const AuthSigningIn({this.social = false});
}

class AuthSignedIn extends AuthState {
  final String userId;
  final String email;
  const AuthSignedIn({required this.userId, required this.email});
}

class AuthMfaRequired extends AuthState {
  final String userId;
  final String email;
  final bool setupRequired;
  final String? secret;
  final String? provisioningUri;

  const AuthMfaRequired({
    required this.userId,
    required this.email,
    required this.setupRequired,
    this.secret,
    this.provisioningUri,
  });
}

class AuthMfaRecoveryCodes extends AuthState {
  final String userId;
  final String email;
  final List<String> codes;

  const AuthMfaRecoveryCodes({
    required this.userId,
    required this.email,
    required this.codes,
  });
}

class AuthError extends AuthState {
  final String code;
  const AuthError(this.code);
}

/// Session controller: access tokens remain memory-only; refresh tokens use
/// iOS Keychain / Android Keystore-backed secure storage.
class AuthSessionController extends Notifier<AuthState> {
  Future<bool>? _refreshInFlight;
  String? _pendingSupabaseAccessToken;
  static const _refreshTokenKey = 'breezze.refresh_token';
  static const _secureStorage = FlutterSecureStorage();
  late final PendingLogoutQueue _pendingLogouts =
      PendingLogoutQueue(SecurePendingLogoutPersistence(_secureStorage));

  static const _configuredApiUrl = String.fromEnvironment('BREEZZE_API_URL');
  // Publishable project credentials are public. No service-role keys belong
  // in app builds. Every listener uses the dedicated Breezze Supabase project.
  static const _supabaseUrl = String.fromEnvironment(
    'BREEZZE_SUPABASE_URL',
    defaultValue: 'https://djwvyjtebmsavhcrmhxf.supabase.co',
  );
  static const _supabasePublishableKey = String.fromEnvironment(
    'BREEZZE_SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_ZloCmmQPo86OqHbH3Yqgsw_xZGPqSi3',
  );
  bool get usesSupabaseAuth => true;

  late final SupabaseAuthTransport _supabase = SupabaseAuthTransport(
    projectUrl: _supabaseUrl,
    publishableKey: _supabasePublishableKey,
  );
  static const _productionApiUrl =
      'https://breezze-api-edge.ykw8vmq7ph.workers.dev';

  late final BreezzeApi _api = BreezzeApi(
    baseUrl: _configuredApiUrl.isNotEmpty
        ? _configuredApiUrl
        : (kReleaseMode ? _productionApiUrl : 'http://localhost:3000'),
  )..onUnauthorized = _refreshAccessToken;

  @override
  AuthState build() {
    return const AuthUninitialized();
  }

  BreezzeApi get api => _api;

  Future<bool> _refreshAccessToken() async {
    final active = _refreshInFlight;
    if (active != null) return active;
    final pending = _performRefresh();
    _refreshInFlight = pending;
    try {
      return await pending;
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<bool> _performRefresh() async {
    try {
      final refreshToken = await _secureStorage.read(key: _refreshTokenKey);
      if (refreshToken == null || refreshToken.isEmpty) return false;
      final response = await _api.refresh(refreshToken);
      await _persistSession(response);
      return true;
    } catch (_) {
      _api.accessToken = null;
      try {
        await _secureStorage.delete(key: _refreshTokenKey);
      } catch (_) {}
      state = const AuthSignedOut();
      return false;
    }
  }

  /// Retry prior offline sign-outs, but never restore these old tokens as a
  /// login session. Guest mode can call this on app resume too.
  Future<void> flushPendingLogouts() async {
    try {
      await _pendingLogouts.flush((token) =>
          _api.logout(token).timeout(const Duration(seconds: 3)));
    } catch (_) {
      // Encrypted pending revocations remain on-device for another attempt.
    }
  }

  Future<void> restoreSession() async {
    unawaited(flushPendingLogouts());
    try {
      final refreshToken = await _secureStorage.read(key: _refreshTokenKey);
      if (refreshToken == null || refreshToken.isEmpty) {
        state = const AuthSignedOut();
        return;
      }
      final response = await _api.refresh(refreshToken);
      await _persistSession(response);
    } catch (_) {
      _api.accessToken = null;
      try {
        await _secureStorage.delete(key: _refreshTokenKey);
      } catch (_) {}
      state = const AuthSignedOut();
    }
  }

  Future<void> _persistSession(AuthResponse response) async {
    await _secureStorage.write(key: _refreshTokenKey, value: response.refreshToken);
    _api.accessToken = response.accessToken;
    if (response.mfaRequired) {
      state = AuthMfaRequired(
        userId: response.userId,
        email: response.email,
        setupRequired: response.mfaSetupRequired,
      );
    } else {
      state = AuthSignedIn(userId: response.userId, email: response.email);
    }
  }

  Future<void> register(
    String email,
    String password, {
    String? displayName,
  }) async {
    _pendingSupabaseAccessToken = null;
    state = const AuthSigningIn();
    try {
      final token = await _supabase.signUp(
        email.trim(), password, displayName: displayName,
      );
      if (token == null) {
        state = const AuthError('EMAIL_VERIFICATION_REQUIRED');
        return;
      }
      await _persistSession(await _api.exchangeSupabaseSession(token));
    } on SupabaseAuthTransportException catch (e) {
      state = AuthError(e.code);
    } on BreezzeApiException catch (e) {
      state = AuthError(e.code);
    } catch (_) {
      state = const AuthError('NETWORK_ERROR');
    }
  }

  Future<void> login(String email, String password) async {
    _pendingSupabaseAccessToken = null;
    state = const AuthSigningIn();
    try {
      final token = await _supabase.signIn(email.trim(), password);
      _pendingSupabaseAccessToken = token;
      await _persistSession(await _api.exchangeSupabaseSession(token));
      _pendingSupabaseAccessToken = null;
    } on SupabaseAuthTransportException catch (e) {
      _pendingSupabaseAccessToken = null;
      state = AuthError(e.code);
    } on BreezzeApiException catch (e) {
      if (e.code != 'SUPABASE_ACCOUNT_LINK_REQUIRED') {
        _pendingSupabaseAccessToken = null;
      }
      state = AuthError(e.code);
    } catch (_) {
      _pendingSupabaseAccessToken = null;
      state = const AuthError('NETWORK_ERROR');
    }
  }

  /// The only legacy migration path. A verified Supabase login must have
  /// happened first. Prove possession of the old Breezze password before
  /// the server can transfer existing library, playlists and user ID.
  Future<void> claimExistingLibrary(String email, String oldPassword) async {
    final token = _pendingSupabaseAccessToken;
    if (token == null || state is! AuthError ||
        (state as AuthError).code != 'SUPABASE_ACCOUNT_LINK_REQUIRED') {
      state = const AuthError('SUPABASE_CLAIM_NOT_READY');
      return;
    }
    state = const AuthSigningIn();
    try {
      await _persistSession(await _api.claimSupabaseLegacyAccount(
        accessToken: token,
        email: email.trim(),
        legacyPassword: oldPassword,
      ));
      _pendingSupabaseAccessToken = null;
    } on BreezzeApiException catch (e) {
      state = AuthError(e.code == 'INVALID_CREDENTIALS'
          ? 'SUPABASE_LEGACY_PASSWORD_INVALID' : e.code);
    } catch (_) {
      state = const AuthError('NETWORK_ERROR');
    }
  }

  Future<void> requestPasswordReset(String email) =>
      _supabase.requestPasswordReset(email);

  Future<void> beginMfaSetup(String password) async {
    final current = state;
    if (current is! AuthMfaRequired || !current.setupRequired) return;
    final result = await _api.beginMfaSetup(password);
    state = AuthMfaRequired(
      userId: current.userId,
      email: current.email,
      setupRequired: true,
      secret: result['secret'] as String?,
      provisioningUri: result['provisioningUri'] as String?,
    );
  }

  Future<void> verifyMfaSetup(String code) async {
    final current = state;
    if (current is! AuthMfaRequired || !current.setupRequired) return;
    final result = await _api.verifyMfaSetup(code);
    final token = result['accessToken'];
    if (token is! String || token.isEmpty) {
      throw const BreezzeApiException(code: 'MFA_TOKEN_MISSING', message: 'MFA verification did not return a session token');
    }
    _api.accessToken = token;
    final codes = (result['recoveryCodes'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList(growable: false);
    state = AuthMfaRecoveryCodes(
      userId: current.userId,
      email: current.email,
      codes: codes,
    );
  }

  Future<void> verifyMfa(String code) async {
    final current = state;
    if (current is! AuthMfaRequired || current.setupRequired) return;
    final result = await _api.verifyMfa(code);
    final token = result['accessToken'];
    if (token is! String || token.isEmpty) {
      throw const BreezzeApiException(code: 'MFA_TOKEN_MISSING', message: 'MFA verification did not return a session token');
    }
    _api.accessToken = token;
    state = AuthSignedIn(userId: current.userId, email: current.email);
  }

  void completeMfaEnrollment() {
    final current = state;
    if (current is AuthMfaRecoveryCodes) {
      state = AuthSignedIn(userId: current.userId, email: current.email);
    }
  }

  Future<void> signOut({bool allDevices = false}) async {
    // All-device revocation needs an acknowledged authenticated request.
    // If offline, preserve the current session and surface the error rather
    // than pretending other devices were signed out.
    if (allDevices) await _api.logoutAllSessions();
    ++_socialAttempt;
    // Stop the global player while the access token is still valid so its
    // server-authorized playback session is closed before account logout.
    try {
      await ref.read(playerControllerProvider.notifier).stop();
    } catch (_) {}
    String? refreshToken;
    try {
      refreshToken = await _secureStorage.read(key: _refreshTokenKey);
    } catch (_) {}
    if (!allDevices && refreshToken != null) {
      try {
        await _api.logout(refreshToken).timeout(const Duration(seconds: 3));
      } catch (_) {
        // Keep the *revocation request*, not an active login session.
        // Retry on launch/resume when the device regains connectivity.
        try {
          await _pendingLogouts.enqueue(refreshToken);
        } catch (_) {}
      }
    }
    _api.accessToken = null;
    _pendingSupabaseAccessToken = null;
    try {
      await _secureStorage.delete(key: _refreshTokenKey);
    } catch (_) {}
    state = const AuthSignedOut();
  }
}

final authSessionProvider =
    NotifierProvider<AuthSessionController, AuthState>(
  AuthSessionController.new,
);
