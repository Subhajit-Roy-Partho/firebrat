import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:async';
import 'download_manager.dart';

/// FCM background handler — must be top-level (separate isolate).
/// Shows data-message downloads/conversions as a local notification.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await NotificationService.showFromMessage(message);
}

/// Push notifications: conversion finished, new books on the server.
/// Foreground messages are re-displayed via flutter_local_notifications
/// (FCM doesn't show heads-up notifications itself while the app is open).
/// Data-only messages from the backend carry {title, body, channel}.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _channelId = 'com.firebrat.firebrat_app.channel.alerts';
  static const _channelName = 'Firebrat updates';
  static const _downloadChannelId = 'com.firebrat.firebrat_app.channel.downloads';
  static const _downloadChannelName = 'Book downloads';

  /// Min interval between progress-notification refreshes per book — the
  /// network layer emits hundreds per second; the shade only needs ~1Hz.
  static final Map<String, DateTime> _lastProgressShown = {};

  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> initialize() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      importance: Importance.high,
    );
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _local.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationAction,
    );
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    FirebaseMessaging.onMessage.listen(showFromMessage);
    // Server broadcasts ("a new book is on the shelf") go to this topic.
    try {
      await messaging.subscribeToTopic('new-books');
    } catch (_) {}
    _ready = true;
  }

  /// FCM registration token — the backend stores it per user to target
  /// "your conversion finished" messages (see `docs/FIREBASE.md`).
  Future<String?> fcmToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  static Future<void> showFromMessage(RemoteMessage message) async {    final n = message.notification;
    final title = n?.title ?? message.data['title'] ?? 'Firebrat';
    final body = n?.body ?? message.data['body'] ?? '';
    if (title.isEmpty && body.isEmpty) return;
    try {
      await instance._local.show(
        id: message.hashCode,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(_channelId, _channelName),
        ),
      );
    } catch (_) {}
  }

  /// Local (no-server) notification — used for job-done detection from the
  /// existing status poll, so it fires even when the server has no FCM
  /// credentials configured.
  static Future<void> showLocal(String title, String body) async {    try {
      await instance._local.show(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(_channelId, _channelName),
        ),
      );
    } catch (_) {}
  }

  bool get isReady => _ready;

  /// Stable notification id per book so progress updates replace the card
  /// instead of stacking.
  static int _downloadNotifId(String bookId) => bookId.hashCode & 0x7fffffff;

  /// Native download progress notification: determinate progress bar, MB
  /// counts, phase line, and Pause/Cancel buttons that act without
  /// opening the app. Throttled to ~1 refresh/sec per book (pass
  /// `force: true` for terminal states). Android notifications can't do
  /// animated backgrounds — this bar + actions is the platform maximum.
  static Future<void> showDownloadProgress({
    required String bookId,
    required String title,
    required double fraction,
    required int receivedBytes,
    required int? totalBytes,
    required String phase,
    bool force = false,
  }) async {
    try {
      final now = DateTime.now();
      final last = _lastProgressShown[bookId];
      if (!force &&
          last != null &&
          now.difference(last).inMilliseconds < 900 &&
          fraction < 1.0) {
        return;
      }
      _lastProgressShown[bookId] = now;
      final pct = (fraction.clamp(0.0, 1.0) * 100).round();
      String mb(int b) => (b / (1024 * 1024)).toStringAsFixed(0);
      final phaseLabel = switch (phase) {
        'verifying' => 'Verifying…',
        'extracting' => 'Extracting…',
        'done' => 'Done',
        _ => '${mb(receivedBytes)}${totalBytes != null && totalBytes > 0 ? ' / ${mb(totalBytes)} MB' : ' MB'} · $pct%',
      };
      final finished = phase == 'done';
      final working = phase == 'verifying' || phase == 'extracting';
      await instance._local.show(
        id: _downloadNotifId(bookId),
        title: title,
        body: phaseLabel,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _downloadChannelId,
            _downloadChannelName,
            importance: Importance.low,
            priority: Priority.low,
            ongoing: !finished,
            autoCancel: finished,
            onlyAlertOnce: true,
            playSound: false,
            enableVibration: false,
            showProgress: true,
            maxProgress: 100,
            progress: finished ? 100 : pct,
            indeterminate: working,
            actions: finished
                ? null
                : <AndroidNotificationAction>[
                    AndroidNotificationAction('pause_$bookId', 'Pause',
                        showsUserInterface: false, cancelNotification: false),
                    AndroidNotificationAction('cancel_$bookId', 'Cancel',
                        showsUserInterface: false, cancelNotification: false),
                  ],
          ),
        ),
        payload: 'download:$bookId',
      );
    } catch (_) {}
  }

  /// Removes the progress notification (done, paused, cancelled, failed).
  static Future<void> cancelDownloadNotification(String bookId) async {
    _lastProgressShown.remove(bookId);
    try {
      await instance._local.cancel(id: _downloadNotifId(bookId));
    } catch (_) {}
  }

  static void _onNotificationAction(NotificationResponse response) {
    final action = response.actionId;
    if (action == null) return;
    if (action.startsWith('pause_')) {
      final bookId = action.substring('pause_'.length);
      DownloadManager.pauseDownload(bookId);
      unawaited(cancelDownloadNotification(bookId));
    } else if (action.startsWith('cancel_')) {
      final bookId = action.substring('cancel_'.length);
      unawaited(DownloadManager.discardPartialStatic(bookId));
      unawaited(cancelDownloadNotification(bookId));
    }
  }
}
