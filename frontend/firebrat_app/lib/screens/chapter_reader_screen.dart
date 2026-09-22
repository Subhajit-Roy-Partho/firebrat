import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../models/manifest.dart';
import '../state/library_providers.dart';

/// Reader for chapter-PDF books (`kind: chapters` manifests from a chapter
/// zip import): no audio, no narration — a chapter list where each row
/// opens its PDF with full page navigation (same viewer engine as the
/// source-PDF screen).
class ChapterReaderScreen extends ConsumerWidget {
  final String bookId;
  const ChapterReaderScreen({super.key, required this.bookId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manifestAsync = ref.watch(chapterManifestProvider(bookId));
    return Scaffold(
      appBar: AppBar(title: const Text('Chapters')),
      body: manifestAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not open book:\n$e')),
        data: (manifest) => ListView.builder(
          itemCount: manifest.sections.length,
          itemBuilder: (context, i) {
            final s = manifest.sections[i];
            return ListTile(
              leading: CircleAvatar(child: Text('${i + 1}')),
              title: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(s.chapterPdf.isEmpty ? 'PDF missing' : s.chapterPdf.split('/').last),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: s.chapterPdf.isNotEmpty,
              onTap: s.chapterPdf.isEmpty
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => _ChapterPdfView(
                          bookId: bookId,
                          title: s.title,
                          relPath: s.chapterPdf,
                        ),
                      )),
            );
          },
        ),
      ),
    );
  }
}

final chapterManifestProvider =
    FutureProvider.family<Manifest, String>((ref, bookId) async {
  final dm = ref.read(downloadManagerProvider);
  final dir = await dm.bookDir(bookId);
  final file = File('${dir.path}/manifest.json');
  return Manifest.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
});

class _ChapterPdfView extends StatefulWidget {
  final String bookId;
  final String title;
  final String relPath;
  const _ChapterPdfView({
    required this.bookId,
    required this.title,
    required this.relPath,
  });

  @override
  State<_ChapterPdfView> createState() => _ChapterPdfViewState();
}

class _ChapterPdfViewState extends State<_ChapterPdfView> {
  final PdfViewerController _controller = PdfViewerController();
  String? _absPath;
  int _page = 1;
  int _count = 1;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final docs = await getApplicationDocumentsDirectory();
    final abs = '${docs.path}/books/${widget.bookId}/${widget.relPath}';
    if (mounted) setState(() => _absPath = abs);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: 'Previous page',
            onPressed: () => _controller.previousPage(),
          ),
          Center(child: Text('$_page / $_count')),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: 'Next page',
            onPressed: () => _controller.nextPage(),
          ),
        ],
      ),
      body: _absPath == null
          ? const Center(child: CircularProgressIndicator())
          : SfPdfViewer.file(
              File(_absPath!),
              controller: _controller,
              onDocumentLoaded: (details) => setState(() {
                _count = details.document.pages.count;
              }),
              onPageChanged: (details) => setState(() {
                _page = details.newPageNumber;
              }),
            ),
    );
  }
}
