import 'package:flutter/material.dart';

class DownloadProgressIndicator extends StatelessWidget {
  final double progress; // 0.0 - 1.0
  const DownloadProgressIndicator({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: progress, minHeight: 6),
        ),
        const SizedBox(height: 4),
        Text('${(progress * 100).toStringAsFixed(0)}%', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
