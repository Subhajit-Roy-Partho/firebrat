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
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['gz', 'tgz', 'zip'],
      withData: false,
    );
    final path = result?.files.single.path;
    if (path == null) return null;
    return File(path);
  }

  /// Extracts [archiveFile] and returns the book_id it contained. Throws if
  /// the file isn't a recognized format or doesn't contain a valid package.
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
    } catch (e) {
      await staging.delete(recursive: true);
      rethrow;
    }

    final target = await downloads.bookDir(bookId);
    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);
    return bookId;
  }
}
