import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'api_client.dart';

/// Downloads a book's zip package once and extracts it into the app's
/// documents directory. After this, the reader reads only local files —
/// no network needed (offline-first, per the project's design). Also used
/// by ImportManager to locate/write into the same on-device book storage
/// for books brought in from a local .tar.gz/.zip file instead.
class DownloadManager {
  final ApiClient api;
  DownloadManager(this.api);

  Future<Directory> booksDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/books');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> bookDir(String bookId) async {
    final books = await booksDir();
    return Directory('${books.path}/$bookId');
  }

  Future<bool> isDownloaded(String bookId) async {
    final dir = await bookDir(bookId);
    return File('${dir.path}/manifest.json').exists();
  }

  /// book_ids of every book already present on-device — downloaded or
  /// imported, both end up here identically.
  Future<List<String>> listLocalBookIds() async {
    final books = await booksDir();
    if (!await books.exists()) return [];
    final ids = <String>[];
    await for (final entry in books.list()) {
      if (entry is Directory && await File('${entry.path}/manifest.json').exists()) {
        ids.add(entry.uri.pathSegments.where((s) => s.isNotEmpty).last);
      }
    }
    return ids;
  }

  /// Extracts an in-memory archive's contents flatly into [target]
  /// (replacing anything already there). Shared by the download and
  /// import paths — both produce identically-laid-out book directories.
  static Future<void> extractArchiveTo(Archive archive, Directory target) async {
    if (await target.exists()) await target.delete(recursive: true);
    await target.create(recursive: true);
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
    if (!await File('${target.path}/manifest.json').exists()) {
      throw StateError('Package at ${target.path} is missing manifest.json');
    }
  }

  Future<Directory> downloadAndExtract(
    String bookId, {
    void Function(double progress)? onProgress,
  }) async {
    final books = await booksDir();
    final zipPath = '${books.path}/$bookId.zip';
    await api.downloadBook(bookId, zipPath, onProgress: onProgress);

    final target = await bookDir(bookId);
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    await extractArchiveTo(archive, target);
    await File(zipPath).delete();
    return target;
  }

  Future<void> deleteBook(String bookId) async {
    final dir = await bookDir(bookId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
