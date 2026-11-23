import 'dart:convert';

import 'package:breezze/core/auth/supabase_auth_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Supabase password sign-in uses only a public key and returns an ephemeral JWT', () async {
    late http.Request sent;
    final transport = SupabaseAuthTransport(
      projectUrl: 'https://breezzetest.supabase.co',
      publishableKey: 'sb_publishable_test',
      client: MockClient((request) async {
        sent = request;
        return http.Response(jsonEncode({'access_token': 'temporary-user-jwt'}), 200);
      }),
    );

    expect(await transport.signIn('listener@example.test', 'password'), 'temporary-user-jwt');
    expect(sent.url.toString(),
        'https://breezzetest.supabase.co/auth/v1/token?grant_type=password');
    expect(sent.headers['apikey'], 'sb_publishable_test');
    expect(jsonDecode(sent.body)['email'], 'listener@example.test');
    expect(sent.headers.containsKey('Authorization'), false);
  });

  test('unverified signup requests email confirmation instead of claiming an active login', () async {
    final transport = SupabaseAuthTransport(
      projectUrl: 'https://breezzetest.supabase.co',
      publishableKey: 'sb_publishable_test',
      client: MockClient((request) async {
        expect(request.url.path, '/auth/v1/signup');
        expect(jsonDecode(request.body)['data']['display_name'], 'Breezze Listener');
        return http.Response('{"user":{"id":"some-user"},"session":null}', 200);
      }),
    );
    expect(await transport.signUp(
      'listener@example.test',
      'a-secure-password',
      displayName: 'Breezze Listener',
    ), isNull);
  });

  test('wrong credentials return a generic error without leaking provider body', () async {
    final transport = SupabaseAuthTransport(
      projectUrl: 'https://breezzetest.supabase.co',
      publishableKey: 'sb_publishable_test',
      client: MockClient((_) async => http.Response(
        '{"msg":"contains private information"}', 400,
      )),
    );
    await expectLater(transport.signIn('a@example.test', 'bad'), throwsA(
      isA<SupabaseAuthTransportException>().having(
        (value) => value.code, 'code', 'INVALID_CREDENTIALS',
      ),
    ));
  });

  test('rejects a Supabase lookalike host before sending credentials', () async {
    var requested = false;
    final transport = SupabaseAuthTransport(
      projectUrl: 'https://breezzetest.supabase.co.evil.example',
      publishableKey: 'sb_publishable_test',
      client: MockClient((_) async {
        requested = true;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(transport.signIn('a@example.test', 'password'), throwsA(
      isA<SupabaseAuthTransportException>(),
    ));
    expect(requested, isFalse);
  });
  test('Google ID-token grant validates through Supabase Auth, never a second provider backend', () async {
    late http.Request sent;
    final transport = SupabaseAuthTransport(
      projectUrl: 'https://breezzetest.supabase.co',
      publishableKey: 'sb_publishable_test',
      client: MockClient((request) async {
        sent = request;
        return http.Response('{"access_token":"ephemeral-supabase-jwt"}', 200);
      }),
    );
    expect(await transport.signInWithIdToken(
      provider: 'google', idToken: 'signed-google-id-token',
    ), 'ephemeral-supabase-jwt');
    expect(sent.url.path, '/auth/v1/token');
    expect(sent.url.queryParameters['grant_type'], 'id_token');
    expect(sent.headers['apikey'], 'sb_publishable_test');
    expect(jsonDecode(sent.body), {
      'provider': 'google', 'id_token': 'signed-google-id-token',
    });
  });

  test('Apple passes raw nonce to Supabase while native Apple receives SHA256', () async {
    late http.Request sent;
    final transport = SupabaseAuthTransport(
      projectUrl: 'https://breezzetest.supabase.co',
      publishableKey: 'sb_publishable_test',
      client: MockClient((request) async {
        sent = request;
        return http.Response('{"access_token":"verified-jwt"}', 200);
      }),
    );
    await transport.signInWithIdToken(
      provider: 'apple', idToken: 'signed-apple-id-token',
      nonce: 'secure-raw-nonce',
    );
    expect(jsonDecode(sent.body), {
      'provider': 'apple', 'id_token': 'signed-apple-id-token',
      'nonce': 'secure-raw-nonce',
    });
  });

  test('other identity providers are denied before sending any request', () async {
    var requests = 0;
    final transport = SupabaseAuthTransport(
      projectUrl: 'https://breezzetest.supabase.co',
      publishableKey: 'sb_publishable_test',
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(transport.signInWithIdToken(
      provider: 'auth0', idToken: 'invalid-token',
    ), throwsA(isA<SupabaseAuthTransportException>()));
    expect(requests, 0);
  });

}
