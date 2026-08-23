import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/reader_providers.dart';
import '../state/settings_providers.dart';
import 'playback_bar.dart';

/// Binds live playback streams (position/play-state) to [PlaybackBar].
/// Shared between the reader screen's bottom bar and the Focus Mode
/// overlay so both stay in sync with the same [PlaybackController] without
/// duplicating the stream-binding logic.
class PlaybackBarBound extends ConsumerStatefulWidget {
  final String bookId;
  /// When set, wraps [PlaybackBar] in this theme — used by Focus Mode to
  /// force legible light-on-dark controls regardless of the system theme.
  final ThemeData? themeOverride;

  const PlaybackBarBound({super.key, required this.bookId, this.themeOverride});

  @override
  ConsumerState<PlaybackBarBound> createState() => _PlaybackBarBoundState();
}

class _PlaybackBarBoundState extends ConsumerState<PlaybackBarBound> {
  Duration _position = Duration.zero;
  bool _isPlaying = false;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;
  String? _boundBookId;

  void _bind(String bookId) {
    if (_boundBookId == bookId) return;
    _boundBookId = bookId;
    _posSub?.cancel();
    _stateSub?.cancel();
    final controller = ref.read(readerControllerProvider(bookId).notifier);
    _posSub = controller.player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _stateSub = controller.player.playerStateStream.listen((s) {
      if (mounted) setState(() => _isPlaying = s.playing);
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerControllerProvider(widget.bookId));
    final settings = ref.watch(readerSettingsProvider);
    if (state == null) return const SizedBox.shrink();
    _bind(widget.bookId);
    final controller = ref.read(readerControllerProvider(widget.bookId).notifier);
    final settingsNotifier = ref.read(readerSettingsProvider.notifier);

    final bar = PlaybackBar(
      isPlaying: _isPlaying,
      position: _position,
      duration: controller.player.duration,
      speed: settings.playbackSpeed,
      autoplayEnabled: settings.autoplayEnabled,
      autoplayDelaySeconds: settings.autoplayDelaySeconds,
      onPlayPause: () => _isPlaying ? controller.player.pause() : controller.player.play(),
      onStop: () => controller.player.stop(),
      onSeek: (d) => controller.player.seek(d),
      onSpeedChanged: (v) {
        settingsNotifier.setPlaybackSpeed(v);
        controller.player.setSpeed(v);
      },
      onPrevSegment: () => controller.player.seekToPreviousSegment(),
      onNextSegment: () => controller.player.seekToNextSegment(),
      onAutoplayChanged: settingsNotifier.setAutoplayEnabled,
      onAutoplayDelayChanged: settingsNotifier.setAutoplayDelaySeconds,
    );

    return widget.themeOverride == null ? bar : Theme(data: widget.themeOverride!, child: bar);
  }
}
