import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart'
    show BackgroundConversionRunner;

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

/// Refcounted keep-alive for transfers (book zips AND model weights).
/// The old design gave each download a boolean "serviceMine" — with two
/// concurrent transfers the first finisher stopped the service out from
/// under the second. Now N holders share one service; it stops when the
/// last holder releases (or never started, when a conversion service
/// already keeps the process alive — which we must NOT disturb).
class DownloadKeepAlive {
  DownloadKeepAlive._();
  static const int _serviceId = 4202; // conversions use 4201, never collide
  static int _users = 0;
  static bool _ours = false;

  /// Returned handle; call [release] exactly once (e.g. in `finally`).
  static Future<KeepAliveHandle> acquire(String reason) async {
    try {
      await BackgroundConversionRunner.requestPermissions();
      if (await FlutterForegroundTask.isRunningService) return KeepAliveHandle._(false);
      if (_users == 0 || !_ours) {
        final res = await FlutterForegroundTask.startService(
          serviceId: _serviceId,
          notificationTitle: 'Downloading…',
          notificationText: reason,
          callback: downloadTaskCallback,
        );
        if (res is ServiceRequestFailure) return KeepAliveHandle._(false);
        _ours = true;
      }
      _users++;
      return KeepAliveHandle._(true);
    } catch (_) {
      // Best-effort: resume + checksum still make a killed transfer
      // recoverable, so never fail the transfer over the service.
      return KeepAliveHandle._(false);
    }
  }

  /// Throttled progress text for the shared notification. Callers pass
  /// their own already-throttled progress; this additionally drops
  /// duplicate percentages so the notification never jitters.
  static String? _lastText;
  static void updateProgress(String title, String text) {
    if (text == _lastText) return;
    _lastText = title + text;
    try {
      FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    } catch (_) {}
  }
}

/// Returned by [DownloadKeepAlive.acquire]; call [release] exactly once.
class KeepAliveHandle {
  final bool _held;
  KeepAliveHandle._(this._held);

  Future<void> release() async {
    if (!_held) return;
    DownloadKeepAlive._users = (DownloadKeepAlive._users - 1).clamp(0, 1 << 30);
    if (DownloadKeepAlive._users == 0 && DownloadKeepAlive._ours) {
      DownloadKeepAlive._ours = false;
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {}
    }
  }
}
