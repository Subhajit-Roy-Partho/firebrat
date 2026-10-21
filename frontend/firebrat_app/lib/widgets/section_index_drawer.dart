import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/reader_providers.dart';

/// Left-side table of contents for the reader: every section in order,
/// with the current section highlighted and scrolled into view on open.
///
/// Tapping a row jumps straight to that section via
/// [ReaderController.goToSection] (which restarts the section from its
/// start while preserving play/pause state) and closes the drawer.
class SectionIndexDrawer extends ConsumerStatefulWidget {
  final String bookId;

  const SectionIndexDrawer({super.key, required this.bookId});

  @override
  ConsumerState<SectionIndexDrawer> createState() => _SectionIndexDrawerState();
}

class _SectionIndexDrawerState extends ConsumerState<SectionIndexDrawer> {
  /// Rough ListTile+subtitle row height. Only used to compute the initial
  /// scroll offset so the current section is visible on open even in a
  /// 242-section book (where the current row isn't built yet, so
  /// Scrollable.ensureVisible on the row itself would never fire).
  static const _estimatedRowHeight = 72.0;

  late final ScrollController _scroll = ScrollController();
  bool _didInitialScroll = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToCurrent(int sectionIndex) {
    if (_didInitialScroll || !_scroll.hasClients) return;
    _didInitialScroll = true;
    final max = _scroll.position.maxScrollExtent;
    final offset = (sectionIndex * _estimatedRowHeight).clamp(0.0, max);
    _scroll.jumpTo(offset);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerControllerProvider(widget.bookId));
    if (state == null) {
      return const Drawer(child: Center(child: CircularProgressIndicator()));
    }
    final sections = state.manifest.sections;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToCurrent(state.sectionIndex);
    });
    return Drawer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DrawerHeader(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  state.manifest.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${state.sectionIndex + 1} of ${sections.length} sections · ${_formatTotal(state.manifest.totalDurationMs)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: sections.length,
              itemBuilder: (context, index) {
                final section = sections[index];
                final current = index == state.sectionIndex;
                final tile = ListTile(
                  leading: SizedBox(
                    width: 32,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: current ? FontWeight.bold : null,
                          ),
                    ),
                  ),
                  title: Text(
                    section.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  subtitle: Text(_formatDuration(section.durationMs)),
                  trailing: current ? const Icon(Icons.play_arrow_rounded) : null,
                  selected: current,
                  onTap: () {
                    Navigator.of(context).pop();
                    ref.read(readerControllerProvider(widget.bookId).notifier).goToSection(index);
                  },
                );
                if (!current) return tile;
                // Thin "current" highlight ring around the actively-reading row.
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: tile,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Row duration as m:ss, or h:mm:ss once over an hour.
String _formatDuration(int durationMs) {
  final totalSeconds = (durationMs / 1000).round().clamp(0, 1 << 31);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

/// Book-total summary as "Xh Ym" (or "Xm" under an hour).
String _formatTotal(int durationMs) {
  final totalMinutes = (durationMs / 60000).round();
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) return '${totalMinutes}m';
  return '${hours}h ${minutes}m';
}
