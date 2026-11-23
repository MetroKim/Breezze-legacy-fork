import 'dart:io';

import 'package:breezze/core/audio/audio_service_bridge.dart';
import 'package:breezze/core/audio/background_audio.dart';
import 'package:breezze/features/player/player_controller.dart';
import 'package:breezze/features/video/device_video.dart';
import 'package:breezze/main.dart' as app;
import 'package:breezze_api_client/breezze_api_client.dart';
import 'package:breezze_audio_contracts/audio_contracts.dart' show PlaybackState;
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';

class _FixtureLyrics implements LyricsHttp {
  @override
  Future<String> getText(String url) async => '[]';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('download, offline decode, media controls and video handoff', (tester) async {
    Future<void> until(String description, bool Function() ready, {int seconds = 25}) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!ready()) {
        if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $description');
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await tester.pump();
      }
    }

    app.main();
    await until('app navigator', () => find.byType(Navigator).evaluate().isNotEmpty);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    final context = navigator.overlay!.context;
    final container = ProviderScope.containerOf(context, listen: false);
    final player = container.read(playerControllerProvider.notifier);
    PlayerState current() => container.read(playerControllerProvider);
    await until('native media session', () => container.read(backgroundBridgeProvider) is AudioServiceBridge);

    final root = await Directory.systemTemp.createTemp('breezze-runtime-');
    addTearDown(() async { await player.stop(); await root.delete(recursive: true); });
    final library = DownloadsLibrary(root: root, lyrics: LyricsProvider(_FixtureLyrics()));
    final tone = await rootBundle.load('integration_test/fixtures/tone.m4a');
    final bytes = tone.buffer.asUint8List(tone.offsetInBytes, tone.lengthInBytes);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    const track = BzTrack(id: 'fixture', title: 'Runtime tone', artist: 'Breezze QA', duration: Duration(seconds: 40));
    try {
      expect(await library.download(track, downloadUrl: 'http://127.0.0.1:${server.port}/tone',
        catalogTrackId: track.id, ownerId: 'listener', rightsExpiresAtUtc: DateTime.now().toUtc().add(const Duration(hours: 1))), isTrue);
    } finally {
      await server.close(force: true);
    }
    expect(await library.list(ownerId: 'another-listener'), isEmpty);
    final saved = (await library.list(ownerId: 'listener')).single;
    expect(saved.trackId, track.id);
    expect(await File(saved.audioPath).readAsBytes(), orderedEquals(bytes));
    await player.playTrack(trackId: saved.catalogTrackId, title: saved.title, localFilePath: saved.audioPath);
    await until('offline audio position', () => current().position > const Duration(milliseconds: 600));
    expect(current().playbackState, PlaybackState.playing);
    expect(current().duration.inSeconds, closeTo(40, 1));

    final bridge = container.read(backgroundBridgeProvider) as AudioServiceBridge;
    await bridge.pause();
    await until('paused', () => current().playbackState == PlaybackState.paused);
    await bridge.seek(const Duration(seconds: 4));
    await bridge.play();
    await until('resumed after seek', () => current().position > const Duration(milliseconds: 4600));

    final videoBytes = await rootBundle.load('integration_test/fixtures/clip.mp4');
    final videoFile = File('${root.path}/clip.mp4');
    await videoFile.writeAsBytes(videoBytes.buffer.asUint8List(videoBytes.offsetInBytes, videoBytes.lengthInBytes));
    final route = openDeviceVideo(context, XFile(videoFile.path));
    await until('native video ready', () => find.byTooltip('Play video').evaluate().isNotEmpty);
    expect(current().playbackState, PlaybackState.paused);
    final video = tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller;
    await until('video route fully visible', () =>
        ModalRoute.of(tester.element(find.byType(VideoPlayer)))?.animation?.isCompleted == true);
    await tester.tap(find.byTooltip('Play video'));
    await until('video decoder advancing', () => video.value.position.inMilliseconds > 100);
    await until('video route removed', () => find.byType(VideoPlayer).evaluate().isEmpty);
    debugPrint('After video pop: audio=${current().playbackState}, lifecycle=${WidgetsBinding.instance.lifecycleState}');
    await until('video finished and audio resumed', () => find.byTooltip('Play video').evaluate().isEmpty &&
        current().playbackState == PlaybackState.playing);
    await route.timeout(const Duration(seconds: 5));
    final resumedAt = current().position;
    await until('audio advancing after video', () => current().position > resumedAt + const Duration(milliseconds: 400));

    debugPrint('Verified local download, offline decode, seek and video handoff');
    if (Platform.isAndroid && const bool.fromEnvironment('QA_ANDROID_MEDIA_KEYS')) {
      debugPrint('QA_ANDROID_MEDIA_KEYS_READY');
      await until('OS pause command', () => current().playbackState == PlaybackState.paused, seconds: 45);
      debugPrint('QA_ANDROID_OS_PAUSED');
      await until('OS play command', () => current().playbackState == PlaybackState.playing, seconds: 45);
    }
    if (const bool.fromEnvironment('QA_LIVE_PREVIEW')) {
      await player.playTrack(trackId: 'bz:deezer_preview:3135556', title: 'Deezer preview');
      await until('live preview decode', () => current().playbackState == PlaybackState.playing &&
          current().position > const Duration(milliseconds: 500) &&
          current().duration.inSeconds >= 25 && current().duration.inSeconds <= 35);
      debugPrint('Verified live preview on native decoder');
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
