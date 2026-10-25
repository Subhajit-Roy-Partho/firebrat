import 'dart:async';
import 'dart:io' show Platform;
import 'package:audio_service/audio_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'firebase_options.dart';
import 'services/audio_handler.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw behind the system bars on every Android version, as Android 15+
  // already enforces for apps targeting SDK 35: screens handle the insets
  // themselves (Scaffold / SafeArea), so all versions look the same.
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  // Firebase (auth + messaging). google-services.json is gitignored and
  // injected by CI; options here mirror it for project firebrat-8c597.
  // Best-effort: a misconfigured Firebase must never stop the app from
  // booting (reads work fully offline, AuthService degrades to signed-out).
  // Android-only: no iOS Firebase app is registered, and the native iOS SDK
  // throws an uncatchable ObjC exception (crash at launch) on a bad app id.
  if (Platform.isAndroid) {
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      await GoogleSignIn.instance.initialize();
    } catch (_) {}
  }
  // Push setup is best-effort: the reader works fully offline and must
  // never fail to start because notifications couldn't initialize.
  final prefs = await SharedPreferences.getInstance();
  unawaited(NotificationService.instance.initialize(
    enablePush: prefs.getString('conversion.mode') == 'cloud',
  ).catchError((Object _) {}));
  // On-device conversion background task + notification — must be
  // initialized before any call to BackgroundConversionRunner.start().
  BackgroundConversionRunner.initialize();
  audioHandler = await AudioService.init(
    builder: () => FirebratAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.firebrat.firebrat_app.channel.audio',
      androidNotificationChannelName: 'Firebrat playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  runApp(const ProviderScope(child: FirebratApp()));
}
