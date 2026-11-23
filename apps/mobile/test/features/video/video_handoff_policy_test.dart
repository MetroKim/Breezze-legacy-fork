import 'package:breezze/features/video/open_youtube_player.dart';
import 'package:breezze_audio_contracts/audio_contracts.dart' show PlaybackState;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool canRestore({
    bool wasPlaying = true,
    String? openedEntryId = 'queue-entry-1',
    String? currentEntryId = 'queue-entry-1',
    String? openedTrackId = 'track-a',
    String? currentTrackId = 'track-a',
    PlaybackState state = PlaybackState.paused,
    AppLifecycleState? lifecycle = AppLifecycleState.resumed,
  }) =>
      shouldResumeAudioAfterVideo(
        wasPlaying: wasPlaying,
        openedEntryId: openedEntryId,
        openedTrackId: openedTrackId,
        currentEntryId: currentEntryId,
        currentTrackId: currentTrackId,
        currentState: state,
        lifecycleState: lifecycle,
      );

  test('resumes the exact paused queue entry after video closes', () {
    expect(canRestore(), isTrue);
  });

  test('does not resume audio that was paused before video opened', () {
    expect(canRestore(wasPlaying: false), isFalse);
  });

  test('does not resume a different queue entry selected during video', () {
    expect(canRestore(currentEntryId: 'queue-entry-2'), isFalse);
  });

  test('does not resume a replacement recording in the same queue entry', () {
    expect(canRestore(currentTrackId: 'track-b'), isFalse);
  });

  test('does not resume when the old queue or recording disappeared', () {
    expect(canRestore(currentEntryId: null), isFalse);
    expect(canRestore(openedTrackId: null), isFalse);
  });

  test('does not override a later play, stop or failed state', () {
    expect(canRestore(state: PlaybackState.playing), isFalse);
    expect(canRestore(state: PlaybackState.idle), isFalse);
    expect(canRestore(state: PlaybackState.failed), isFalse);
  });

  test('does not resume while the application is backgrounded', () {
    expect(canRestore(lifecycle: AppLifecycleState.paused), isFalse);
    expect(canRestore(lifecycle: AppLifecycleState.inactive), isFalse);
    expect(canRestore(lifecycle: null), isFalse);
  });
}
