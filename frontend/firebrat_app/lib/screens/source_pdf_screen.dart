import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../state/library_providers.dart';
import '../state/reader_providers.dart';
import '../widgets/pdf_image_selection.dart';

/// Shows the book's shipped `source.pdf` (package root + manifest
/// `source_pdf_path`) opened at the current section's first source page.
///
/// Page numbers in the manifest are 0-based PDF indices; the viewer is
/// 1-based, so +1 on the way in and -1 on the way out. Old packages
/// without `source_pdf_path` (or without the file on disk) never reach
/// here — the reader hides the entry point for those (see reader_screen).
class SourcePdfScreen extends ConsumerStatefulWidget {
  final String bookId;
  const SourcePdfScreen({super.key, required this.bookId});

  @override
  ConsumerState<SourcePdfScreen> createState() => _SourcePdfScreenState();
}

class _LoadedSourcePdf {
  final String title;
  final File file;
  final int initialPageNumber; // 1-based
  final String sectionTitle;
  const _LoadedSourcePdf({
    required this.title,
    required this.file,
    required this.initialPageNumber,
    required this.sectionTitle,
  });
}

class _SourcePdfScreenState extends ConsumerState<SourcePdfScreen> {
  final PdfViewerController _controller = PdfViewerController();
  late final Future<_LoadedSourcePdf?> _loadFuture;
  int _currentPage = 1;
  int _pageCount = 0;
  final _pdfKey = GlobalKey();
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    _loadFuture = _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<_LoadedSourcePdf?> _load() async {
    final repo = ref.read(libraryRepositoryProvider);
    final manifest = await repo.loadLocalManifest(widget.bookId);
    final rel = manifest.sourcePdfPath;
    if (rel == null) return null;
    final absPath = await repo.bookAssetPath(widget.bookId, rel);
    final file = File(absPath);
    if (!await file.exists()) return null;
    final reader = ref.read(readerControllerProvider(widget.bookId));
    final pages = reader?.section.sourcePages ?? const <int>[];
    final selectedPage = reader?.selectedSourceVisual?.sourcePage;
    final initial = selectedPage != null
        ? selectedPage + 1
        : pages.isNotEmpty
        ? pages.first + 1
        : 1;
    return _LoadedSourcePdf(
      title: manifest.title,
      file: file,
      initialPageNumber: initial,
      sectionTitle: reader?.section.title ?? '',
    );
  }

  /// 1-based page of the section currently being read (null if unmapped).
  int? _currentSectionPage() {
    final reader = ref.read(readerControllerProvider(widget.bookId));
    final sourcePage = reader?.selectedSourceVisual?.sourcePage;
    if (sourcePage != null) return sourcePage + 1;
    final pages = reader?.section.sourcePages ?? const <int>[];
    return pages.isNotEmpty ? pages.first + 1 : null;
  }

  void _goToPage(int page) {
    if (_pageCount < 1) return;
    final target = page.clamp(1, _pageCount);
    _controller.jumpToPage(target);
  }

