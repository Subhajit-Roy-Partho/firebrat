import 'dart:io';

import 'package:flutter/material.dart';
import '../models/book.dart';
import '../state/library_layout_provider.dart';
import '../services/download_manager.dart';
import 'download_progress_indicator.dart';

class BookCard extends StatelessWidget {
  final BookSummary book;
  final LibraryLayout layout;
  final bool isDownloaded;
  final DownloadProgress? downloadProgress; // null = not downloading
  final VoidCallback onTap;
  final VoidCallback? onPauseDownload;
  final VoidCallback? onDiscardDownload;

  /// Long-press opens the card's action sheet (open/download, delete
  /// from device, delete from server). Null = no long-press actions.
  final VoidCallback? onLongPress;

  /// Absolute cover image path, or null for the built-in cover. Resolved by
  /// the library screen via bookCoverProvider (packages may ship cover.*).
  final String? coverPath;

  const BookCard({
    super.key,
    required this.book,
    this.layout = LibraryLayout.largeCards,
    required this.isDownloaded,
    required this.downloadProgress,
    required this.onTap,
    this.onPauseDownload,
    this.onDiscardDownload,
    this.onLongPress,
    this.coverPath,
  });

  Widget _cover(ColorScheme scheme) {
    final fallback = Semantics(
      label: 'Default book cover',
      image: true,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primaryContainer, scheme.tertiaryContainer],
          ),
          border: Border(left: BorderSide(color: scheme.primary, width: 5)),
        ),
        child: Center(
          child: Icon(
            Icons.auto_stories_rounded,
            color: scheme.onPrimaryContainer,
            size: 28,
          ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 44,
        height: 62,
        child: coverPath == null
            ? fallback
            : Image.file(
                File(coverPath!),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
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
    if (layout == LibraryLayout.list) {
      return Card(
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _cover(scheme),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (book.author.isNotEmpty)
                        Text(
                          book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      Text(
                        '${_duration()} · ${book.sectionCount} sections',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (downloadProgress != null) ...[
                        DownloadProgressIndicator(progress: downloadProgress!),
                        Wrap(
                          children: [
                            IconButton(
                              onPressed: onPauseDownload,
                              tooltip:
                                  'Pause download (tap the book to resume)',
                              icon: const Icon(Icons.pause_rounded),
                            ),
                            IconButton(
                              onPressed: onDiscardDownload,
                              tooltip: 'Cancel and clear download',
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (downloadProgress == null)
                  Icon(
                    isDownloaded
                        ? Icons.check_circle_rounded
                        : Icons.download_rounded,
                    color: scheme.primary,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.all(layout == LibraryLayout.smallCards ? 10 : 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _cover(scheme),
                  const Spacer(),
                  if (isDownloaded)
                    Icon(
                      Icons.check_circle_rounded,
                      color: scheme.primary,
                      size: 20,
                    )
                  else if (downloadProgress == null)
                    Icon(
                      Icons.download_rounded,
                      color: scheme.onSurfaceVariant,
                      size: 20,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                book.title,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (book.author.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  book.author,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 10),
              if (downloadProgress != null) ...[
                DownloadProgressIndicator(progress: downloadProgress!),
                const SizedBox(height: 4),
                // Compact icon buttons (not labeled TextButtons): the card
                // has a fixed grid height, and the labeled row overflowed
                // it on narrow cards, pushing controls out of reach.
                Wrap(
                  alignment: WrapAlignment.end,
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
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      _duration(),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      '${book.sectionCount} sections',
                      style: Theme.of(context).textTheme.bodySmall,
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
