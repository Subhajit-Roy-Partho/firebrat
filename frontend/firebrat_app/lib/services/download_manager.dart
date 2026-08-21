import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'api_client.dart';

/// Downloads a book's zip package once and extracts it into the app's
/// documents directory. After this, the reader reads only local files —
/// no network needed (offline-first, per the project's design).
class DownloadManager {
  final ApiClient api;
  DownloadManager(this.api);

  Future<Directory> _booksDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/books');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> bookDir(String bookId) async {
    final books = await _booksDir();
    return Directory('${books.path}/$bookId');
  }

  Future<bool> isDownloaded(String bookId) async {
    final dir = await bookDir(bookId);
    return File('${dir.path}/manifest.json').exists();
  }

  Future<Directory> downloadAndExtract(
    String bookId, {
    void Function(double progress)? onProgress,
  }) async {
    final books = await _booksDir();
    final zipPath = '${books.path}/$bookId.zip';
    await api.downloadBook(bookId, zipPath, onProgress: onProgress);

    final target = await bookDir(bookId);
    if (await target.exists()) await target.delete(recursive: true);
    await target.create(recursive: true);

    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      final outPath = '${target.path}/${file.name}';
      if (file.isFile) {
        final outFile = File(outPath);
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
    await File(zipPath).delete();

    if (!await File('${target.path}/manifest.json').exists()) {
      throw StateError('Downloaded package for $bookId is missing manifest.json');
    }
    return target;
  }

  Future<void> deleteBook(String bookId) async {
    final dir = await bookDir(bookId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