  Future<void> _selectImage() async {
    final reader = ref.read(readerControllerProvider(widget.bookId));
    if (reader == null || reader.loadingSection || _selecting) return;
    final sectionId = reader.section.sectionId;
    final page = _currentPage - 1;
    setState(() => _selecting = true);
    ui.Image? image;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final boundary =
          _pdfKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || boundary.debugNeedsPaint) {
        throw StateError('PDF still rendering');
      }
      image = await boundary.toImage(pixelRatio: 2);
      if (!mounted) return;
      final png = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(builder: (_) => PdfImageSelection(image: image!)),
      );
      if (png == null || !mounted) return;
      await ref
          .read(readerControllerProvider(widget.bookId).notifier)
          .selectSourceVisual(sectionId, page, png);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image saved for ${reader.section.title}.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not save the image. Wait for the PDF to finish loading and try again.',
            ),
          ),
        );
      }
    } finally {
      image?.dispose();
      if (mounted) setState(() => _selecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reader = ref.watch(readerControllerProvider(widget.bookId));
    ref.listen(
      readerControllerProvider(
        widget.bookId,
      ).select((s) => (s?.sectionIndex, s?.loadingSection)),
      (previous, next) {
        if (previous == next ||
            next.$1 == null ||
            next.$2 != false ||
            _selecting) {
          return;
        }
        final page = _currentSectionPage();
        if (page != null) _goToPage(page);
      },
    );
    return FutureBuilder<_LoadedSourcePdf?>(
      future: _loadFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          final missing = snapshot.connectionState == ConnectionState.done;
          return Scaffold(
            appBar: AppBar(title: const Text('Source page')),
            body: Center(
              child: snapshot.hasError
                  ? Text('Could not open the source PDF: ${snapshot.error}')
                  : missing
                  ? const Text('This book has no source PDF on this device.')
                  : const CircularProgressIndicator(),
            ),
          );
        }
        final data = snapshot.data!;
        // The section page can be far beyond page 1 before the PDF loads.
        // Keep slider bounds valid until the document supplies its real count.
        final sliderMax = _pageCount > 0 ? _pageCount : 1;
        final sliderPage = _currentPage.clamp(1, sliderMax);
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Source page'),
                Text(
                  reader?.section.title ?? data.sectionTitle,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            actions: [
              if (reader?.selectedSourceVisual != null)
                IconButton(
                  icon: const Icon(Icons.image_not_supported_outlined),
                  tooltip: 'Use automatic section images',
                  onPressed: _selecting || reader!.loadingSection
                      ? null
                      : () async {
                          try {
                            await ref
                                .read(
                                  readerControllerProvider(
                                    widget.bookId,
                                  ).notifier,
                                )
                                .clearSourceVisual();
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Could not remove the selected image. Try again.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: RepaintBoundary(
                  key: _pdfKey,
                  child: SfPdfViewer.file(
                    data.file,
                    controller: _controller,
                    pageLayoutMode: PdfPageLayoutMode.single,
                    initialPageNumber: 1,
                    onDocumentLoaded: (details) {
                      if (!mounted) return;
                      final count = details.document.pages.count;
                      final target = count > 0
                          ? (_currentSectionPage() ?? data.initialPageNumber)
                                .clamp(1, count)
                          : 1;
                      setState(() {
                        _pageCount = count;
                        _currentPage = target;
                      });
                      if (count > 0) _controller.jumpToPage(target);
                    },
                    onPageChanged: (details) {
                      if (!mounted || _pageCount < 1) return;
                      setState(
                        () => _currentPage = details.newPageNumber.clamp(
                          1,
                          _pageCount,
                        ),
                      );
                    },
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chevron_left_rounded),
                            tooltip: 'Previous page',
                            onPressed: _currentPage > 1
                                ? () => _goToPage(_currentPage - 1)
                                : null,
                          ),
                          Expanded(
                            child: SourcePdfPageSlider(
                              currentPage: _currentPage,
                              pageCount: _pageCount,
                              onPageSelected: _goToPage,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right_rounded),
                            tooltip: 'Next page',
                            onPressed: _currentPage < _pageCount
                                ? () => _goToPage(_currentPage + 1)
                                : null,
                          ),
                          Text(
                            _pageCount > 0
                                ? 'p. $sliderPage / $_pageCount'
                                : 'Loading pages…',
                          ),
                        ],
                      ),
                      SourcePdfTransport(
                        bookId: widget.bookId,
                        onJump: _pageCount > 0 && _currentSectionPage() != null
                            ? () => _goToPage(_currentSectionPage()!)
                            : null,
                        onSelectImage:
                            _pageCount > 0 &&
                                !_selecting &&
                                reader != null &&
                                !reader.loadingSection
                            ? _selectImage
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Compact PDF controls use the reader's existing playback session.
class SourcePdfTransport extends ConsumerWidget {
  final String bookId;
  final VoidCallback? onJump;
  final VoidCallback? onSelectImage;
  const SourcePdfTransport({
    super.key,
    required this.bookId,
    this.onJump,
    this.onSelectImage,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerControllerProvider(bookId));
    final controller = ref.read(readerControllerProvider(bookId).notifier);
    final ready = state != null && !state.loadingSection && state.error == null;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.my_location_rounded),
          tooltip: 'Jump to current section',
          onPressed: onJump,
        ),
        IconButton(
          icon: const Icon(Icons.skip_previous_rounded),
          tooltip: 'Previous section',
          onPressed: ready && state.sectionIndex > 0
              ? controller.previousSection
              : null,
        ),
        StreamBuilder(
          stream: controller.player.playerStateStream,
          builder: (context, snapshot) {
            final playing =
                snapshot.data?.playing ?? controller.player.isPlaying;
            return IconButton.filled(
              icon: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: ready
                  ? () => playing
                        ? controller.player.pause()
                        : controller.player.play()
                  : null,
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.skip_next_rounded),
          tooltip: 'Next section',
          onPressed:
              ready && state.sectionIndex < state.manifest.sections.length - 1
              ? controller.nextSection
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.crop_rounded),
          tooltip: 'Select image from PDF',
          onPressed: onSelectImage,
        ),
      ],
    );
  }
}

/// Keeps document-loading and stale page callbacks outside Slider's assertions.
class SourcePdfPageSlider extends StatelessWidget {
  final int currentPage;
  final int pageCount;
  final ValueChanged<int> onPageSelected;
  const SourcePdfPageSlider({
    super.key,
    required this.currentPage,
    required this.pageCount,
    required this.onPageSelected,
  });

  @override
  Widget build(BuildContext context) {
    final maximum = pageCount > 0 ? pageCount : 1;
    final page = currentPage.clamp(1, maximum);
    return Slider(
      value: page.toDouble(),
      min: 1,
      max: maximum.toDouble(),
      divisions: maximum > 1 ? maximum - 1 : null,
      label: 'p. $page',
      onChanged: pageCount > 1
          ? (value) => onPageSelected(value.round())
          : null,
    );
  }
}
