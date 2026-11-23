import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:breezze/core/api/breezze_api.dart';

void main() {
  test('social providers are discovered from the backend, not hardcoded', () async {
    late http.Request captured;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'data': {'google': true, 'apple': false}}), 200,
        );
      }),
    );
    final providers = await api.socialProviders();
    expect(providers, {'google': true, 'apple': false});
    expect(captured.method, 'GET');
    expect(captured.url.path, '/api/v1/auth/social/providers');
  });

  test('starting Google OAuth returns app-only one-time pairing details', () async {
    late http.Request captured;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode({'data': {
          'id': 'flow-id',
          'secret': 'app-only-random-secret',
          'authorizationUrl': 'https://accounts.google.com/o/oauth2/v2/auth',
        }}), 200);
      }),
    );
    final started = await api.startSocialLogin('google');
    expect(started['id'], 'flow-id');
    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/v1/auth/social/google/start');
    expect(captured.url.query, isEmpty);
    expect(captured.body, '{}');
  });

  test('invalid provider does not result in an HTTP request', () async {
    var calls = 0;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    expect(() => api.startSocialLogin('untrusted'), throwsArgumentError);
    expect(calls, 0);
  });

  test('polling sends secret inside POST body, never URL', () async {
    late http.Request captured;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode({'data': {
          'status': 'completed',
          'session': {
            'accessToken': 'access',
            'refreshToken': 'refresh',
            'user': {'id': 'user-1', 'email': 'user@example.com'},
          },
        }}), 200);
      }),
    );
    final result = await api.pollSocialLogin(flowId: 'flow-id',
      secret: 'browser-must-not-know-this-secret');
    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/v1/auth/social/poll');
    expect(captured.url.query, isEmpty);
    expect(jsonDecode(captured.body), {
      'id': 'flow-id',
      'secret': 'browser-must-not-know-this-secret',
    });
    expect(AuthResponse.fromJson(
      Map<String, dynamic>.from(result['session'] as Map)).userId, 'user-1');
  });
  test('embedded Auth0 login uses Breezze themed screen API without browser URL', () async {
    late http.Request request;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((sent) async {
        request = sent;
        return http.Response(jsonEncode({'data': {
          'accessToken': 'test-breezze-access',
          'refreshToken': 'test-breezze-refresh',
          'user': {'id':'listener-1','email':'listener@example.com'},
        }}), 200);
      }),
    );
    final result = await api.loginAuth0Embedded('listener@example.com', 'private-password');
    expect(result.userId, 'listener-1');
    expect(request.method, 'POST');
    expect(request.url.path, '/api/v1/auth/auth0/login');
    expect(request.url.query, isEmpty);
    expect(jsonDecode(request.body), {
      'email':'listener@example.com','password':'private-password',
    });
    expect(request.headers['Authorization'], isNull);
  });

  test('embedded registration waits for email verification, no token is returned', () async {
    late http.Request request;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((sent) async {
        request = sent;
        return http.Response(jsonEncode({'data': {'verificationRequired':true}}), 202);
      }),
    );
    await api.registerAuth0Embedded('listener@example.com', 'long-password',
      displayName:' Listener ');
    expect(request.url.path, '/api/v1/auth/auth0/register');
    expect(jsonDecode(request.body), {
      'email':'listener@example.com','password':'long-password',
      'displayName':'Listener',
    });
  });

  test('Auth0 password reset and existing-account link are both Breezze endpoints', () async {
    final requests = <http.Request>[];
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((sent) async {
        requests.add(sent);
        return http.Response(jsonEncode({'data': {'sent':true,'linked':true}}), 200);
      }),
    );
    await api.sendAuth0PasswordReset('listener@example.com');
    api.accessToken = 'existing-breezze-access';
    await api.linkAuth0Embedded('listener@example.com','password');
    expect(requests[0].url.path, '/api/v1/auth/auth0/password/reset');
    expect(requests[1].url.path, '/api/v1/auth/auth0/link');
    expect(requests[1].headers['authorization'], 'Bearer existing-breezze-access');
  });

}
