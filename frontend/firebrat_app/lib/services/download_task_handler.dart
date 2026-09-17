import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Entry point for the lightweight foreground service that keeps book
/// downloads alive when the app is backgrounded (Android Doze / app
/// standby would otherwise stall or kill a 400MB+ transfer, which is the
/// "error even after downloading all the files" failure mode).
///
/// This is deliberately separate from the on-device *conversion* service
/// (`mobile_backend_pipeline`'s `mobileConversionTaskCallback`, serviceId
/// 4201): downloads do their real work on the main isolate (Dio stream +
/// checksum + extract) and only need the service as a keep-alive shell
/// with a live notification. Progress text is pushed from the main
/// isolate via `FlutterForegroundTask.updateService`, same pattern as the
/// conversion runner.
///
/// Must be top-level (isolate entry point). Registered at
/// `FlutterForegroundTask.initCommunicationPort()` time in `main()` via
/// `BackgroundConversionRunner.initialize()` — no separate init needed.
@pragma('vm:entry-point')
void downloadTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_DownloadTaskHandler());
}

class _DownloadTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Not used — the main isolate pushes notification updates as the
    // download progresses (see DownloadManager).
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
