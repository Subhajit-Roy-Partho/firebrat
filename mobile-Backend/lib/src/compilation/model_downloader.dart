import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../models/model_tier.dart';

typedef DownloadProgressCallback = void Function(double? progress, String status);

/// Byte-level progress: cumulative bytes + authoritative total (null while
/// unknown). The caller maps it to UI; reporting bytes (not just a
/// fraction) is what lets the UI show stable "1.2 / 2.5 GB" numbers.
typedef DownloadBytesCallback = void Function(int receivedBytes, int? totalBytes);

/// Lightweight check for cached or newly downloaded weights before native load.
Future<bool> hasGgufHeader(File file) async {
  if (!await file.exists()) return false;
  final handle = await file.open();
  try {
    final bytes = await handle.read(24);
    return bytes.length == 24 &&
        bytes[0] == 0x47 && bytes[1] == 0x47 &&
        bytes[2] == 0x55 && bytes[3] == 0x46 &&
        (bytes[4] == 2 || bytes[4] == 3) &&
        bytes[5] == 0 && bytes[6] == 0 && bytes[7] == 0;
  } finally {
    await handle.close();
  }
}

/// Downloads a [DownloadableAsset] (an `OnDeviceLlmModel`'s GGUF weights, a TTS model file, ...) directly from Hugging
/// Face into [modelsDir], skipping the download if a file of roughly the
/// right size is already there. Uses `dio` (already a dependency, via
/// `cloud_compiler.dart`) rather than pulling in a second HTTP client.
///
/// Robustness (multi-GB weights over phone connections, and the app may be
/// backgrounded or killed mid-file):
/// - Resume: an interrupted transfer leaves `<file>.part`; the next run
///   continues from its length via HTTP Range (HF's CDN answers 206), so
///   closing the screen / losing signal never restarts from zero. A stale
///   or over-long part file is discarded and restarted, boundedly.
/// - Cancel: pass a [cancelToken] and call `cancel()` on it — the download
///   aborts promptly and the `.part` stays for a later resume.
/// - Throttling: progress callbacks fire at most ~5/sec with a monotonic
///   fraction, so UI listeners don't rebuild on every network chunk.
class ModelDownloader {
  final Dio _dio = Dio();

