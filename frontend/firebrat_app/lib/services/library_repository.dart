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
