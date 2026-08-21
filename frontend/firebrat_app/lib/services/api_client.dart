import 'package:dio/dio.dart';
import '../models/book.dart';

/// Talks to the Firebrat FastAPI backend. Only used for the catalog listing
/// and the one-time download — the reader itself never calls this once a
/// book is on-device (offline-first).
class ApiClient {
  final Dio _dio;
  final String baseUrl;

  ApiClient({required this.baseUrl})
      : _dio = Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: const Duration(seconds: 10)));

  Future<List<BookSummary>> listBooks() async {
    final resp = await _dio.get('/books');
    return (resp.data as List)
        .map((e) => BookSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> getManifest(String bookId) async {
    final resp = await _dio.get('/books/$bookId/manifest');
    return resp.data as Map<String, dynamic>;
  }

  /// Downloads the book's zip package to [savePath], reporting 0.0-1.0 progress.
  Future<void> downloadBook(
    String bookId,
    String savePath, {
    void Function(double progress)? onProgress,
  }) async {
    await _dio.download(
      '/books/$bookId/download',
      savePath,
      onReceiveProgress: (received, total) {
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      },
    );
  }
}
