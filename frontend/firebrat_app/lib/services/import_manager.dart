import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'download_manager.dart';

/// Imports a book package the user picks from local storage — a .tar.gz
/// produced by the backend's packaging step, or a .zip (same layout, either
/// works). This is the "no server required" path: sideload a file onto the
/// device (USB, a messaging app, cloud storage) and read it with zero
/// network access, ever.
class ImportManager {
  final DownloadManager downloads;
  ImportManager(this.downloads);

  /// Opens the system file picker filtered to archive files. Returns null
  /// if the user cancelled.
  Future<File?> pickArchiveFile() async {
    // file_picker 12 returns the picked files directly (empty = cancelled).
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['gz', 'tgz', 'zip'],
    );
    if (files.isEmpty) return null;
    final path = files.single.path;
    if (path == null) return null;
    return File(path);
  }

  /// Extracts [archiveFile] and returns the book_id it contained. Two
  /// formats are accepted:
  /// - a narrated package (has manifest.json) — stored as-is;
  /// - a "chapter zip": no manifest, but one or more `.pdf` files, each
  ///   treated as a chapter (sorted by path). A minimal manifest with
  ///   `"kind": "chapters"` is synthesized so the library + reader treat
  ///   it as a first-class book (PDF per chapter, no audio).
  /// Throws if the file isn't a recognized format or has neither.
  Future<String> importFromFile(File archiveFile) async {
    final bytes = await archiveFile.readAsBytes();
    final name = archiveFile.path.toLowerCase();

    final Archive archive;
    if (name.endsWith('.tar.gz') || name.endsWith('.tgz')) {
      final tarBytes = const GZipDecoder().decodeBytes(bytes);
      archive = TarDecoder().decodeBytes(tarBytes);
    } else if (name.endsWith('.zip')) {
      archive = ZipDecoder().decodeBytes(bytes);
    } else {
      throw const FormatException('Unrecognized archive type — expected .tar.gz, .tgz, or .zip');
    }

    // Extract to a staging dir first so we can read manifest.json for the
    // real book_id before committing to books/<book_id>/ (the archive's
    // filename on disk isn't a reliable source of truth for the id).
    final books = await downloads.booksDir();
    final staging = Directory('${books.path}/_importing_${DateTime.now().millisecondsSinceEpoch}');
    await DownloadManager.extractArchiveTo(archive, staging);

    late final String bookId;
    try {
      final manifestFile = File('${staging.path}/manifest.json');
      final manifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      bookId = manifest['book_id'] as String;
    } catch (_) {
      // No usable manifest — maybe a chapter zip (PDFs, no manifest)?
      await staging.delete(recursive: true);
      return _importChapterZip(archiveFile, bytes, name);
    }

    final target = await downloads.bookDir(bookId);
    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);
    return bookId;
  }

  /// Builds a chapter-PDF book from a zip of PDFs: copies each PDF into
  /// `chapters/`, synthesizes a `kind: chapters` manifest (titles from
  /// filenames, `chapter_pdf` per section), and stores any top-level image
  /// as the cover. book_id derives from the zip filename, sanitized.
  Future<String> _importChapterZip(File archiveFile, List<int> bytes, String lowerName) async {
    if (!lowerName.endsWith('.zip')) {
      throw const FormatException(
          'No manifest.json and no chapter PDFs found — expected a book package or a zip of chapter PDFs');
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    final pdfs = archive.files
        .where((f) => f.isFile && f.name.toLowerCase().endsWith('.pdf'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (pdfs.isEmpty) {
      throw const FormatException('Zip contains no .pdf chapters and no manifest.json');
    }
    final base = archiveFile.uri.pathSegments.last.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
    final bookId = base
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '')
        .ifEmpty('chapter-book');
    final target = await downloads.bookDir(bookId);
    if (await target.exists()) await target.delete(recursive: true);
    await Directory('${target.path}/chapters').create(recursive: true);
    final sections = <Map<String, dynamic>>[];
    var order = 0;
    for (final entry in pdfs) {
      final fileName = entry.name.split('/').last;
      final stem = fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
      final rel = 'chapters/${_safeName(order, fileName)}';
      final out = File('${target.path}/$rel');
      await out.create(recursive: true);
      await out.writeAsBytes(entry.content as List<int>);
      order++;
      sections.add({
        'section_id': 'sec_${order.toString().padLeft(4, '0')}',
        'order': order,
        'title': stem.replaceAll(RegExp(r'[_-]+'), ' ').trim().ifEmpty('Chapter $order'),
        'audio_path': '',
        'segments_path': '',
        'duration_ms': 0,
        'figure_refs': [],
        'formula_refs': [],
        'table_refs': [],
        'needs_review': false,
        'source_pages': [],
        'chapter_pdf': rel,
      });
    }
    // First top-level image becomes the cover (shown on the library card).
    for (final entry in archive.files) {
      final n = entry.name.toLowerCase();
      if (entry.isFile &&
          !entry.name.contains('/') &&
          (n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.webp'))) {
        final ext = n.split('.').last;
        final cover = File('${target.path}/cover.$ext');
        await cover.writeAsBytes(entry.content as List<int>);
        break;
      }
    }
    final manifest = {
      'book_id': bookId,
      'title': base.replaceAll(RegExp(r'[_-]+'), ' ').trim(),
      'author': '',
      'kind': 'chapters',
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'total_duration_ms': 0,
      'sections': sections,
      'figures': [],
      'formulas': [],
      'tables': [],
    };
    await File('${target.path}/manifest.json')
        .writeAsString(jsonEncode(manifest));
    return bookId;
  }

  static String _safeName(int order, String fileName) =>
      '${order.toString().padLeft(2, '0')}-${fileName.split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
