import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, kReleaseMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import '../api/breezze_api.dart';
import '../../features/player/player_controller.dart';

/// Supabase Auth is Breezze's only identity and session authority.
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

class AuthEmailConfirmationRequired extends AuthState {
  final String email;
  const AuthEmailConfirmationRequired(this.email);
}

class AuthError extends AuthState {
  final String code;
  const AuthError(this.code);
}

class AuthSessionController extends Notifier<AuthState> {
  static const _configuredApiUrl = String.fromEnvironment('BREEZZE_API_URL');
  static const _productionApiUrl =
      'https://breezze-api-edge.ykw8vmq7ph.workers.dev';
  static const _googleWebClientId =
      String.fromEnvironment('GOOGLE_WEB_CLIENT_ID',
        defaultValue:
            '990493102909-6pj8hj2nkthcrb2a807mjnhhrgf5pqo7.apps.googleusercontent.com');
  static const _googleIosClientId =
      String.fromEnvironment('GOOGLE_IOS_CLIENT_ID',
        defaultValue:
            '990493102909-pg9d31ongdv2aghv53vb3uttgha9jnn3.apps.googleusercontent.com');
  static const _callback = 'io.breezze.app://login-callback/';

  StreamSubscription<supa.AuthState>? _sessionListener;
  Future<void>? _googleInitialization;
  Future<bool>? _refreshInFlight;

  late final BreezzeApi _api = BreezzeApi(
    baseUrl: _configuredApiUrl.isNotEmpty
        ? _configuredApiUrl
        : (kReleaseMode ? _productionApiUrl : 'http://localhost:3000'),
  )..onUnauthorized = _refreshAccessToken;

  supa.SupabaseClient get _client => supa.Supabase.instance.client;
  BreezzeApi get api => _api;

  @override
  AuthState build() {
    ref.onDispose(() {
      _sessionListener?.cancel();
      _api.accessToken = null;
    });
    return const AuthUninitialized();
  }

  void _applySession(supa.Session? session) {
    final identity = session?.user;
    final email = identity?.email;
    _api.accessToken = session?.accessToken;
    if (identity != null && email != null && email.isNotEmpty) {
      state = AuthSignedIn(userId: identity.id, email: email);
    } else {
      state = const AuthSignedOut();
    }
  }

  Future<void> restoreSession() async {
    _sessionListener ??= _client.auth.onAuthStateChange.listen(
      (event) => _applySession(event.session),
      onError: (Object _) {
        // Network failures do not destroy an otherwise valid local session.
      },
    );
    _applySession(_client.auth.currentSession);
  }

