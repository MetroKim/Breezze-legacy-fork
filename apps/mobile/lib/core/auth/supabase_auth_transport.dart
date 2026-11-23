import 'dart:convert';

import 'package:http/http.dart' as http;

/// Sign-in transport for verified Supabase users. Only a PUBLIC publishable
/// key belongs in the client. Returned Supabase access tokens are used once
/// for backend identity exchange and are never persisted by this transport.
class SupabaseAuthTransport {
  SupabaseAuthTransport({
    required this.projectUrl,
    required this.publishableKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String projectUrl;
  final String publishableKey;
  final http.Client _client;

  Uri _endpoint(String path, [Map<String, String>? query]) {
    final url = Uri.tryParse(projectUrl);
    if (url == null ||
        url.scheme != 'https' ||
        !RegExp(r'^[a-z0-9-]+\.supabase\.co$').hasMatch(url.host) ||
        url.path.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        publishableKey.isEmpty) {
      throw const SupabaseAuthTransportException('SUPABASE_AUTH_NOT_CONFIGURED');
    }
    return url.replace(path: '/auth/v1$path', queryParameters: query);
  }

  Future<Map<String, dynamic>> _send(Uri url, Map<String, dynamic> data) async {
    final response = await _client
        .post(url,
          headers: {
            'apikey': publishableKey,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(data),
        )
        .timeout(const Duration(seconds: 12));
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const SupabaseAuthTransportException('SUPABASE_AUTH_INVALID_RESPONSE');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const SupabaseAuthTransportException('SUPABASE_AUTH_INVALID_RESPONSE');
    }
    if (response.statusCode >= 400) {
      // Never expose provider diagnostics containing PII or raw credentials
      // as user-facing error messages.
      if (response.statusCode == 400 || response.statusCode == 401) {
        throw const SupabaseAuthTransportException('INVALID_CREDENTIALS');
      }
      if (response.statusCode == 429) {
        throw const SupabaseAuthTransportException('RATE_LIMITED');
      }
      throw const SupabaseAuthTransportException('SUPABASE_AUTH_UNAVAILABLE');
    }
    return decoded;
  }

  Future<String> signIn(String email, String password) async {
    final data = await _send(
      _endpoint('/token', {'grant_type': 'password'}),
      {'email': email, 'password': password},
    );
    final token = data['access_token'];
    if (token is! String || token.isEmpty) {
      throw const SupabaseAuthTransportException('SUPABASE_AUTH_INVALID_RESPONSE');
    }
    return token;
  }

  /// With email confirmation enabled Supabase returns a user but no session.
  /// The UI must ask the listener to confirm the email, never fake success.
  Future<String?> signUp(String email, String password, {String? displayName}) async {
    final data = await _send(_endpoint('/signup'), {
      'email': email,
      'password': password,
      if (displayName != null && displayName.trim().isNotEmpty)
        'data': {'display_name': displayName.trim()},
    });
    final token = data['access_token'];
    return token is String && token.isNotEmpty ? token : null;
  }
}

class SupabaseAuthTransportException implements Exception {
  const SupabaseAuthTransportException(this.code);
  final String code;
}
