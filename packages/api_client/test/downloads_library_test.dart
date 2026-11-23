import 'dart:convert';
import 'dart:io';

import 'package:breezze_api_client/breezze_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnusedLyricsHttp implements LyricsHttp {
  @override
  Future<String> getText(String url) async => throw StateError('not used');
}

void main() {
  late Directory root;
  late DownloadsLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('breezze-downloads-');
    library = DownloadsLibrary(
      root: root,
      lyrics: LyricsProvider(_UnusedLyricsHttp()),
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });


  test('resumes a partial authorized download using HTTP byte ranges', () async {
    final track = BzTrack(
      id: 'catalog-resume',
      title: 'Resume track',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
    );
    final trackDir = Directory('${root.path}/catalog-resume');
    await trackDir.create();
    final partial = File('${trackDir.path}/audio.part');
    await partial.writeAsBytes(utf8.encode('abc'));
    await File('${trackDir.path}/audio.part.version').writeAsString('asset-v1');

    var receivedRange = '';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      receivedRange = request.headers.value('range') ?? '';
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers
        ..set('content-range', 'bytes 3-5/6')
        ..contentLength = 3;
      request.response.add(utf8.encode('def'));
      await request.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
    });

    final ok = await library.download(
      track,
      downloadUrl: 'http://${server.address.address}:${server.port}/audio',
      ownerId: 'user-1',
      catalogTrackId: 'catalog-resume',
      assetVersion: 'asset-v1',
    );

    expect(ok, isTrue);
    expect(receivedRange, 'bytes=3-');
    expect(await File('${trackDir.path}/audio.m4a').readAsString(), 'abcdef');
    expect(await partial.exists(), isFalse);
  });


  test('discards old partial when asset identity is unavailable', () async {
    final track = BzTrack(
      id: 'changed-asset',
      title: 'Changed master',
      artist: 'Artist',
      duration: const Duration(minutes: 2),
    );
    final trackDir = Directory('${root.path}/changed-asset');
    await trackDir.create();
    await File('${trackDir.path}/audio.part')
        .writeAsBytes(utf8.encode('wrong-master'));
    await File('${trackDir.path}/audio.part.version')
        .writeAsString('old-master');

    var requestedRange = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requestedRange = request.headers.value('range') != null;
      request.response.statusCode = HttpStatus.ok;
      request.response.add(utf8.encode('new-master'));
      await request.response.close();
    });
    addTearDown(() async => server.close(force: true));

    final ok = await library.download(
      track,
      downloadUrl: 'http://${server.address.address}:${server.port}/audio',
      ownerId: 'user-1',
      catalogTrackId: 'changed-asset',
    );

    expect(ok, isTrue);
    expect(requestedRange, isFalse);
    expect(await File('${trackDir.path}/audio.m4a').readAsString(),
        'new-master');
    expect(await File('${trackDir.path}/audio.part.version').exists(), isFalse);
  });

  test('discards old partial when asset version changes', () async {
    final track = BzTrack(
      id: 'version-change',
      title: 'Changed codec',
      artist: 'Artist',
      duration: const Duration(minutes: 2),
    );
    final trackDir = Directory('${root.path}/version-change');
    await trackDir.create();
    await File('${trackDir.path}/audio.part')
        .writeAsBytes(utf8.encode('old'));
    await File('${trackDir.path}/audio.part.version')
        .writeAsString('asset-v1');

    var requestedRange = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requestedRange = request.headers.value('range') != null;
      request.response.statusCode = HttpStatus.ok;
      request.response.add(utf8.encode('new'));
      await request.response.close();
    });
    addTearDown(() async => server.close(force: true));

    final ok = await library.download(
      track,
      downloadUrl: 'http://${server.address.address}:${server.port}/audio',
      ownerId: 'user-1',
      catalogTrackId: 'version-change',
      assetVersion: 'asset-v2',
    );
    expect(ok, isTrue);
    expect(requestedRange, isFalse);
    expect(await File('${trackDir.path}/audio.m4a').readAsString(), 'new');
  });


  test('invalidates a completed file when the authorized version changes', () async {
    final track = BzTrack(
      id: 'completed-replacement',
      title: 'Updated master',
      artist: 'Artist',
      duration: const Duration(minutes: 2),
    );
    final trackDir = Directory('${root.path}/completed-replacement');
    await trackDir.create();
    await File('${trackDir.path}/audio.m4a')
        .writeAsBytes(utf8.encode('old-master'));
    await File('${trackDir.path}/meta.json').writeAsString(jsonEncode({
      'ownerId': 'user-1',
      'catalogTrackId': 'completed-replacement',
      'assetVersion': 'master-old',
    }));

    var calls = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      calls++;
      request.response.statusCode = HttpStatus.ok;
      request.response.add(utf8.encode('new-master'));
      await request.response.close();
    });
    addTearDown(() async => server.close(force: true));

    final ok = await library.download(
      track,
      downloadUrl: 'http://${server.address.address}:${server.port}/audio',
      ownerId: 'user-1',
      catalogTrackId: 'completed-replacement',
      assetVersion: 'master-new',
    );
    expect(ok, isTrue);
    expect(calls, 1);
    expect(await File('${trackDir.path}/audio.m4a').readAsString(),
        'new-master');
    final saved = jsonDecode(await File('${trackDir.path}/meta.json').readAsString());
    expect(saved['assetVersion'], 'master-new');
  });

  test('lists only assets owned by the requested account', () async {
    final alice = Directory('${root.path}/bz_alice-track');
    final bob = Directory('${root.path}/bz_bob-track');
    await alice.create();
    await bob.create();

    await File('${alice.path}/audio.m4a').writeAsBytes([1, 2, 3]);
    await File('${bob.path}/audio.m4a').writeAsBytes([4, 5, 6]);
    await File('${alice.path}/meta.json').writeAsString(jsonEncode({
      'title': 'Alice track',
      'artist': 'Artist A',
      'ownerId': 'alice',
      'catalogTrackId': 'catalog-a',
      'rightsExpiresAtUtc': null,
    }));
    await File('${bob.path}/meta.json').writeAsString(jsonEncode({
      'title': 'Bob track',
      'artist': 'Artist B',
      'ownerId': 'bob',
      'catalogTrackId': 'catalog-b',
      'rightsExpiresAtUtc': null,
    }));

    final tracks = await library.list(ownerId: 'alice');

    expect(tracks, hasLength(1));
    expect(tracks.single.title, 'Alice track');
    expect(tracks.single.ownerId, 'alice');
    expect(tracks.single.catalogTrackId, 'catalog-a');
    expect(tracks.single.audioPath, '${alice.path}/audio.m4a');
  });

  test('preserves rights expiry metadata for offline enforcement', () async {
    final trackDir = Directory('${root.path}/bz_expiring-track');
    await trackDir.create();
    final expiry = DateTime.utc(2027, 1, 1);
    await File('${trackDir.path}/audio.m4a').writeAsBytes([1]);
    await File('${trackDir.path}/meta.json').writeAsString(jsonEncode({
      'title': 'Expiring track',
      'artist': 'Artist',
      'ownerId': 'user-1',
      'catalogTrackId': 'catalog-track-1',
      'rightsExpiresAtUtc': expiry.toIso8601String(),
    }));

    final tracks = await library.list(ownerId: 'user-1');

    final saved = tracks.single;
    expect(saved.rightsExpiresAtUtc, expiry);
    final renewed = expiry.add(const Duration(days: 1));
    await library.updateOfflineLease(saved.trackId, renewed);
    expect((await library.list(ownerId: 'user-1')).single.rightsExpiresAtUtc, renewed);
    await library.remove(saved.trackId);
    expect(await library.list(ownerId: 'user-1'), isEmpty);
  });

  test('does not expose legacy metadata without an owner', () async {
    final legacy = Directory('${root.path}/legacy-track');
    await legacy.create();
    await File('${legacy.path}/meta.json').writeAsString(
      jsonEncode({'title': 'Legacy', 'artist': 'Unknown'}),
    );

    expect(await library.list(ownerId: 'user-1'), isEmpty);
  });
}
