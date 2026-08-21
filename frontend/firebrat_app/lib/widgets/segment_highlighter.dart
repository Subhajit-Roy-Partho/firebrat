import 'package:flutter/material.dart';
import '../models/segment.dart';

/// Renders one prose/heading segment's text, highlighted with a soft
/// background + left accent bar while it's the one being spoken. Tapping
/// a segment jumps playback there directly (works whether autoplay is on
/// or off).
class SegmentHighlighter extends StatelessWidget {
  final Segment segment;
  final bool active;
  final double fontScale;
  final VoidCallback onTap;

  const SegmentHighlighter({
    super.key,
    required this.segment,
    required this.active,
    required this.fontScale,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isHeading = segment.type == SegmentType.heading;
    final baseStyle = isHeading
        ? Theme.of(context).textTheme.titleLarge
        : Theme.of(context).textTheme.bodyLarge;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: active ? scheme.primaryContainer.withValues(alpha: 0.6) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border(
            left: BorderSide(
              color: active ? scheme.primary : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        child: Text(
          segment.text,
          style: baseStyle?.copyWith(fontSize: (baseStyle.fontSize ?? 16) * fontScale),
        ),
      ),
    );
  }
}
