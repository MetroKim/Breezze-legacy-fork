import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Breezze never receives a Google/Apple password. The native platform prompt
/// issues an identity token, which Supabase Auth verifies with that provider.
/// Only a short-lived Supabase access token reaches the Breezze API bridge.
class NativeSocialCredential {
  const NativeSocialCredential(this.provider, this.idToken, {this.nonce});
  final String provider;
  final String idToken;
  final String? nonce;
}

class NativeSocialSignInException implements Exception {
  const NativeSocialSignInException(this.code);
  final String code;
}

class NativeSocialSignIn {
  static const googleWebClientId =
      String.fromEnvironment('BREEZZE_GOOGLE_WEB_CLIENT_ID');
  static const googleIosClientId =
      String.fromEnvironment('BREEZZE_GOOGLE_IOS_CLIENT_ID');
  static const appleEnabled =
      bool.fromEnvironment('BREEZZE_APPLE_SIGN_IN_ENABLED');

  Future<void>? _googleInitialization;

  bool available(String provider) {
    if (kIsWeb) return false;
    if (provider == 'google') {
      return googleWebClientId.isNotEmpty &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);
    }
    if (provider == 'apple') {
      return appleEnabled &&
          (defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.macOS);
    }
    return false;
  }

  Future<NativeSocialCredential> authenticate(String provider) async {
    if (!available(provider)) {
      throw const NativeSocialSignInException('SOCIAL_PROVIDER_NOT_CONFIGURED');
    }
    if (provider == 'google') {
      try {
        final signIn = GoogleSignIn.instance;
        _googleInitialization ??= signIn.initialize(
          clientId: defaultTargetPlatform == TargetPlatform.iOS &&
                  googleIosClientId.isNotEmpty
              ? googleIosClientId
              : null,
          serverClientId: googleWebClientId,
        );
        await _googleInitialization;
        if (!signIn.supportsAuthenticate()) {
          throw const NativeSocialSignInException('SOCIAL_PLATFORM_UNSUPPORTED');
        }
        final account = await signIn.authenticate();
        final token = account.authentication.idToken;
        if (token == null || token.isEmpty) {
          throw const NativeSocialSignInException('SOCIAL_TOKEN_INVALID');
        }
        return NativeSocialCredential('google', token);
      } on NativeSocialSignInException {
        rethrow;
      } catch (_) {
        throw const NativeSocialSignInException('SOCIAL_AUTH_FAILED');
      }
    }
    if (provider == 'apple') {
      final rawNonce = _randomNonce();
      final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
      try {
        final credential = await SignInWithApple.getAppleIDCredential(
          scopes: [
            AppleIDAuthorizationScopes.email,
            AppleIDAuthorizationScopes.fullName,
          ],
          nonce: hashedNonce,
        );
        final token = credential.identityToken;
        if (token == null || token.isEmpty) {
          throw const NativeSocialSignInException('SOCIAL_TOKEN_INVALID');
        }
        return NativeSocialCredential('apple', token, nonce: rawNonce);
      } on NativeSocialSignInException {
        rethrow;
      } catch (_) {
        throw const NativeSocialSignInException('SOCIAL_AUTH_FAILED');
      }
    }
    throw const NativeSocialSignInException('INVALID_PROVIDER');
  }

  String _randomNonce() {
    const alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    final random = Random.secure();
    return List.generate(32, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }
}
