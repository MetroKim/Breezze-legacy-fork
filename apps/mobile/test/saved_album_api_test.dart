import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:breezze/core/api/breezze_api.dart';

void main() {
  test('saved albums list uses account JWT and correct cursor', () async {
    final calls = <http.Request>[];
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((request) async {
        calls.add(request);
        return http.Response(
          jsonEncode({'data': {
            'items': [],
            'nextCursor': null,
          }}),
          200,
        );
      }),
    )..accessToken = 'owner-a-access-token';

    final result = await api.getSavedAlbums(cursor: 'cursor-id');
    expect(result['items'], isEmpty);
    expect(calls.single.url.path, '/api/v1/library/albums');
    expect(calls.single.url.queryParameters['cursor'], 'cursor-id');
    expect(calls.single.headers['Authorization'], 'Bearer owner-a-access-token');
  });

  test('saved album upsert posts metadata without any playback grant', () async {
    late http.Request captured;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode({'data': {'externalAlbumId': '123'}}), 201);
      }),
    )..accessToken = 'token';

    await api.upsertSavedAlbum(
      externalAlbumId: '123',
      title: 'Album',
      artist: 'Artist',
      genres: ['Jazz'],
      isCompilation: true,
      isPinned: true,
    );
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/v1/library/albums');
    expect(body, containsPair('externalAlbumId', '123'));
    expect(body, containsPair('isCompilation', true));
    expect(body, containsPair('isPinned', true));
    expect(body.containsKey('streamUrl'), isFalse);
    expect(body.containsKey('playback'), isFalse);
  });

  test('followed artists list, follow metadata and pin use owner JWT',
      () async {
    final calls = <http.Request>[];
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((request) async {
        calls.add(request);
        final data = request.method == 'GET'
            ? {'items': <dynamic>[]}
            : {'isPinned': true};
        return http.Response(
          jsonEncode({'data': data}),
          request.method == 'POST' ? 201 : 200,
        );
      }),
    )..accessToken = 'owner-token';

    await api.getFollowedArtists();
    await api.followArtist('apple:123', true, displayName: 'Verified Name');
    await api.pinArtist('apple:123', true);
    await api.followArtist('apple:123', false);
    expect(calls.map((c) => c.method).toList(),
      ['GET', 'POST', 'PATCH', 'DELETE']);
    expect(calls.first.url.path, '/api/v1/library/artists');
    expect(calls[1].url.path, '/api/v1/library/artists/apple%3A123');
    expect(jsonDecode(calls[1].body), {'displayName': 'Verified Name'});
    expect(calls[2].url.path, '/api/v1/library/artists/apple%3A123/pin');
    expect(jsonDecode(calls[2].body), {'pinned': true});
    expect(calls.last.url.path, '/api/v1/library/artists/apple%3A123');
    expect(calls.every((c) =>
        c.headers['Authorization'] == 'Bearer owner-token'), isTrue);
  });

  test('removing a saved album uses an authenticated owner-bound request', () async {
    late http.Request captured;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode({'data': {'removed': true}}), 200);
      }),
    )..accessToken = 'owner-a-access-token';

    await api.deleteSavedAlbum('321');
    expect(captured.method, 'DELETE');
    expect(captured.url.path, '/api/v1/library/albums/321');
    expect(captured.headers['Authorization'], 'Bearer owner-a-access-token');
  });
  test('transient GET timeout retries once with the same owner token', () async {
    var calls = 0;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((request) async {
        calls++;
        expect(request.method, 'GET');
        expect(request.headers['Authorization'], 'Bearer owner-token');
        if (calls == 1) throw TimeoutException('temporary edge timeout');
        return http.Response(jsonEncode({'data': <Map<String, dynamic>>[
          {'id': 'playlist-1', 'name': 'Library'},
        ]}), 200);
      }),
    )..accessToken = 'owner-token';

    final result = await api.playlists();
    expect(result.single['id'], 'playlist-1');
    expect(calls, 2);
  });

  test('repeated GET transport failure stops after one retry', () async {
    var calls = 0;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((_) async {
        calls++;
        throw http.ClientException('connection interrupted');
      }),
    );

    await expectLater(api.playlists(), throwsA(isA<http.ClientException>()));
    expect(calls, 2);
  });

  test('GET HTTP 503 does not retry provider errors', () async {
    var calls = 0;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((_) async {
        calls++;
        return http.Response('{"message":"UPSTREAM_UNAVAILABLE"}', 503);
      }),
    );

    await expectLater(
      api.playlists(),
      throwsA(isA<BreezzeApiException>().having(
        (error) => error.code, 'code', 'UPSTREAM_UNAVAILABLE',
      )),
    );
    expect(calls, 1);
  });

  test('POST mutation is never retried after a timeout', () async {
    var calls = 0;
    final api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((_) async {
        calls++;
        throw TimeoutException('write response lost');
      }),
    );

    await expectLater(api.createPlaylist('No duplicates'), throwsA(isA<TimeoutException>()));
    expect(calls, 1);
  });

  test('account switch prevents a timed-out GET from replaying', () async {
    var calls = 0;
    late BreezzeApi api;
    api = BreezzeApi(
      baseUrl: 'https://breezze.example.test',
      client: MockClient((_) async {
        calls++;
        api.accessToken = 'different-listener';
        throw TimeoutException('old listener request failed');
      }),
    )..accessToken = 'original-listener';

    await expectLater(api.playlists(), throwsA(isA<TimeoutException>()));
    expect(calls, 1);
  });

}