  Future<bool> _refreshAccessToken() async {
    final inflight = _refreshInFlight;
    if (inflight != null) return inflight;
    final future = _refreshSession();
    _refreshInFlight = future;
    try {
      return await future;
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<bool> _refreshSession() async {
    try {
      final response = await _client.auth.refreshSession();
      if (response.session == null) return false;
      _applySession(response.session);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> login(String email, String password) async {
    state = const AuthSigningIn();
    try {
      final response = await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      if (response.session == null) {
        state = const AuthError('INVALID_CREDENTIALS');
      } else {
        _applySession(response.session);
      }
    } on supa.AuthException catch (error) {
      state = AuthError(_authError(error));
    } catch (_) {
      state = const AuthError('NETWORK_ERROR');
    }
  }

  Future<void> register(
    String email,
    String password, {
    String? displayName,
  }) async {
    state = const AuthSigningIn();
    try {
      final result = await _client.auth.signUp(
        email: email.trim(),
        password: password,
        emailRedirectTo: kIsWeb ? Uri.base.origin : _callback,
        data: displayName == null || displayName.isEmpty
            ? null
            : {'full_name': displayName},
      );
      if (result.session != null) {
        _applySession(result.session);
      } else {
        state = AuthEmailConfirmationRequired(email.trim());
      }
    } on supa.AuthException catch (error) {
      state = AuthError(_authError(error));
    } catch (_) {
      state = const AuthError('NETWORK_ERROR');
    }
  }

  Future<void> socialLogin(String provider) async {
    state = const AuthSigningIn(social: true);
    try {
      if (provider == 'google') {
        await _signInWithGoogle();
      } else if (provider == 'apple') {
        await _signInWithApple();
      } else {
        state = const AuthError('PROVIDER_UNSUPPORTED');
        return;
      }
      // OAuth returns before the system browser completes. The Supabase
      // auth-state stream moves the user into Breezze once the callback lands.
      if (state is AuthSigningIn) {
        _applySession(_client.auth.currentSession);
      }
    } on GoogleSignInException catch (error) {
      state = error.code.name == 'canceled'
          ? const AuthSignedOut()
          : const AuthError('SOCIAL_AUTH_FAILED');
    } on supa.AuthException catch (error) {
      state = AuthError(_authError(error));
    } catch (_) {
      state = const AuthError('SOCIAL_AUTH_FAILED');
    }
  }

  Future<void> _signInWithGoogle() async {
    final isMobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (!isMobile) {
      await _client.auth.signInWithOAuth(
        supa.OAuthProvider.google,
        redirectTo: kIsWeb ? Uri.base.origin : _callback,
      );
      return;
    }
    if (_googleWebClientId.isEmpty ||
        (defaultTargetPlatform == TargetPlatform.iOS &&
            _googleIosClientId.isEmpty)) {
      throw const supa.AuthException('GOOGLE_SETUP_REQUIRED');
    }
    _googleInitialization ??= GoogleSignIn.instance.initialize(
      clientId: defaultTargetPlatform == TargetPlatform.iOS
          ? _googleIosClientId
          : null,
      serverClientId: _googleWebClientId,
    );
    await _googleInitialization;
    final account = await GoogleSignIn.instance.authenticate();
    final identityToken = account.authentication.idToken;
    if (identityToken == null) {
      throw const supa.AuthException('GOOGLE_ID_TOKEN_MISSING');
    }
    final response = await _client.auth.signInWithIdToken(
      provider: supa.OAuthProvider.google,
      idToken: identityToken,
    );
    _applySession(response.session);
  }

  Future<void> _signInWithApple() async {
    final native = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (!native) {
      await _client.auth.signInWithOAuth(
        supa.OAuthProvider.apple,
        redirectTo: kIsWeb ? Uri.base.origin : _callback,
      );
      return;
    }
    if (!await SignInWithApple.isAvailable()) {
      throw const supa.AuthException('APPLE_UNAVAILABLE');
    }
    final rawNonce = _client.auth.generateRawNonce();
    final nonceHash = sha256.convert(utf8.encode(rawNonce)).toString();
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: nonceHash,
    );
    final identityToken = credential.identityToken;
    if (identityToken == null) {
      throw const supa.AuthException('APPLE_ID_TOKEN_MISSING');
    }
    final response = await _client.auth.signInWithIdToken(
      provider: supa.OAuthProvider.apple,
      idToken: identityToken,
      nonce: rawNonce,
    );
    final givenName = credential.givenName?.trim() ?? '';
    final familyName = credential.familyName?.trim() ?? '';
    final fullName = [givenName, familyName]
        .where((value) => value.isNotEmpty).join(' ');
    if (fullName.isNotEmpty) {
      await _client.auth.updateUser(supa.UserAttributes(
        data: {'full_name': fullName},
      ));
    }
    _applySession(response.session ?? _client.auth.currentSession);
  }

  String _authError(supa.AuthException error) {
    final message = error.message.toLowerCase();
    if (message.contains('google_setup_required')) return 'GOOGLE_SETUP_REQUIRED';
    if (message.contains('apple_unavailable')) return 'APPLE_UNAVAILABLE';
    if (message.contains('password') && message.contains('short')) {
      return 'PASSWORD_TOO_SHORT';
    }
    if (message.contains('invalid login') ||
        message.contains('invalid credentials')) {
      return 'INVALID_CREDENTIALS';
    }
    if (message.contains('rate limit')) return 'RATE_LIMITED';
    return 'AUTH_FAILED';
  }

  void resetToSignedOut() {
    if (state is! AuthSignedIn) state = const AuthSignedOut();
  }

  Future<void> signOut() async {
    try {
      await ref.read(playerControllerProvider.notifier).stop();
    } catch (_) {}
    try {
      await _client.auth.signOut();
    } finally {
      _api.accessToken = null;
      state = const AuthSignedOut();
    }
  }

  Future<void> signOutEverywhere() async {
    try {
      await ref.read(playerControllerProvider.notifier).stop();
    } catch (_) {}
    try {
      await _client.auth.signOut(scope: supa.SignOutScope.global);
    } finally {
      _api.accessToken = null;
      state = const AuthSignedOut();
    }
  }
}

final authSessionProvider =
    NotifierProvider<AuthSessionController, AuthState>(
  AuthSessionController.new,
);
