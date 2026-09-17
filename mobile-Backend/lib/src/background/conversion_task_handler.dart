import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import '../models/conversion_settings.dart';
import '../pipeline/mobile_conversion_pipeline.dart';
import 'conversion_request.dart';

/// Runs inside `flutter_foreground_task`'s dedicated background isolate —
/// this is what makes an on-device conversion survive the app being
/// backgrounded (Android keeps the process alive via a real foreground
/// service + persistent notification; see package README for iOS's much
/// weaker equivalent). The callback below must be a top-level or static
/// function per the plugin's contract (it's the isolate entry point).
///
/// **Unverified**: written directly against the documented
/// `flutter_foreground_task` API — this sandbox has no device/emulator
/// (`adb` doesn't run here) to actually confirm the service starts, the
/// notification updates live, or data crosses the isolate boundary as
/// expected. Treat as reviewed, not proven — see package README.
@pragma('vm:entry-point')
void mobileConversionTaskCallback() {
  FlutterForegroundTask.setTaskHandler(MobileConversionTaskHandler());
}

class MobileConversionTaskHandler extends TaskHandler {
  bool _started = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    if (_started) return; // guards against onStart firing more than once (e.g. restartService)
    _started = true;

    final stateDir = (await getApplicationSupportDirectory()).path;
    final request = await ConversionRequest.readFrom(stateDir);
    if (request == null) {
      FlutterForegroundTask.sendDataToMain({'error': 'no pending conversion request found'});
      FlutterForegroundTask.stopService();
      return;
    }

    final pipeline = MobileConversionPipeline(
      settings: OnDeviceModeSettings(
        llmBaseUrl: request.llmBaseUrl,
        llmApiKey: request.llmApiKey,
        llmModel: request.llmModel,
        onDeviceLlmModelId: request.onDeviceLlmModelId,
        onDeviceGpuLayers: request.onDeviceGpuLayers,
        voiceEngine: request.voiceEngine == 'kokoroOnnx'
            ? OnDeviceVoiceEngine.kokoroOnnx
            : OnDeviceVoiceEngine.stockTts,
        kokoroVoice: request.kokoroVoice,
      ),
      onProgress: (p) {
        FlutterForegroundTask.sendDataToMain({
          'stage': p.stage,
          'detail': p.detail,
          'fraction': p.fraction,
        });
        FlutterForegroundTask.updateService(
          notificationTitle: 'Converting "${request.titleOverride ?? request.pdfPath.split('/').last}"',
          notificationText: p.detail.isEmpty ? p.stage : '${p.stage} — ${p.detail}',
        );
      },
    );

    try {
      final bookId = await pipeline.convert(
        pdfPath: request.pdfPath,
        booksRootDir: request.booksRootDir,
        modelsDir: request.modelsDir,
        titleOverride: request.titleOverride,
      );
      await ConversionRequest.clear(stateDir);
      FlutterForegroundTask.sendDataToMain({'done': true, 'bookId': bookId});
    } catch (e) {
      await ConversionRequest.clear(stateDir);
      FlutterForegroundTask.sendDataToMain({'error': e.toString()});
    } finally {
      FlutterForegroundTask.stopService();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Not used — progress is pushed from the pipeline's onProgress callback
    // above as it happens, rather than polled on a fixed interval.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}

  @override
  void onNotificationDismissed() {}
}
