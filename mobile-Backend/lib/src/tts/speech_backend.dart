/// One neural speech engine behind the expressive narrator: Kokoro v1.0
/// (natural, ~0.6-0.9x real time on a Pixel 9a) or Piper multi-speaker VITS
/// (many voices, ~0.1x). The narrator only needs "say this text with that
/// voice at this speed"; engines differ in voices, speed and phonemizer.
library;

import 'dart:typed_data';

import '../cast/cast_voices.dart';

abstract class SpeechBackend {
  /// `kokoro_v1` or `piper_libritts`; written to the manifest `cast.engine`.
  String get engineName;
  int get sampleRate;

  /// Voices the casting may use (already limited to what is installed).
  List<VoiceProfile> get voices;
  String get defaultNarratorVoice;

  /// What the speech model really runs on, for the "Running on" status.
  String get accelerationStatus;

  Future<void> ensureReady({void Function(double progress, String status)? onProgress});

  /// Mono float samples in [-1, 1] at [sampleRate]. [speed] 1.0 = natural.
  Future<Float32List> speak(String text, {required String voice, required double speed});

  Future<void> dispose();
}
