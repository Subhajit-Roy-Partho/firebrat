import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

/// App-wide singleton wrapping the one `just_audio` player, registered with
/// the OS once via `AudioService.init` in main() before the app starts.
/// This is what makes playback survive navigation and stay controllable
/// from the lock screen / notification / headset buttons: unlike
/// [PlaybackController] (recreated per book), this handler and its player
/// live for the whole app session.
class FirebratAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer();

  /// Wired up by whichever [PlaybackController] currently owns playback.
  /// There's no queue here — one section is one combined audio track — so
  /// lock-screen/notification skip buttons are routed to segment
  /// navigation instead of a real queue.
  FutureOr<void> Function()? onSkipToNext;
  FutureOr<void> Function()? onSkipToPrevious;

  FirebratAudioHandler() {
    player.playbackEventStream.map(_transformEvent).pipe(playbackState);
  }

  /// Replaces the media item shown in the notification / lock screen.
  void setMediaItem(MediaItem item) => mediaItem.add(item);

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async => onSkipToNext?.call();

  @override
  Future<void> skipToPrevious() async => onSkipToPrevious?.call();

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState]!,
      playing: player.playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: event.currentIndex,
    );
  }
}

/// Set once in main() right after `AudioService.init` resolves.
late final FirebratAudioHandler audioHandler;

final audioHandlerProvider = Provider<FirebratAudioHandler>((ref) => audioHandler);
