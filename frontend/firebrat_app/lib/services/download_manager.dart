import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'api_client.dart';
import 'download_task_handler.dart';

/// Phase-aware progress snapshot. The UI shows `downloadedMb/totalMb · pct`
/// from this instead of a bare fraction — raw Dio chunk callbacks fire
/// hundreds of times per second and bare fractions visibly jitter; the
/// notifier smooths those into these stable snapshots.
class DownloadProgress {
  final double fraction; // 0.0–1.0, download mapped to 0–0.92, verify/extract above
  final int receivedBytes;
  final int? totalBytes; // null while the checksum endpoint is unreachable
  final String phase; // 'downloading' | 'verifying' | 'extracting' | 'done'

  const DownloadProgress({
    required this.fraction,
    required this.receivedBytes,
    required this.totalBytes,
    required this.phase,
  });

  String get label {
    final got = _mb(receivedBytes);
    final pct = (fraction.clamp(0.0, 1.0) * 100).toStringAsFixed(0);
    if (totalBytes == null || totalBytes == 0) return '$got MB · $pct%';
    return '$got / ${_mb(totalBytes!)} MB · $pct%';
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);
}

/// Downloads a book's zip package once and extracts it into the app's
/// documents directory. After this, the reader reads only local files —
/// no network needed (offline-first, per the project's design). Also used
/// by ImportManager to locate/write into the same on-device book storage
/// for books brought in from a local .tar.gz/.zip file instead.
///
/// Reliability contract (books are 300–500MB over an often-relayed
/// Tailscale link, and Android kills backgrounded network):
/// - Single-flight per bookId: concurrent taps share one future instead
///   of interleaving two progress streams into the same file (that was
///   the violent progress-bar fluctuation).
/// - Resume: an interrupted transfer leaves a `.part` file; the next run
///   continues from its length via HTTP Range (server answers 206), so a
///   killed app or dropped relay never restarts from zero.
/// - Integrity: the finished file's sha256 must match the server's
///   `/checksum` before anything is extracted; mismatch deletes the part
///   and retries fresh, up to [maxAttempts].
/// - Streaming extract (`extractFileToDisk`) instead of readAsBytes +
///   decodeBytes — the old path held the whole ~500MB zip plus the
///   decoded archive in RAM at once (OOM → "error even after downloading
///   all the files").
/// - Foreground keep-alive: unless an on-device conversion already holds
///   the foreground service, downloads run under their own lightweight
///   service (see `download_task_handler.dart`) so backgrounding the app
///   doesn't stall the transfer.
class DownloadManager {
  final ApiClient api;
  DownloadManager(this.api);

  static const int maxAttempts = 3;

  /// bookIds with a live download future. Cleared in `finally`.
  static final Map<String, Future<Directory>> _inFlight = {};

  /// One cancel token per live download. cancelDownload() cancels the
  /// in-flight HTTP stream; the `.part` file stays for resume.
  static final Map<String, CancelToken> _tokens = {};

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

