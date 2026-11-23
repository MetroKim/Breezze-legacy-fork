import 'package:breezze_audio_contracts/audio_contracts.dart' show PlaybackState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../player/player_controller.dart';
import 'official_music_video_screen.dart';

/// Opens YouTube's visible player without putting a metadata ID in the native queue.
Future<void> openYouTubePlayer({
  required BuildContext context,
  required WidgetRef ref,
  required String videoId,
  required String title,
  required String artist,
  String? artworkUrl,
}) async {
  await openVideoSurface(context, (_) => OfficialMusicVideoScreen(
    videoId: videoId, title: title, artist: artist, artworkUrl: artworkUrl,
  ));
}

Future<void> openVideoSurface(BuildContext context, WidgetBuilder builder) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final controller = container.read(playerControllerProvider.notifier);
  final previous = container.read(playerControllerProvider);
  if (previous.playbackState == PlaybackState.resolving ||
      previous.playbackState == PlaybackState.buffering ||
      previous.playbackState == PlaybackState.loading ||
      previous.playbackState == PlaybackState.transitioning) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Audio is loading. Try the video again in a moment.')),
    );
    return;
  }
  final entry = controller.queue.current?.entryId;
  final resumeAudio = previous.playbackState == PlaybackState.playing;
  if (resumeAudio) await controller.pause();
  try {
    if (!context.mounted) return;
    final route = MaterialPageRoute<void>(builder: builder);
    await Navigator.of(context).push(route);
    // The pop result arrives while the video widget still owns its decoder.
    // Wait for the reverse transition and disposal before resuming audio.
    await route.completed;
  } finally {
    if (context.mounted && resumeAudio && entry != null &&
        controller.queue.current?.entryId == entry &&
        container.read(playerControllerProvider).playbackState == PlaybackState.paused &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      await controller.resume();
    }
  }
}
