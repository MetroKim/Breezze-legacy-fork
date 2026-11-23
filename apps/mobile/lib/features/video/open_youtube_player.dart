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

/// Audio may be restored only if the video still belongs to the exact
/// queue entry and recording that were playing at handoff time.
/// Never resurrect a superseded track or override a user/OS pause.
bool shouldResumeAudioAfterVideo({
  required bool wasPlaying,
  required String? openedEntryId,
  required String? openedTrackId,
  required String? currentEntryId,
  required String? currentTrackId,
  required PlaybackState currentState,
  required AppLifecycleState? lifecycleState,
}) =>
    wasPlaying &&
    openedEntryId != null &&
    openedEntryId == currentEntryId &&
    openedTrackId != null &&
    openedTrackId == currentTrackId &&
    currentState == PlaybackState.paused &&
    lifecycleState == AppLifecycleState.resumed;

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
  final trackId = previous.currentTrack?.id;
  final resumeAudio = previous.playbackState == PlaybackState.playing;
  if (resumeAudio) {
    await controller.pause();
    // Pausing can await a server session. A new selection made during that
    // await must not be covered by a video started for the previous track.
    if (!context.mounted ||
        !shouldResumeAudioAfterVideo(
          wasPlaying: resumeAudio,
          openedEntryId: entry,
          openedTrackId: trackId,
          currentEntryId: controller.queue.current?.entryId,
          currentTrackId: container.read(playerControllerProvider).currentTrack?.id,
          currentState: container.read(playerControllerProvider).playbackState,
          lifecycleState: WidgetsBinding.instance.lifecycleState,
        )) {
      return;
    }
  }
  try {
    if (!context.mounted) return;
    final route = MaterialPageRoute<void>(builder: builder);
    await Navigator.of(context).push(route);
    // The pop result arrives while the video widget still owns its decoder.
    // Wait for the reverse transition and disposal before resuming audio.
    await route.completed;
  } finally {
    if (context.mounted &&
        shouldResumeAudioAfterVideo(
          wasPlaying: resumeAudio,
          openedEntryId: entry,
          openedTrackId: trackId,
          currentEntryId: controller.queue.current?.entryId,
          currentTrackId: container.read(playerControllerProvider).currentTrack?.id,
          currentState: container.read(playerControllerProvider).playbackState,
          lifecycleState: WidgetsBinding.instance.lifecycleState,
        )) {
      await controller.resume();
    }
  }
}
