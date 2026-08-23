import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'app.dart';
import 'services/audio_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
