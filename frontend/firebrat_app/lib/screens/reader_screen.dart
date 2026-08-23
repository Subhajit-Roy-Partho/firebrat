import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/segment.dart';
import '../state/reader_providers.dart';
import '../state/settings_providers.dart';
import '../theme/app_theme.dart';
import 'focus_mode_screen.dart';
import '../widgets/section_nav_bar.dart';
import '../widgets/segment_highlighter.dart';
import '../widgets/formula_view.dart';
import '../widgets/figure_gallery.dart';
import '../widgets/playback_bar_bound.dart';

class ReaderScreen extends ConsumerWidget {
  final String bookId;
  const ReaderScreen({super.key, required this.bookId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerControllerProvider(bookId));
    final controller = ref.read(readerControllerProvider(bookId).notifier);
    final settings = ref.watch(readerSettingsProvider);

    if (state == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final wide = AppTheme.isWide(context);
    final galleryItems = _galleryItems(state);

    return Scaffold(
      appBar: AppBar(
        title: Text(state.manifest.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.fullscreen_rounded),
            tooltip: 'Focus mode',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => FocusModeScreen(bookId: bookId)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.text_fields_rounded),
            tooltip: 'Text size',
            onPressed: () => _showFontSizeSheet(context, ref),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: SectionNavBar(
              title: state.section.title,
              sectionIndex: state.sectionIndex,
              sectionCount: state.manifest.sections.length,
              onPrevious: state.sectionIndex > 0 ? controller.previousSection : null,
              onNext: state.sectionIndex < state.manifest.sections.length - 1 ? controller.nextSection : null,
            ),
          ),
          FigureGallery(items: galleryItems, activeId: state.activeSegment?.ref),
          Expanded(
            child: state.loadingSection
                ? const Center(child: CircularProgressIndicator())
                : _SegmentList(
                    bookId: bookId,
                    assetPaths: state.assetPaths,
                    fontScale: settings.fontScale,
                    wide: wide,
                  ),
          ),
        ],
      ),
      bottomNavigationBar: PlaybackBarBound(bookId: bookId),
    );
  }

  List<GalleryItem> _galleryItems(ReaderState state) {
    final items = <GalleryItem>[];
    for (final id in state.section.figureRefs) {
      final fig = state.manifest.figureById(id);
      if (fig != null && state.assetPaths.containsKey(id)) {
        items.add(GalleryItem(id: id, imagePath: state.assetPaths[id]!, caption: fig.caption));
      }
    }
    for (final id in state.section.tableRefs) {
      final tbl = state.manifest.tableById(id);
      if (tbl != null && state.assetPaths.containsKey(id)) {
        items.add(GalleryItem(id: id, imagePath: state.assetPaths[id]!, caption: tbl.caption));
      }
    }
    return items;
  }

  void _showFontSizeSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final settings = ref.watch(readerSettingsProvider);
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Text size', style: Theme.of(ctx).textTheme.titleMedium),
                Slider(
                  value: settings.fontScale,
                  min: 0.85,
                  max: 1.6,
                  divisions: 15,
                  label: settings.fontScale.toStringAsFixed(2),
                  onChanged: (v) => ref.read(readerSettingsProvider.notifier).setFontScale(v),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Isolated so the whole screen doesn't rebuild every position tick — only
/// the highlight/gallery state (driven by activeSegment) needs to react fast.
class _SegmentList extends ConsumerWidget {
  final String bookId;
  final Map<String, String> assetPaths;
  final double fontScale;
  final bool wide;

  const _SegmentList({
    required this.bookId,
    required this.assetPaths,
    required this.fontScale,
    required this.wide,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerControllerProvider(bookId));
    final controller = ref.read(readerControllerProvider(bookId).notifier);
    if (state == null) return const SizedBox.shrink();
    final segments = controller.player.currentSegments?.segments ?? const <Segment>[];
    final activeId = state.activeSegment?.segmentId;

    return ListView.builder(
      padding: EdgeInsets.symmetric(horizontal: wide ? 48 : 16, vertical: 12),
      itemCount: segments.length,
      itemBuilder: (context, i) {
        final seg = segments[i];
        final active = seg.segmentId == activeId;
        if (seg.type == SegmentType.formulaCallout && seg.ref != null && assetPaths.containsKey(seg.ref)) {
          final manifest = state.manifest;
          final formula = manifest.formulaById(seg.ref!);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentHighlighter(
                  segment: seg,
                  active: active,
                  fontScale: fontScale,
                  onTap: () => controller.player.seekToSegment(seg),
                ),
                if (formula != null)
                  FormulaView(latex: formula.latex, imagePath: assetPaths[seg.ref]!, active: active),
              ],
            ),
          );
        }
        return SegmentHighlighter(
          segment: seg,
          active: active,
          fontScale: fontScale,
          onTap: () => controller.player.seekToSegment(seg),
        );
      },
    );
  }
}