  Future<String> ensureDownloaded(
    DownloadableAsset model,
    String modelsDir, {
    DownloadProgressCallback? onProgress,
    DownloadBytesCallback? onBytes,
    CancelToken? cancelToken,
  }) async {
    final dir = Directory(modelsDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final path = '$modelsDir/${model.fileName}';
    final file = File(path);
    final isGguf = model.fileName.endsWith('.gguf');

    if (await file.exists()) {
      final existingSize = await file.length();
      // Within 2% of the expected size counts as "already downloaded" --
      // exact byte-for-byte comparison isn't reliable since most catalog
      // entries only have an approximate size (see model_catalog.dart),
      // and HF occasionally re-serves a quant with a marginally different
      // byte count across a re-upload.
      // The SHA-256 (when present) is checked on fresh downloads only: a file
      // already on disk may be a user-imported GGUF of slightly different size.
      if ((existingSize - model.approxSizeBytes).abs() < model.approxSizeBytes * 0.02 &&
          (!isGguf || await hasGgufHeader(file))) {
        onProgress?.call(1.0, 'already downloaded');
        onBytes?.call(existingSize, existingSize);
        return path;
      }
      // Present but wrong size and no .part resume candidate handling below
      // applies (this is the finished path, not the part path) — a corrupt
      // full file can never be resumed, only replaced.
      await file.delete();
    }

    // Resume from a previous partial transfer when sane.
    final tmpPath = '$path.part';
    final partFile = File(tmpPath);
    var have = await partFile.exists() ? await partFile.length() : 0;
    // Guard against a part file larger than any plausible full file
    // (server-side re-upload with different bytes, or garbage): restart.
    if (have > model.approxSizeBytes * 1.1) have = 0;

    DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    double lastFraction = -1;
    void emit(int received, int? total, String Function() status) {
      final now = DateTime.now();
      final fraction = total != null && total > 0
          ? (received / total).clamp(0.0, 1.0)
          : -1.0;
      onBytes?.call(received, total);
      if (fraction < 0) {
        onProgress?.call(null, status());
        return;
      }
      if (fraction < lastFraction) return; // never backward
      if (fraction < 1.0 &&
          fraction - lastFraction < 0.004 &&
          now.difference(lastEmit).inMilliseconds < 200) {
        return; // throttle: ~5 UI updates/sec max for sub-0.4% moves
      }
      lastFraction = fraction;
      lastEmit = now;
      onProgress?.call(fraction, status());
    }

    emit(have, null, () => have > 0
        ? 'resuming ${model.displayName}'
        : 'downloading ${model.displayName}');

    final headers = <String, dynamic>{};
    if (have > 0) headers['Range'] = 'bytes=$have-';
    final resp = await _dio.get<ResponseBody>(
      model.downloadUrl,
      cancelToken: cancelToken,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
        followRedirects: true,
        // Multi-GB download over a phone connection can legitimately take
        // a long time; callers run under a foreground service (see
        // `background/` + the app's download keep-alive), so there is no
        // UI-thread timeout pressure forcing this to be tight.
        receiveTimeout: null,
      ),
    );

    final status = resp.statusCode ?? 200;
    int? rangeTotal;
    if (have > 0) {
      if (status == 200) {
        // Server ignored Range — restart cleanly rather than appending a
        // full body onto a prefix (guaranteed corrupt GGUF, and llama.cpp
        // fails unpredictably, not cleanly, on truncated weights).
        have = 0;
        if (await partFile.exists()) await partFile.delete();
      } else if (status != 206) {
        throw DioException(requestOptions: resp.requestOptions,
            message: 'Unexpected status $status for range resume');
      } else {
        final contentRange = resp.headers.value('content-range') ?? '';
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(contentRange);
        rangeTotal = int.tryParse(range?.group(3) ?? '');
        if (range == null || int.tryParse(range.group(1)!) != have ||
            rangeTotal == null || int.tryParse(range.group(2)!) != rangeTotal - 1) {
          await partFile.delete();
          throw DioException(requestOptions: resp.requestOptions,
              message: 'Server resumed at $contentRange, expected from $have');
        }
      }
    }

    // Authoritative total: remaining slice + what we already hold (206),
    // or the full body (200). Falls back to the catalog approximation.
    int? total;
    try {
      final remaining = int.parse(resp.headers.value('content-length') ?? '');
      total = have + remaining;
    } catch (_) {
      total = null;
    }
    final responseTotal = rangeTotal ?? total;
    total = responseTotal;
    total ??= model.approxSizeBytes > 0 ? model.approxSizeBytes : null;

    final sink = partFile.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    var received = have;
    try {
      await for (final chunk in resp.data!.stream) {
        sink.add(chunk);
        received += (chunk as List<int>).length;
        emit(received, total, () => 'downloading ${model.displayName}');
      }
      await sink.flush();
      await sink.close();
      if (responseTotal != null && received != responseTotal) {
        throw const FormatException('The download ended early. Retry to resume it.');
      }
      if (isGguf && !await hasGgufHeader(partFile)) {
        await partFile.delete();
        throw FormatException('The download for ${model.displayName} is not a supported GGUF file. Retry the download.');
      }
      final expected = model.sha256;
      if (expected != null) {
        emit(received, total, () => 'verifying ${model.displayName}');
        final digest = await sha256.bind(partFile.openRead()).first;
        if (digest.toString() != expected.toLowerCase()) {
          await partFile.delete();
          throw StateError('Checksum mismatch for ${model.displayName}; the partial file was removed. Retry the download.');
        }
      }
      await partFile.rename(path);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      rethrow; // .part stays on disk for resume; cancel tokens land here too
    }
    emit(received, total, () => 'download complete');
    return path;
  }
}
