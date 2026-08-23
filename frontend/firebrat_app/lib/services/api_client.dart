import 'package:dio/dio.dart';
import '../models/book.dart';
import '../models/job.dart';

/// Talks to the Firebrat FastAPI backend: the catalog listing, the one-time
/// download (the reader itself never calls this again once a book is
/// on-device, offline-first), and the upload/conversion job queue.
class ApiClient {
  final Dio _dio;
  final String baseUrl;

  ApiClient({required this.baseUrl})
      : _dio = Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: const Duration(seconds: 10)));

  /// True if the server at [baseUrl] is reachable and responding — used to
  /// validate a server URL as soon as the user enters one, before trying
  /// to list or convert anything against it.
  Future<bool> checkHealth() async {
    try {
      final resp = await _dio.get('/health', options: Options(sendTimeout: const Duration(seconds: 5)));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<BookSummary>> listBooks() async {
    final resp = await _dio.get('/books');
    return (resp.data as List)
        .map((e) => BookSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Permanently deletes a book from the server to free space. Irreversible.
  Future<void> deleteBook(String bookId) async {
    await _dio.delete('/books/$bookId');
  }

  /// Uploads a PDF for conversion, reporting 0.0-1.0 upload progress.
  /// Returns the freshly-created job (state usually "queued").
  Future<ConversionJob> uploadBook(
    String pdfPath, {
    String? title,
    void Function(double progress)? onProgress,
  }) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(pdfPath, filename: pdfPath.split('/').last),
      if (title != null && title.isNotEmpty) 'title': title,
    });
    final resp = await _dio.post(
      '/books/upload',
      data: form,
      onSendProgress: (sent, total) {
        if (total > 0 && onProgress != null) onProgress(sent / total);
      },
    );
    return ConversionJob.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<List<ConversionJob>> listJobs() async {
    final resp = await _dio.get('/jobs');
    return (resp.data as List).map((e) => ConversionJob.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ConversionJob> getJob(String jobId) async {
    final resp = await _dio.get('/jobs/$jobId');
    return ConversionJob.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<ConversionJob> retryJob(String jobId) async {
    final resp = await _dio.post('/jobs/$jobId/retry');
    return ConversionJob.fromJson(resp.data as Map<String, dynamic>);
  }

  /// Puts a stuck queued/running job back on the server's work queue. The
  /// server already does this automatically on its own restart — this is
  /// for the rarer case a job still looks stuck for some other reason.
  Future<ConversionJob> resumeJob(String jobId) async {
    final resp = await _dio.post('/jobs/$jobId/resume');
    return ConversionJob.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<List<String>> getJobLog(String jobId, {int tailLines = 200}) async {
    final resp = await _dio.get('/jobs/$jobId/log', queryParameters: {'tail_lines': tailLines});
    return (resp.data['lines'] as List).cast<String>();
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
