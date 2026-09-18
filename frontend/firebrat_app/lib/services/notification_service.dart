import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
    await _local.initialize(settings: settings);
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
  static Future<void> showLocal(String title, String body) async {
    try {
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
}
