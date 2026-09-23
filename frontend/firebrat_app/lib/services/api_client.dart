import 'dart:io';
import 'package:dio/dio.dart';
import '../models/book.dart';
import '../models/job.dart';
import 'auth_service.dart';

/// Server answered a byte-range request from an unexpected offset (or with
/// an unexpected status) — the local `.part` file can't be trusted, the
/// caller should discard it and start over.
class DownloadIntegrityException implements Exception {
  final String message;
  const DownloadIntegrityException(this.message);
  @override
  String toString() => 'DownloadIntegrityException: $message';
}

/// Talks to the Firebrat FastAPI backend: the catalog listing, the one-time
/// download (the reader itself never calls this again once a book is
/// on-device, offline-first), and the upload/conversion job queue.
class ApiClient {
  final Dio _dio;
  final String baseUrl;

  ApiClient({required this.baseUrl})
      : _dio = Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: const Duration(seconds: 10))) {
    // Firebase ID token on every call when signed in (anonymous otherwise —
    // the server decides per-endpoint what anonymous callers may do).
    // Token fetch failures must never break a call: fall through unsigned.
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        try {
          final token = await AuthService.instance.idToken();
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
        } catch (_) {}
        handler.next(options);
      },
    ));
  }

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

  /// Uploads a PDF — or a .zip of PDFs, which the server merges in
  /// archive order — for conversion, reporting 0.0-1.0 upload progress.
  /// Returns the freshly-created job (state usually "queued").
  Future<ConversionJob> uploadBook(
    String filePath, {
    String? title,
    void Function(double progress)? onProgress,
  }) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: filePath.split('/').last),
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

  /// Exact byte size + sha256 of the zip `/download` serves for [bookId].
  /// The download manager fetches this first (resume needs the true total)
  /// and verifies the completed file against it before extracting.
  Future<({int sizeBytes, String sha256})> getPackageChecksum(String bookId) async {
    final resp = await _dio.get('/books/$bookId/checksum');
    final data = resp.data as Map<String, dynamic>;
    return (
      sizeBytes: (data['size_bytes'] as num).toInt(),
      sha256: data['sha256'] as String,
    );
  }

  /// Downloads the book's zip package to [savePath], resuming from an
  /// existing `.part` file when the server honors `Range` (it does —
  /// Starlette `FileResponse` answers 206). Reports cumulative
  /// (receivedBytes, totalBytes); totalBytes is the authoritative size
  /// passed in (from [getPackageChecksum]), NOT the response's
  /// content-length, which is only the remaining slice on a 206.
  ///
  /// Throws [DownloadIntegrityException] when the server answers 206 with
  /// a range that doesn't start where asked (stale/mismatched part file).
  Future<void> downloadBook(
    String bookId,
    String savePath, {
    required int expectedTotal,
    void Function(int receivedBytes, int totalBytes)? onBytes,
    CancelToken? cancelToken,
  }) async {
    final partPath = '$savePath.part';
    final partFile = File(partPath);
    var have = await partFile.exists() ? await partFile.length() : 0;
    if (have >= expectedTotal && expectedTotal > 0) {
      // A previous run already fetched every byte — skip the network.
      await partFile.rename(savePath);
      onBytes?.call(expectedTotal, expectedTotal);
      return;
    }

    final headers = <String, dynamic>{};
    if (have > 0) headers['Range'] = 'bytes=$have-';
    final resp = await _dio.get<ResponseBody>(
      '/books/$bookId/download',
      cancelToken: cancelToken,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
        // A 500MB book over a slow relay legitimately idles between
        // chunks; only the connect phase gets a deadline.
        receiveTimeout: null,
      ),
    );

    final status = resp.statusCode ?? 200;
    if (have > 0) {
      if (status == 200) {
        // Server ignored Range — restart cleanly rather than appending
        // a full body onto a prefix (guaranteed corrupt zip).
        have = 0;
        if (await partFile.exists()) await partFile.delete();
      } else if (status != 206) {
        throw DownloadIntegrityException(
            'Unexpected status $status for range resume of $bookId');
      } else {
        final contentRange = resp.headers.value('content-range') ?? '';
        if (!contentRange.startsWith('bytes $have-')) {
          throw DownloadIntegrityException(
              'Server resumed at $contentRange, expected bytes starting at $have');
        }
      }
    }

    final sink = partFile.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    var received = have;
    try {
      await for (final chunk in resp.data!.stream) {
        sink.add(chunk);
        received += (chunk as List<int>).length;
        onBytes?.call(received, expectedTotal);
      }
      await sink.flush();
      await sink.close();
      await partFile.rename(savePath);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      rethrow;
    }
  }
}
