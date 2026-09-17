import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import '../models/segment.dart';
import '../state/library_providers.dart';
import '../state/reader_providers.dart';
import '../state/settings_providers.dart';
import '../theme/app_theme.dart';
import 'focus_mode_screen.dart';
import 'source_pdf_screen.dart';
import '../widgets/section_index_drawer.dart';
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
      drawer: SectionIndexDrawer(bookId: bookId),
      appBar: AppBar(
        title: Text(state.manifest.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.menu_rounded),
              tooltip: 'Sections',
              onPressed: () => Scaffold.of(ctx).openDrawer(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.fullscreen_rounded),
            tooltip: 'Focus mode',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => FocusModeScreen(bookId: bookId)),
            ),
          ),
          _SourcePageAction(bookId: bookId),
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
          _SourcePageButton(bookId: bookId),
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

/// "View source page" app-bar action: opens the embedded source PDF at
/// the first PDF page behind the section currently being read (the
/// screen itself resolves the live section, so no page params needed).
/// Disabled with an explanatory tooltip when the package has no embedded
/// source PDF (old packages) or the section carries no source pages.
class _SourcePageAction extends ConsumerWidget {
  final String bookId;
  const _SourcePageAction({required this.bookId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerControllerProvider(bookId));
    final hasSource = state != null &&
        (state.manifest.sourcePdfPath?.isNotEmpty ?? false) &&
        state.section.sourcePages.isNotEmpty;
    return IconButton(
      icon: const Icon(Icons.picture_as_pdf_outlined),
      tooltip: hasSource
          ? 'View source page'
          : 'Source PDF not included in this package',
      onPressed: state == null || !hasSource
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SourcePdfScreen(bookId: bookId),
                ),
              ),
    );
  }
}

/// Entry point to the shipped source PDF, shown under the section nav bar.
///
/// Visibility rules (graceful old-package behavior):
/// - manifest has no `source_pdf_path` → hidden entirely (old packages).
/// - current section has no `source_pages` → hidden (nothing to open at).
/// - path set but the file isn't on disk (partial download) → shown but
///   disabled, with a tooltip explaining why.
class _SourcePageButton extends ConsumerWidget {
  final String bookId;
  const _SourcePageButton({required this.bookId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerControllerProvider(bookId));
    if (state == null) return const SizedBox.shrink();
    final rel = state.manifest.sourcePdfPath;
    final pages = state.section.sourcePages;
    if (rel == null || pages.isEmpty) return const SizedBox.shrink();

    final label = pages.first == pages.last
        ? 'Source page · p. ${pages.first + 1}'
        : 'Source pages · pp. ${pages.first + 1}–${pages.last + 1}';

    return FutureBuilder<bool>(
      future: _sourcePdfExists(ref),
      builder: (context, snapshot) {
        final exists = snapshot.data ?? false;
        final checking = snapshot.connectionState == ConnectionState.waiting;
        if (!checking && !exists) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: 'Source PDF is not on this device (re-download the book to get it)',
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: Text(label),
                  onPressed: null,
                ),
              ),
            ),
          );
        }
        if (checking) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: Text(label),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => SourcePdfScreen(bookId: bookId)),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _sourcePdfExists(WidgetRef ref) async {
    final state = ref.read(readerControllerProvider(bookId));
    final rel = state?.manifest.sourcePdfPath;
    if (rel == null) return false;
    final repo = ref.read(libraryRepositoryProvider);
    return File(await repo.bookAssetPath(bookId, rel)).exists();
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
