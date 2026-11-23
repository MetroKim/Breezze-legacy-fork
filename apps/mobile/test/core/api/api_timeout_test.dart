import 'dart:async';

import 'package:breezze/core/api/breezze_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('all HTTP methods have a bounded timeout for offline recovery', () async {
    final client = MockClient((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return http.Response('{}', 200);
    });
    final api = BreezzeApi(
      baseUrl: 'https://api.example.test',
      client: client,
      requestTimeout: const Duration(milliseconds: 15),
    );
    await expectLater(api.homeFeed(), throwsA(isA<TimeoutException>()));
    await expectLater(api.logout('expired-session-token'), throwsA(isA<TimeoutException>()));
    await expectLater(
      api.updateProfile(displayName: 'Listener'),
      throwsA(isA<TimeoutException>()),
    );
    await expectLater(
      api.deleteAccount(password: 'redacted'),
      throwsA(isA<TimeoutException>()),
    );
    client.close();
  });
}
