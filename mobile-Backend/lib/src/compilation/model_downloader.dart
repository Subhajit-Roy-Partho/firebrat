import 'dart:io';
import 'package:dio/dio.dart';
import 'model_catalog.dart';

typedef DownloadProgressCallback = void Function(double? progress, String status);

/// Downloads an [OnDeviceLlmModel]'s GGUF weights directly from Hugging
/// Face into [modelsDir], skipping the download if a file of roughly the
/// right size is already there. Uses `dio` (already a dependency, via
/// `cloud_compiler.dart`) rather than pulling in a second HTTP client.
class ModelDownloader {
  final Dio _dio = Dio();

  Future<String> ensureDownloaded(
    OnDeviceLlmModel model,
    String modelsDir, {
    DownloadProgressCallback? onProgress,
  }) async {
    final dir = Directory(modelsDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final path = '$modelsDir/${model.fileName}';
    final file = File(path);

    if (await file.exists()) {
      final existingSize = await file.length();
      // Within 2% of the expected size counts as "already downloaded" --
      // exact byte-for-byte comparison isn't reliable since most catalog
      // entries only have an approximate size (see model_catalog.dart),
      // and HF occasionally re-serves a quant with a marginally different
      // byte count across a re-upload.
      if ((existingSize - model.approxSizeBytes).abs() < model.approxSizeBytes * 0.02) {
        onProgress?.call(1.0, 'already downloaded');
        return path;
      }
      // Partial/mismatched file from an interrupted previous download --
      // remove it and redownload cleanly. llama.cpp fails unpredictably,
      // not cleanly, on a truncated GGUF, so this isn't worth risking.
      await file.delete();
    }

    final tmpPath = '$path.part';
    onProgress?.call(0.0, 'downloading ${model.displayName}');
    await _dio.download(
      model.downloadUrl,
      tmpPath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total, 'downloading ${model.displayName}');
      },
      options: Options(
        followRedirects: true,
        // Multi-GB download over a phone connection can legitimately take
        // a long time; this pipeline already runs inside a foreground
        // service (see `background/`), so there's no UI-thread timeout
        // pressure forcing this to be tight.
        receiveTimeout: const Duration(minutes: 45),
      ),
    );
    await File(tmpPath).rename(path);
    onProgress?.call(1.0, 'download complete');
    return path;
  }
}
