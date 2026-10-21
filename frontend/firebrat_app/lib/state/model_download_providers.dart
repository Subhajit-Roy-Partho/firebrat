import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:path_provider/path_provider.dart';
import '../services/download_task_handler.dart';

/// Per-model weight download state. Lives in a provider (not widget
/// state) so closing the models screen, backgrounding the app, or a
/// dropped connection no longer kills the transfer: the Dio stream keeps
/// running under the shared foreground keep-alive, and an interrupted
/// `.part` file resumes via HTTP Range on the next start.
class ModelDownloadState {
  final double? fraction; // null = indeterminate / not started this session
  final int receivedBytes;
  final int? totalBytes;
  final String status;
  final bool downloading;
  final bool downloaded;

  const ModelDownloadState({
    required this.fraction,
    required this.receivedBytes,
    required this.totalBytes,
    required this.status,
    required this.downloading,
    required this.downloaded,
  });

  String get label {
    String mb(int b) => (b / 1073741824).toStringAsFixed(1);
    if (totalBytes == null || totalBytes == 0) return status;
    final pct = fraction == null
        ? ''
        : ' · ${(fraction!.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%';
    return '${mb(receivedBytes)} / ${mb(totalBytes!)}$pct GB';
  }
}

/// Single-flight model downloads keyed by catalog id. One entry per model
/// ever started this session; concurrent starts share the same future.
class ModelDownloadNotifier extends Notifier<Map<String, ModelDownloadState>> {
  final Map<String, Future<String>> _inFlight = {};
  final Map<String, CancelToken> _tokens = {};

  @override
  Map<String, ModelDownloadState> build() => {};

  static Future<String> modelsDir() async =>
      '${(await getApplicationSupportDirectory()).path}/firebrat_models';

  void _set(String id, ModelDownloadState s) {
    state = {...state, id: s};
  }

  ModelDownloadState _current(String id, {bool downloading = false}) {
    final prev = state[id];
    return ModelDownloadState(
      fraction: prev?.fraction,
      receivedBytes: prev?.receivedBytes ?? 0,
      totalBytes: prev?.totalBytes,
      status: prev?.status ?? 'starting…',
      downloading: downloading,
      downloaded: prev?.downloaded ?? false,
    );
  }

  Future<String> startDownload(OnDeviceLlmModel model) {
    return _inFlight.putIfAbsent(model.id, () => _run(model).whenComplete(() {
          _inFlight.remove(model.id);
          _tokens.remove(model.id);
        }));
  }

  /// Pause = cancel the stream, keep the `.part` file. Tapping download
  /// again resumes from it ( Range). Never deletes progress.
  void pauseDownload(String modelId) {
    _tokens[modelId]?.cancel('paused by user');
  }

  Future<String> _run(OnDeviceLlmModel model) async {
    final dir = await modelsDir();
    final token = CancelToken();
    _tokens[model.id] = token;
    final keepAlive = await DownloadKeepAlive.acquire('model ${model.id}');
    DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    double lastFraction = -1;
    try {
      final path = await ModelDownloader().ensureDownloaded(
        model,
        dir,
        cancelToken: token,
        onBytes: (received, total) {
          final now = DateTime.now();
          final f = total != null && total > 0
              ? (received / total).clamp(0.0, 1.0)
              : -1.0;
          // Throttle + monotonic, same contract as book downloads.
          if (f >= 0 && f < lastFraction) return;
          if (f >= 0 &&
              f < 1.0 &&
              f - lastFraction < 0.004 &&
              now.difference(lastEmit).inMilliseconds < 200) {
            return;
          }
          lastFraction = f;
          lastEmit = now;
          _set(model.id, ModelDownloadState(
            fraction: f < 0 ? null : f,
            receivedBytes: received,
            totalBytes: total,
            status: 'downloading ${model.displayName}',
            downloading: true,
            downloaded: false,
          ));
          if (f >= 0) {
            DownloadKeepAlive.updateProgress(
              'Downloading model… ${(f * 100).toStringAsFixed(0)}%',
              '${model.id} · ${_gb(received)} / ${total != null ? _gb(total) : "?"} GB',
            );
          }
        },
        onProgress: (p, status) {
          final prev = state[model.id];
          _set(model.id, ModelDownloadState(
            fraction: p,
            receivedBytes: prev?.receivedBytes ?? 0,
            totalBytes: prev?.totalBytes,
            status: status,
            downloading: p == null || p < 1.0,
            downloaded: p != null && p >= 1.0,
          ));
        },
      );
      _set(model.id, ModelDownloadState(
        fraction: 1.0,
        receivedBytes: state[model.id]?.receivedBytes ?? 0,
        totalBytes: state[model.id]?.totalBytes,
        status: 'downloaded',
        downloading: false,
        downloaded: true,
      ));
      return path;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        // Paused by the user (or the OS): keep .part + last progress so
        // the next start resumes instead of restarting. Not an error.
        final prev = _current(model.id);
        _set(model.id, ModelDownloadState(
          fraction: prev.fraction,
          receivedBytes: prev.receivedBytes,
          totalBytes: prev.totalBytes,
          status: 'paused — tap download to resume',
          downloading: false,
          downloaded: false,
        ));
      }
      rethrow;
    } finally {
      await keepAlive.release();
    }
  }

  static String _gb(int bytes) => (bytes / 1073741824).toStringAsFixed(1);
}

final modelDownloadProvider = NotifierProvider<ModelDownloadNotifier,
    Map<String, ModelDownloadState>>(ModelDownloadNotifier.new);
