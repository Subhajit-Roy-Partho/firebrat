import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../compilation/model_downloader.dart';
import '../models/tts_model_catalog.dart';

/// Extra Kokoro files beyond what the pinned `flutter_kokoro_tts` downloads
/// (its int8 model and six voices): the fp16/fp32 model variants and the
/// five extra voices. Same directory layout, so the stock files are untouched.
/// Downloads resume (HTTP Range), verify SHA-256 and accept a [CancelToken]
/// so the network gate can pause them.
class KokoroAssets {
  static Future<String> baseDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}/kokoro/Kokoro-82M-ONNX';
  }

  static Future<String> modelPath(OnDeviceTtsModel m) async =>
      '${await baseDir()}/${m.fileName}';

  /// True when the model file for [m] is present with the exact size.
  static Future<bool> isModelPresent(OnDeviceTtsModel m) async {
    final f = File(await modelPath(m));
    return await f.exists() && await f.length() == m.approxSizeBytes;
  }

  static Future<bool> areExtraVoicesPresent() async {
    final dir = '${await baseDir()}/voices';
    for (final v in kKokoroExtraVoices) {
      final f = File('$dir/${v.fileName}');
      if (!await f.exists() || await f.length() != v.approxSizeBytes) {
        return false;
      }
    }
    return true;
  }

  /// Names of voices usable right now (bundled six are assumed present once
  /// the base download is ready; extras are checked on disk).
  static Future<Set<String>> availableExtraVoiceNames() async {
    final dir = '${await baseDir()}/voices';
    final out = <String>{};
    for (final v in kKokoroExtraVoices) {
      final f = File('$dir/${v.fileName}');
      if (await f.exists() && await f.length() == v.approxSizeBytes) {
        out.add(v.name);
      }
    }
    return out;
  }

  static Future<void> downloadModel(
    OnDeviceTtsModel m, {
    DownloadBytesCallback? onBytes,
    DownloadProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (m.bundledWithBase) return;
    await ModelDownloader().ensureDownloaded(
      m,
      await baseDir(),
      onBytes: onBytes,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  static Future<void> downloadExtraVoices({
    DownloadProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = '${await baseDir()}/voices';
    var i = 0;
    final all = kKokoroExtraVoices;
    for (final v in all) {
      await ModelDownloader().ensureDownloaded(
        v,
        dir,
        cancelToken: cancelToken,
        onProgress: (p, s) =>
            onProgress?.call(((i + (p ?? 0)) / all.length), 'voice ${v.name}'),
      );
      i++;
    }
    onProgress?.call(1.0, 'voices ready');
  }

  /// Total bytes still to fetch for [m] plus the extra voices if [withExtraVoices].
  static Future<int> missingBytes(
    OnDeviceTtsModel m, {
    bool withExtraVoices = false,
  }) async {
    var total = 0;
    if (!m.bundledWithBase && !await isModelPresent(m)) {
      total += m.approxSizeBytes;
    }
    if (withExtraVoices && !await areExtraVoicesPresent()) {
      total += kKokoroExtraVoices.length * 524288;
    }
    return total;
  }
}
