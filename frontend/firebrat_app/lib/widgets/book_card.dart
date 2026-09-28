import 'dart:io';

import 'package:flutter/material.dart';
import '../models/book.dart';
import '../services/download_manager.dart';
import 'download_progress_indicator.dart';

class BookCard extends StatelessWidget {
  final BookSummary book;
  final bool isDownloaded;
  final DownloadProgress? downloadProgress; // null = not downloading
  final VoidCallback onTap;
  final VoidCallback? onPauseDownload;
  final VoidCallback? onDiscardDownload;
  /// Long-press opens the card's action sheet (open/download, delete
  /// from device, delete from server). Null = no long-press actions.
  final VoidCallback? onLongPress;
  /// Absolute cover image path, or null for the generic icon. Resolved by
  /// the library screen via bookCoverProvider (packages may ship cover.*).
  final String? coverPath;

  const BookCard({
    super.key,
    required this.book,
    required this.isDownloaded,
    required this.downloadProgress,
    required this.onTap,
    this.onPauseDownload,
    this.onDiscardDownload,
    this.onLongPress,
    this.coverPath,
  });

  Widget _fallbackIcon(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(Icons.menu_book_rounded, color: scheme.onPrimaryContainer),
    );
  }

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
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (coverPath != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.file(
                        File(coverPath!),
                        width: 44,
                        height: 60,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _fallbackIcon(scheme),
                      ),
                    )
                  else
                    _fallbackIcon(scheme),
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
                Text(book.author,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
              const SizedBox(height: 10),
              if (downloadProgress != null) ...[
                DownloadProgressIndicator(progress: downloadProgress!),
                const SizedBox(height: 4),
                // Compact icon buttons (not labeled TextButtons): the card
                // has a fixed grid height, and the labeled row overflowed
                // it on narrow cards, pushing controls out of reach.
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      onPressed: onPauseDownload,
                      icon: const Icon(Icons.pause_rounded, size: 20),
                      tooltip: 'Pause download (tap the book to resume)',
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      onPressed: onDiscardDownload,
                      icon: const Icon(Icons.close_rounded, size: 20),
                      tooltip: 'Cancel and clear download',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ] else
                Row(
                  children: [
                    Icon(Icons.headphones_rounded, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(_duration(),
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 12),
                    Icon(Icons.view_list_rounded, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text('${book.sectionCount} sections',
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
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
