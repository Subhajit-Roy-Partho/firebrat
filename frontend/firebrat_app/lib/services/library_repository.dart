import 'dart:convert';
import 'dart:io';
import '../models/book.dart';
import '../models/manifest.dart';
import 'api_client.dart';
import 'download_manager.dart';

/// Merges the remote catalog (if reachable) with what's already downloaded
/// on-device, so the library screen works offline for previously-seen books.
class LibraryRepository {
  final ApiClient api;
  final DownloadManager downloads;
  LibraryRepository(this.api, this.downloads);

  Future<List<BookSummary>> fetchCatalog() => api.listBooks();

  /// Every book already on-device (downloaded from a server, or imported
  /// from a local file — indistinguishable once extracted), built directly
  /// from each local manifest.json. This is what makes the library usable
  /// with zero server ever reachable, as long as you've imported a file.
  Future<List<BookSummary>> listLocalBooks() async {
    final ids = await downloads.listLocalBookIds();
    final result = <BookSummary>[];
    for (final id in ids) {
      try {
        final m = await loadLocalManifest(id);
        final dir = await downloads.bookDir(id);
        result.add(BookSummary(
          bookId: m.bookId,
          title: m.title,
          author: m.author,
          totalDurationMs: m.totalDurationMs,
          sectionCount: m.sections.length,
          sizeBytes: await _dirSize(dir),
          updatedAt: m.generatedAt,
        ));
      } catch (_) {
        // A partially-written or corrupt local package — skip it rather
        // than failing the whole library listing.
        continue;
      }
    }
    return result;
  }

  Future<int> _dirSize(Directory dir) async {
    int total = 0;
    if (!await dir.exists()) return 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }

  Future<Manifest> loadLocalManifest(String bookId) async {
    final dir = await downloads.bookDir(bookId);
    final file = File('${dir.path}/manifest.json');
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return Manifest.fromJson(json);
  }

  Future<String> bookAssetPath(String bookId, String relativePath) async {
    final dir = await downloads.bookDir(bookId);
    return '${dir.path}/$relativePath';
  }
}
