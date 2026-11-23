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
}
