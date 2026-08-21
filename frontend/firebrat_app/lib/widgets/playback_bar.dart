import 'package:flutter/material.dart';

/// Bottom-pinned transport controls: play/pause/stop, scrub, speed,
/// prev/next segment, and the autoplay toggle + delay. Always available
/// regardless of playback state — nothing here is gated on autoplay.
class PlaybackBar extends StatelessWidget {
  final bool isPlaying;
  final Duration position;
  final Duration? duration;
  final double speed;
  final bool autoplayEnabled;
  final int autoplayDelaySeconds;
  final VoidCallback onPlayPause;
  final VoidCallback onStop;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onSpeedChanged;
  final VoidCallback onPrevSegment;
  final VoidCallback onNextSegment;
  final ValueChanged<bool> onAutoplayChanged;
  final ValueChanged<int> onAutoplayDelayChanged;

  const PlaybackBar({
    super.key,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.speed,
    required this.autoplayEnabled,
    required this.autoplayDelaySeconds,
    required this.onPlayPause,
    required this.onStop,
    required this.onSeek,
    required this.onSpeedChanged,
    required this.onPrevSegment,
    required this.onNextSegment,
    required this.onAutoplayChanged,
    required this.onAutoplayDelayChanged,
  });

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = duration ?? Duration.zero;
    final maxMs = total.inMilliseconds.clamp(1, 1 << 31).toDouble();
    final curMs = position.inMilliseconds.clamp(0, maxMs.toInt()).toDouble();

    return Material(
      elevation: 8,
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(_fmt(position), style: Theme.of(context).textTheme.bodySmall),
                  Expanded(
                    child: Slider(
                      value: curMs,
                      max: maxMs,
                      onChanged: (v) => onSeek(Duration(milliseconds: v.toInt())),
                    ),
                  ),
                  Text(_fmt(total), style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _SpeedMenu(speed: speed, onChanged: onSpeedChanged),
                  Row(
                    children: [
                      IconButton(icon: const Icon(Icons.skip_previous_rounded), onPressed: onPrevSegment, tooltip: 'Previous segment'),
                      IconButton(icon: const Icon(Icons.stop_rounded), onPressed: onStop, tooltip: 'Stop'),
                      IconButton.filled(
                        icon: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                        iconSize: 32,
                        onPressed: onPlayPause,
                        tooltip: isPlaying ? 'Pause' : 'Play',
                      ),
                      IconButton(icon: const Icon(Icons.skip_next_rounded), onPressed: onNextSegment, tooltip: 'Next segment'),
                    ],
                  ),
                  _AutoplayMenu(
                    enabled: autoplayEnabled,
                    delaySeconds: autoplayDelaySeconds,
                    onEnabledChanged: onAutoplayChanged,
                    onDelayChanged: onAutoplayDelayChanged,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpeedMenu extends StatelessWidget {
  final double speed;
  final ValueChanged<double> onChanged;
  const _SpeedMenu({required this.speed, required this.onChanged});

  static const _options = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      initialValue: speed,
      onSelected: onChanged,
      itemBuilder: (_) => _options
          .map((v) => PopupMenuItem(value: v, child: Text('${v}x')))
          .toList(),
      child: Chip(label: Text('${speed}x')),
    );
  }
}

class _AutoplayMenu extends StatelessWidget {
  final bool enabled;
  final int delaySeconds;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<int> onDelayChanged;
  const _AutoplayMenu({
    required this.enabled,
    required this.delaySeconds,
    required this.onEnabledChanged,
    required this.onDelayChanged,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Autoplay settings',
      onSelected: (v) {
        if (v == -1) {
          onEnabledChanged(!enabled);
        } else {
          onDelayChanged(v);
        }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(value: -1, checked: enabled, child: const Text('Autoplay next')),
        const PopupMenuDivider(),
        for (final d in [0, 1, 2, 3, 5])
          CheckedPopupMenuItem(value: d, checked: delaySeconds == d, child: Text('Delay ${d}s')),
      ],
      child: Chip(
        avatar: Icon(enabled ? Icons.play_circle_outline : Icons.pause_circle_outline, size: 18),
        label: Text(enabled ? 'Auto ${delaySeconds}s' : 'Manual'),
      ),
    );
  }
}
