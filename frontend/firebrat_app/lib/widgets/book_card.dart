import 'package:flutter/material.dart';
import '../models/book.dart';
import 'download_progress_indicator.dart';

class BookCard extends StatelessWidget {
  final BookSummary book;
  final bool isDownloaded;
  final double? downloadProgress; // null = not downloading
  final VoidCallback onTap;

  const BookCard({
    super.key,
    required this.book,
    required this.isDownloaded,
    required this.downloadProgress,
    required this.onTap,
  });

  String _duration() {
    final mins = (book.totalDurationMs / 60000).round();
    final h = mins ~/ 60;
    final m = mins % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.menu_book_rounded, color: scheme.onPrimaryContainer),
                  ),
                  const Spacer(),
                  if (isDownloaded)
                    Icon(Icons.check_circle_rounded, color: scheme.primary, size: 20)
                  else if (downloadProgress == null)
                    Icon(Icons.download_rounded, color: scheme.onSurfaceVariant, size: 20),
                ],
              ),
              const SizedBox(height: 12),
              Text(book.title, style: Theme.of(context).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (book.author.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(book.author, style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 10),
              if (downloadProgress != null)
                DownloadProgressIndicator(progress: downloadProgress!)
              else
                Row(
                  children: [
                    Icon(Icons.headphones_rounded, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(_duration(), style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(width: 12),
                    Icon(Icons.view_list_rounded, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text('${book.sectionCount} sections', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
