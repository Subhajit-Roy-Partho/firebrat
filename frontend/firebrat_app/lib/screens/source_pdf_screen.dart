import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../state/library_providers.dart';
import '../state/reader_providers.dart';

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
    final initial = pages.isNotEmpty ? pages.first + 1 : 1;
    return _LoadedSourcePdf(
      title: manifest.title,
      file: file,
      initialPageNumber: initial,
      sectionTitle: reader?.section.title ?? '',
    );
  }

  /// 1-based page of the section currently being read (null if unmapped).
  int? _currentSectionPage() {
    final reader = ref.watch(readerControllerProvider(widget.bookId));
    final pages = reader?.section.sourcePages ?? const <int>[];
    return pages.isNotEmpty ? pages.first + 1 : null;
  }

  void _goToPage(int page) {
    if (_pageCount < 1) return;
    final target = page.clamp(1, _pageCount);
    _controller.jumpToPage(target);
  }

  @override
  Widget build(BuildContext context) {
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
                  data.sectionTitle,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.my_location_rounded),
                tooltip: 'Jump to current section',
                onPressed: () {
                  final p = _currentSectionPage();
                  if (p != null) _goToPage(p);
                },
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: SfPdfViewer.file(
                  data.file,
                  controller: _controller,
                  initialPageNumber: 1,
                  onDocumentLoaded: (details) {
                    if (!mounted) return;
                    final count = details.document.pages.count;
                    final target = count > 0
                        ? data.initialPageNumber.clamp(1, count)
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
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.my_location_rounded),
                          label: const Text('Jump to current section'),
                          onPressed: () {
                            final p = _currentSectionPage();
                            if (p == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Current section has no page mapping.',
                                  ),
                                ),
                              );
                              return;
                            }
                            _goToPage(p);
                          },
                        ),
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
