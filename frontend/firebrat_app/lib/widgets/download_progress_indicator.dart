import 'package:flutter/material.dart';
import '../services/download_manager.dart';

class DownloadProgressIndicator extends StatelessWidget {
  final DownloadProgress progress;
  const DownloadProgressIndicator({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
              value: progress.fraction.clamp(0.0, 1.0), minHeight: 6),
        ),
        const SizedBox(height: 4),
        Text(progress.label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
