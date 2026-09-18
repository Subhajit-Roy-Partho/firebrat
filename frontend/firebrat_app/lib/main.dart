import 'package:audio_service/audio_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'app.dart';
import 'firebase_options.dart';
import 'services/audio_handler.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase (auth + messaging). google-services.json is gitignored and
  // injected by CI; options here mirror it for project firebrat-8c597.
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await GoogleSignIn.instance.initialize();
  // Push setup is best-effort: the reader works fully offline and must
  // never fail to start because notifications couldn't initialize.
  try {
    await NotificationService.instance.initialize();
  } catch (_) {}
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
