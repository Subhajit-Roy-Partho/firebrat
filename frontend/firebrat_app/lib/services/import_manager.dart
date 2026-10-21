import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import '../utils/tar_stream.dart';
import 'download_manager.dart';

/// Imports a book package the user picks from local storage — a .tar.gz
/// produced by the backend's packaging step, or a .zip (same layout, either
/// works). This is the "no server required" path: sideload a file onto the
/// device (USB, a messaging app, cloud storage) and read it with zero
/// network access, ever.
///
/// Memory contract: book packages are ~1 GB. Nothing here may hold the
/// archive (or its decompressed form) in memory — .tar.gz streams entry by
/// entry to disk ([extractTarGzToDir]), .zip streams via
/// `extractFileToDisk`. The previous implementation did
/// `readAsBytes()` + in-memory decode of the whole file and was reliably
/// killed by the OS on real book sizes.
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
  /// Extraction streams to a staging dir; the live book dir is only
  /// swapped in on success (via a backup rename), so a failed import can
  /// never destroy a previously-good book.
  /// Throws if the file isn't a recognized format or has neither.
  Future<String> importFromFile(
    File archiveFile, {
    void Function(double fraction)? onProgress,
  }) async {
    final name = archiveFile.path.toLowerCase();

    // Extract to a staging dir first so we can read manifest.json for the
    // real book_id before committing to the books dir (the archive's
    // filename on disk isn't a reliable source of truth for the id).
    final books = await downloads.booksDir();
    final staging = Directory('${books.path}/_importing_${DateTime.now().millisecondsSinceEpoch}');
    try {
      if (name.endsWith('.tar.gz') || name.endsWith('.tgz')) {
        await extractTarGzToDir(archiveFile.path, staging.path, onProgress: onProgress);
      } else if (name.endsWith('.zip')) {
        // Zip entries stream from the open file via extractFileToDisk —
        // flat memory regardless of package size.
        extractFileToDisk(archiveFile.path, staging.path);
      } else {
        throw const FormatException('Unrecognized archive type — expected .tar.gz, .tgz, or .zip');
      }

      final manifestFile = File('${staging.path}/manifest.json');
      if (!await manifestFile.exists()) {
        // No usable manifest — maybe a chapter zip (PDFs, no manifest)?
        if (name.endsWith('.zip')) {
          return await _importChapterZipFromDir(staging, archiveFile);
        }
        throw const FormatException(
            'No manifest.json found — expected a book package (.tar.gz/.zip) or a zip of chapter PDFs');
      }
      final manifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final bookId = sanitizeBookId(manifest['book_id']);

      await _commitStaging(staging, await downloads.bookDir(bookId));
      return bookId;
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  /// Moves [staging] over [target], keeping a backup until the swap
  /// succeeds so a crash mid-import can't lose a previously-good book.
  Future<void> _commitStaging(Directory staging, Directory target) async {
    Directory? backup;
    if (await target.exists()) {
      backup = Directory('${target.path}.bak_${DateTime.now().millisecondsSinceEpoch}');
      if (await backup.exists()) await backup.delete(recursive: true);
      await target.rename(backup.path);
    }
    try {
      await staging.rename(target.path);
    } catch (_) {
      if (backup != null && await backup.exists()) {
        try {
          if (await target.exists()) await target.delete(recursive: true);
          await backup.rename(target.path);
        } catch (_) {}
      }
      rethrow;
    }
    if (backup != null && await backup.exists()) {
      await backup.delete(recursive: true);
    }
  }

  /// Builds a chapter-PDF book from an already-extracted zip staging dir:
  /// every PDF becomes a chapter (sorted by relative path), copied into
  /// `chapters/` without ever loading file bytes into memory. A minimal
  /// `kind: chapters` manifest is synthesized, and any top-level image
  /// becomes the cover. book_id derives from the zip filename, sanitized.
  Future<String> _importChapterZipFromDir(Directory staging, File archiveFile) async {
    final pdfs = <File>[];
    await for (final entity in staging.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.pdf')) pdfs.add(entity);
    }
    pdfs.sort((a, b) => a.path.compareTo(b.path));
    if (pdfs.isEmpty) {
      throw const FormatException('Zip contains no .pdf chapters and no manifest.json');
    }
    final base = archiveFile.uri.pathSegments.last.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
    final bookId = sanitizeBookId(base, fallback: 'chapter-book');
    final target = await downloads.bookDir(bookId);
    if (await target.exists()) await target.delete(recursive: true);
    await Directory('${target.path}/chapters').create(recursive: true);
    final sections = <Map<String, dynamic>>[];
    var order = 0;
    for (final pdf in pdfs) {
      final fileName = pdf.uri.pathSegments.last;
      final stem = fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
      final rel = 'chapters/${_safeName(order, fileName)}';
      await pdf.copy('${target.path}/$rel');
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
    await for (final entity in staging.list(followLinks: false)) {
      if (entity is! File) continue;
      final n = entity.path.toLowerCase();
      if (n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.webp')) {
        final ext = n.split('.').last;
        await entity.copy('${target.path}/cover.$ext');
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
    await File('${target.path}/manifest.json').writeAsString(jsonEncode(manifest));
    return bookId;
  }

  static String _safeName(int order, String fileName) =>
      '${order.toString().padLeft(2, '0')}-${fileName.split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';
}

/// Sanitizes a manifest/archive-derived book_id into a safe directory name.
/// Slugs we generate pass through unchanged; anything with path separators
/// or traversal collapses to dashes (leading dots stripped) instead of
/// escaping the books dir.
String sanitizeBookId(Object? raw, {String fallback = 'book'}) {
  final s = (raw as String? ?? '').trim().toLowerCase();
  final clean = s
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^[\.\-]+'), '');
  if (clean.isEmpty || clean == '.' || clean == '..') {
    // Default (strict) mode: a corrupt/empty id fails loudly instead of
    // importing as a generic "book" dir that would collide with others.
    // Callers with an explicit fallback (chapter-zip filenames) get that.
    if (fallback == 'book') {
      throw FormatException('Book package has an invalid book_id: "$s"');
    }
    return fallback;
  }
  return clean;
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