  /// Streaming-extract [zipPath] into the book dir for [bookId]
  /// (replacing anything there), verifying the manifest. Shared by server
  /// downloads and Drive pulls — both produce identical layouts.
  /// Throws StateError when the zip has no manifest.json.
  Future<Directory> extractZipToBook(String zipPath, Directory target) async {
    if (await target.exists()) await target.delete(recursive: true);
    await target.create(recursive: true);
    // Streaming extract — entries are written as they are read, so peak
    // memory stays flat instead of spiking to ~2x the zip size.
    extractFileToDisk(zipPath, target.path);
    if (!await File('${target.path}/manifest.json').exists()) {
      await target.delete(recursive: true);
      throw StateError('Package at ${target.path} is missing manifest.json');
    }
    return target;
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
    void Function(DownloadProgress progress)? onProgress,
    /// Called with the verified zip BEFORE it is extracted and deleted —
    /// used for Drive backup (the only moment the full file exists).
    /// Errors are swallowed: backup must never fail a download.
    Future<void> Function(String bookId, String zipPath)? onZipReady,
  }) {
    // Single-flight: a second tap while downloading joins the same future
    // instead of starting a rival transfer into the same `.part` file.
    return _inFlight.putIfAbsent(
        bookId,
        () => _run(bookId, onProgress, onZipReady: onZipReady).whenComplete(() {
              _inFlight.remove(bookId);
              _tokens.remove(bookId);
            }));
  }

  /// True while [bookId] has a live download (UI tap guard).
  static bool isDownloading(String bookId) => _inFlight.containsKey(bookId);

  /// Pause a live download: aborts the HTTP stream but KEEPS the `.part`
  /// file, so tapping the book again resumes where it stopped. No-op when
  /// nothing is running. Never throws.
  static void pauseDownload(String bookId) {
    try {
      _tokens[bookId]?.cancel('paused by user');
    } catch (_) {}
  }

  /// Pause + delete the partial file (start fully over next time).
  Future<void> discardPartial(String bookId) async {
    pauseDownload(bookId);
    final books = await booksDir();
    await _deleteQuietly(File('${books.path}/$bookId.zip.part'));
    await _deleteQuietly(File('${books.path}/$bookId.zip'));
  }

  /// True when a partial download exists that a tap would resume.
  Future<bool> hasPartial(String bookId) async {
    final books = await booksDir();
    final part = File('${books.path}/$bookId.zip.part');
    return await part.exists() && await part.length() > 0;
  }

  Future<Directory> _run(
    String bookId,
    void Function(DownloadProgress progress)? onProgress, {
    Future<void> Function(String bookId, String zipPath)? onZipReady,
  }) async {
    final books = await booksDir();
    final zipPath = '${books.path}/$bookId.zip';
    final target = await bookDir(bookId);

    void emit(double fraction, int received, int? total, String phase) {
      onProgress?.call(DownloadProgress(
        fraction: fraction.clamp(0.0, 1.0),
        receivedBytes: received,
        totalBytes: total,
        phase: phase,
      ));
    }

    final keepAlive = await DownloadKeepAlive.acquire('book $bookId');
    try {
      final checksum = await api.getPackageChecksum(bookId);
      final total = checksum.sizeBytes;
      if (total <= 0) {
        throw const DownloadIntegrityException('Server reported an empty package');
      }

      var attempt = 0;
      while (true) {
        attempt++;
        final token = CancelToken();
        _tokens[bookId] = token;
        try {
          await api.downloadBook(
            bookId,
            zipPath,
            expectedTotal: total,
            cancelToken: token,
            onBytes: (received, _) {
              emit(received / total * 0.92, received, total, 'downloading');
              _updateNotification(bookId, received, total);
            },
          );
          emit(0.94, total, total, 'verifying');
          await _verifySha256(zipPath, checksum.sha256);
          break; // verified — fall through to extraction
        } on DownloadIntegrityException {
          // Stale/mismatched part file or a failed verification: discard
          // and retry from zero. Bounded — a persistently bad server file
          // must surface, not loop forever.
          await _deleteQuietly(File('$zipPath.part'));
          await _deleteQuietly(File(zipPath));
          if (attempt >= maxAttempts) rethrow;
        }
      }

      emit(0.96, total, total, 'extracting');
      if (onZipReady != null) {
        try {
          await onZipReady(bookId, zipPath);
        } catch (_) {}
      }
      await extractZipToBook(zipPath, target);
      await _deleteQuietly(File(zipPath));
      emit(1.0, total, total, 'done');
      return target;
    } finally {
      await keepAlive.release();
    }
  }

  /// Verifies the downloaded zip against the server's sha256, streaming
  /// the file (never loads a 500MB package into memory for hashing).
  Future<void> _verifySha256(String zipPath, String expected) async {
    final digest = await sha256.bind(File(zipPath).openRead()).first;
    if (digest.toString() != expected.toLowerCase()) {
      throw DownloadIntegrityException(
          'Checksum mismatch for $zipPath — expected $expected');
    }
  }

  void _updateNotification(String bookId, int received, int total) {
    final pct = (received / total * 100).toStringAsFixed(0);
    DownloadKeepAlive.updateProgress(
      'Downloading book… $pct%',
      '$bookId · ${DownloadProgress._mb(received)} / ${DownloadProgress._mb(total)} MB',
    );
  }

  Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> deleteBook(String bookId) async {
    final dir = await bookDir(bookId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
