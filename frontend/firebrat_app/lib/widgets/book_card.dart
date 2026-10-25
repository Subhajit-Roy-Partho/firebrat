import 'package:flutter/material.dart';
import '../models/book.dart';
import '../state/library_layout_provider.dart';
import '../services/download_manager.dart';
import 'book_cover.dart';
import 'download_progress_indicator.dart';

/// Cover-first library entry. Grid layouts show the cover large with the
/// title underneath; the list layout puts a smaller cover beside the text.
/// Pressing scales the card slightly, and the cover is a Hero that flies
/// into the reader.
class BookCard extends StatefulWidget {
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

  /// Absolute cover image path, or null for the generated cover. Resolved by
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

  @override
  State<BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<BookCard> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  String _duration() {
    final mins = (widget.book.totalDurationMs / 60000).round();
    final h = mins ~/ 60;
    final m = mins % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  Widget _cover() => BookCover(
    bookId: widget.book.bookId,
    title: widget.book.title,
    author: widget.book.author,
    coverPath: widget.coverPath,
  );

  /// Check / download badge sitting on the cover's bottom-right corner.
  String _sectionsLabel() {
    final b = widget.book;
    if (!b.partial) return '${_duration()} · ${b.sectionCount} sections';
    final planned = b.sectionsPlanned;
    return planned == null
        ? '${_duration()} ready · still converting'
        : '${_duration()} ready · ${b.sectionCount} of $planned sections';
  }

  Widget _badge(ColorScheme scheme) {
    final done = widget.isDownloaded;
    if (widget.book.partial) {
      return Container(
        key: const Key('partial-badge'),
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          shape: BoxShape.circle,
          boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 6)],
        ),
        child: Icon(
          Icons.hourglass_top_rounded,
          size: 16,
          color: scheme.onTertiaryContainer,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: done ? scheme.primary : scheme.surface.withValues(alpha: .92),
        shape: BoxShape.circle,
        boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 6)],
      ),
      child: Icon(
        done ? Icons.check_rounded : Icons.download_rounded,
        size: 16,
        color: done ? scheme.onPrimary : scheme.onSurface,
      ),
    );
  }

  /// Scrim over the cover while downloading: a bright progress ring with the
  /// percentage in the middle, and pause/cancel underneath. The ring is white on
  /// a dark scrim so progress reads at a glance on every cover colour.
  Widget _downloadOverlay(ColorScheme scheme, {required bool compact}) {
    final p = widget.downloadProgress!;
    final fraction = p.fraction.clamp(0.0, 1.0);
    final ring = compact ? 52.0 : 64.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .66),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Eases between updates instead of jumping.
            TweenAnimationBuilder<double>(
              tween: Tween(end: fraction),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              builder: (context, value, _) => SizedBox(
                width: ring,
                height: ring,
                child: Stack(
                  alignment: Alignment.center,
                  fit: StackFit.expand,
                  children: [
                    CircularProgressIndicator(
                      key: const ValueKey('download-ring'),
                      // Indeterminate until the first bytes arrive.
                      value: fraction <= 0 ? null : value,
                      strokeWidth: 5,
                      strokeCap: StrokeCap.round,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                    ),
                    Center(
                      child: Text(
                        '${(value * 100).round()}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 2),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                IconButton(
                  onPressed: widget.onPauseDownload,
                  tooltip: 'Pause download (tap the book to resume)',
                  icon: const Icon(Icons.pause_rounded, color: Colors.white),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: widget.onDiscardDownload,
                  tooltip: 'Cancel and clear download',
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final book = widget.book;
    final downloading = widget.downloadProgress != null;
    final isList = widget.layout == LibraryLayout.list;

    final Widget body = isList
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 68,
                  height: 102,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _cover(),
                      if (downloading)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .55),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium,
                      ),
                      if (book.author.isNotEmpty)
                        Text(
                          book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      const SizedBox(height: 6),
                      if (downloading) ...[
                        DownloadProgressIndicator(
                          progress: widget.downloadProgress!,
                        ),
                        Wrap(
                          children: [
                            IconButton(
                              onPressed: widget.onPauseDownload,
                              tooltip:
                                  'Pause download (tap the book to resume)',
                              icon: const Icon(Icons.pause_rounded),
                              visualDensity: VisualDensity.compact,
                            ),
                            IconButton(
                              onPressed: widget.onDiscardDownload,
                              tooltip: 'Cancel and clear download',
                              icon: const Icon(Icons.close_rounded),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ] else
                        Text(
                          _sectionsLabel(),
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (!downloading) ...[const SizedBox(width: 8), _badge(scheme)],
              ],
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AspectRatio(
                    aspectRatio: BookCover.aspect,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _cover(),
                        if (downloading)
                          _downloadOverlay(scheme, compact: true)
                        else
                          Positioned(
                            right: 7,
                            bottom: 7,
                            child: _badge(scheme),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (book.author.isNotEmpty)
                Text(
                  book.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                downloading
                    ? widget.downloadProgress!.label
                    : widget.layout == LibraryLayout.smallCards
                    ? _duration()
                    : _sectionsLabel(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          );

    return AnimatedScale(
      scale: _pressed ? .965 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: Padding(padding: const EdgeInsets.all(4), child: body),
      ),
    );
  }
}
