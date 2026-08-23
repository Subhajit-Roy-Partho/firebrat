import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'conversion_request.dart';
import 'conversion_task_handler.dart';

/// App-facing API for running an on-device conversion as a real background
/// task with a persistent notification — call [initialize] once at app
/// startup (before anything else in this class), then [start] per
/// conversion. See package README "Known limitations" for the Android/iOS
/// difference: Android gets a genuine foreground service (survives the app
/// being backgrounded indefinitely); iOS's equivalent is much weaker by OS
/// design (~30s bursts every ~15min, and the task dies immediately if the
/// user force-closes the app from the app switcher) — see
/// `flutter_foreground_task`'s own README for the exact iOS constraints,
/// not something this package can work around.
///
/// **Unverified end to end** — see `conversion_task_handler.dart`'s doc
/// comment.
class BackgroundConversionRunner {
  BackgroundConversionRunner._();

  static bool _initialized = false;

  /// Call once, early in `main()`, before `runApp`.
  static void initialize() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'firebrat_on_device_conversion',
        channelName: 'On-device book conversion',
        channelDescription: 'Shows progress while a book is being converted on this device.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Requests the OS permissions the service needs (notification
  /// permission on Android 13+/iOS). Call before [start]; safe to call
  /// every time, it no-ops once granted.
  static Future<void> requestPermissions() async {
    final permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  /// Starts converting [request] as a background task, showing a
  /// persistent "Converting…" notification that updates live with the
  /// pipeline's stage/detail. Call [addProgressListener] first if the
  /// caller wants to observe progress (the notification updates
  /// regardless of whether anything is listening).
  static Future<ServiceRequestResult> start(ConversionRequest request) async {
    final stateDir = (await getApplicationSupportDirectory()).path;
    await request.writeTo(stateDir);

    if (await FlutterForegroundTask.isRunningService) {
      return FlutterForegroundTask.restartService();
    }
    return FlutterForegroundTask.startService(
      serviceId: 4201, // arbitrary, fixed — this app only ever runs one conversion service at a time
      notificationTitle: 'Converting a book…',
      notificationText: 'Starting…',
      callback: mobileConversionTaskCallback,
    );
  }

  /// Data pushed from the task handler: `{stage, detail, fraction}` while
  /// running, `{done: true, bookId}` on success, or `{error}` on failure.
  static void addProgressListener(void Function(Object data) callback) {
    FlutterForegroundTask.addTaskDataCallback(callback);
  }

  static void removeProgressListener(void Function(Object data) callback) {
    FlutterForegroundTask.removeTaskDataCallback(callback);
  }

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  static Future<ServiceRequestResult> stop() => FlutterForegroundTask.stopService();
}
