import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:path_provider/path_provider.dart';
import '../services/app_network_gate.dart';
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

  /// Non-null while the "Download over" setting is holding the transfer
  /// (e.g. "Waiting for Wi-Fi"). Partial progress is kept and it resumes by itself.
  final String? waitingLabel;

  const ModelDownloadState({
    this.waitingLabel,
    required this.fraction,
    required this.receivedBytes,
    required this.totalBytes,
    required this.status,
    required this.downloading,
    required this.downloaded,
  });

  String get label {
    if (waitingLabel != null) return waitingLabel!;
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
      waitingLabel: prev?.waitingLabel,
    );
  }

  void _setWaiting(String id, String? label) {
    final prev = _current(id, downloading: true);
    _set(id, ModelDownloadState(
      fraction: prev.fraction, receivedBytes: prev.receivedBytes, totalBytes: prev.totalBytes,
      status: label ?? prev.status, downloading: true, downloaded: false, waitingLabel: label));
  }

  Future<String> startDownload(OnDeviceLlmModel model) {
    return _inFlight.putIfAbsent(model.id, () => _run(model).whenComplete(() {
          _inFlight.remove(model.id);
          _tokens.remove(model.id);
        }));
  }

  /// Imports and downloads cannot replace the same model slot together.
  Future<String> importModel(OnDeviceLlmModel model, {required String path, required String pickedName}) {
    if (_inFlight.containsKey(model.id)) throw StateError('Pause the model transfer before importing.');
    final future = _runImport(model, path, pickedName).whenComplete(() {
      _inFlight.remove(model.id); _tokens.remove(model.id);
    });
    _inFlight[model.id] = future; return future;
  }

  Future<String> _runImport(OnDeviceLlmModel model, String path, String pickedName) async {
    final token = CancelToken(); _tokens[model.id] = token;
    _set(model.id, const ModelDownloadState(fraction: null, receivedBytes: 0,
        totalBytes: null, status: 'validating local GGUF', downloading: true, downloaded: false));
    final keepAlive = await DownloadKeepAlive.acquire('import model ${model.id}');
    var last = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final result = await ModelImporter().importFile(sourcePath: path, pickedName: pickedName,
          model: model, modelsDir: '${await modelsDir()}/llm', cancelToken: token,
          onBytes: (received, total) {
            final now = DateTime.now();
            if (received != total && now.difference(last).inMilliseconds < 250) return;
            last = now;
            _set(model.id, ModelDownloadState(fraction: received / total,
                receivedBytes: received, totalBytes: total, status: 'importing local GGUF',
                downloading: true, downloaded: false));
          });
      _set(model.id, ModelDownloadState(fraction: 1, receivedBytes: model.approxSizeBytes,
          totalBytes: model.approxSizeBytes, status: 'imported', downloading: false, downloaded: true));
      return result;
    } catch (_) {
      _set(model.id, const ModelDownloadState(fraction: null, receivedBytes: 0,
          totalBytes: null, status: 'import not completed', downloading: false, downloaded: false));
      rethrow;
    } finally { await keepAlive.release(); }
  }

  /// Pause = cancel the stream, keep the `.part` file. Tapping download
  /// again resumes from it ( Range). Never deletes progress.
  void pauseDownload(String modelId) {
    _tokens[modelId]?.cancel('paused by user');
  }

  Future<String> _run(OnDeviceLlmModel model) async {
    final dir = '${await modelsDir()}/llm';
    final token = CancelToken();
    _tokens[model.id] = token;
    final keepAlive = await DownloadKeepAlive.acquire('model ${model.id}');
    DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    double lastFraction = -1;
    try {
      // The "Download over" rule: wait (keeping the .part file) when the network
      // is not allowed, pause if it stops being allowed, resume automatically.
      final path = await AppNetworkGate.instance.runGated<String>(
        model.approxSizeBytes,
        (gateToken) => ModelDownloader().ensureDownloaded(
        model,
        dir,
        cancelToken: gateToken,
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
            waitingLabel: null,
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
      ),
        userCancel: token,
        onWaiting: (label) => _setWaiting(model.id, label),
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
