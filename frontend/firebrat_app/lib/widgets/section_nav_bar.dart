import 'package:flutter/material.dart';

/// Top navigation strip: previous/next section, title, and chapter progress.
/// Always enabled — section navigation is never blocked by autoplay state.
class SectionNavBar extends StatelessWidget {
  final String title;
  final int sectionIndex;
  final int sectionCount;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  const SectionNavBar({
    super.key,
    required this.title,
    required this.sectionIndex,
    required this.sectionCount,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(icon: const Icon(Icons.chevron_left_rounded), onPressed: onPrevious, tooltip: 'Previous section'),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('Section ${sectionIndex + 1} of $sectionCount', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            IconButton(icon: const Icon(Icons.chevron_right_rounded), onPressed: onNext, tooltip: 'Next section'),
          ],
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: sectionCount > 0 ? (sectionIndex + 1) / sectionCount : 0,
            minHeight: 4,
          ),
        ),
      ],
    );
  }
}
