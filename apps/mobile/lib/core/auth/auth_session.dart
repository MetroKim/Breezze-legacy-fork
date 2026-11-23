import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/breezze_api.dart';
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
  int _socialAttempt = 0;
  static const _refreshTokenKey = 'breezze.refresh_token';
  static const _secureStorage = FlutterSecureStorage();

  static const _configuredApiUrl = String.fromEnvironment('BREEZZE_API_URL');
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

  Future<void> restoreSession() async {
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
    state = const AuthSigningIn();
    try {
      final response = await _api.register(email, password,
          displayName: displayName);
      await _persistSession(response);
    } on BreezzeApiException catch (e) {
      state = AuthError(e.code);
    } catch (_) {
      state = const AuthError('NETWORK_ERROR');
    }
  }

  Future<void> login(String email, String password) async {
    state = const AuthSigningIn();
    try {
      final response = await _api.login(email, password);
      await _persistSession(response);
    } on BreezzeApiException catch (e) {
      state = AuthError(e.code);
    } catch (_) {
      state = const AuthError('NETWORK_ERROR');
    }
  }

  Future<void> socialLogin(
    String provider, {
    Map<String, dynamic>? preparedFlow,
  }) async {
    final attempt = ++_socialAttempt;
    state = const AuthSigningIn(social: true);
    try {
      // Preloaded flow keeps launchUrl on the original pointer activation
      // for browsers that block asynchronous popups.
      final flow = preparedFlow ?? await _api.startSocialLogin(provider);
      if (attempt != _socialAttempt) return;
      final flowId = flow['id'];
      final pollSecret = flow['secret'];
      final authorizationUrl = Uri.tryParse(flow['authorizationUrl'] as String? ?? '');
      if (flowId is! String || pollSecret is! String ||
          authorizationUrl == null || authorizationUrl.scheme != 'https') {
        throw const BreezzeApiException(
          code: 'SOCIAL_FLOW_INVALID',
          message: 'The sign-in provider returned an invalid authorization URL.',
        );
      }
      if (!await launchUrl(authorizationUrl, mode: LaunchMode.externalApplication)) {
        throw const BreezzeApiException(
          code: 'SOCIAL_BROWSER_UNAVAILABLE',
          message: 'Cannot open the secure system browser for sign-in.',
        );
      }
      // The system browser never sees Breezze refresh tokens. The app
      // redeems a single-use random pairing secret through the own backend.
      for (var n = 0; n < 150; n++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (attempt != _socialAttempt) return;
        final result = await _api.pollSocialLogin(flowId: flowId, secret: pollSecret);
        if (attempt != _socialAttempt) return;
        if (result['status'] == 'pending') continue;
        if (result['status'] == 'completed' && result['session'] is Map) {
          final session = AuthResponse.fromJson(
            Map<String, dynamic>.from(result['session'] as Map),
          );
          if (attempt != _socialAttempt) return;
          await _persistSession(session);
          return;
        }
        throw BreezzeApiException(
          code: result['code'] as String? ?? 'SOCIAL_AUTH_FAILED',
          message: 'The identity provider could not complete the sign-in.',
        );
      }
      throw const BreezzeApiException(
        code: 'SOCIAL_AUTH_EXPIRED',
        message: 'The browser sign-in timed out. You can try again.',
      );
    } on BreezzeApiException catch (e) {
      if (attempt == _socialAttempt) state = AuthError(e.code);
    } catch (_) {
      if (attempt == _socialAttempt) state = const AuthError('SOCIAL_AUTH_FAILED');
    }
  }

  void cancelSocialLogin() {
    ++_socialAttempt;
    if (state is AuthSigningIn) state = const AuthSignedOut();
  }

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
        await _api.logout(refreshToken);
      } catch (_) {
        // Local logout must still complete when the network is unavailable.
      }
    }
    _api.accessToken = null;
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
