import 'dart:typed_data';

import '../cast/cast_voices.dart';
import 'piper_runtime.dart';
import 'speech_backend.dart';

/// Piper en_US libritts_r (904 speakers; [kPiperLibrittsVoices] is the curated
/// subset) as an expressive-narration engine. ~10x faster than real time on a
/// Pixel 9a CPU, so a full book converts in well under an hour of speech time.
class PiperBackend implements SpeechBackend {
  final String modelPath;
  final String configPath;

  /// Directory that holds `espeak-ng-data/`.
  final String espeakDir;
  final String provider;
  final int threads;
  PiperTts? _tts;
  PiperBackend({required this.modelPath, required this.configPath, required this.espeakDir, this.provider = 'cpu', this.threads = 4});

  @override
  String get engineName => 'piper_libritts';
  @override
  int get sampleRate => _tts?.sampleRate ?? 22050;
  @override
  List<VoiceProfile> get voices => kPiperLibrittsVoices;
  @override
  String get defaultNarratorVoice => 'libritts_$piperNarratorSpeaker';
  @override
  String get accelerationStatus => provider == 'xnnpack' ? 'XNNPACK (optimised CPU)' : 'CPU';

  /// Speaker 375 (male, ~114 Hz, the highest voiced-speech ratio of the male set): the default narrator.
  static const piperNarratorSpeaker = 375;

  @override
  Future<void> ensureReady({void Function(double progress, String status)? onProgress}) async {
    if (_tts != null) return;
    onProgress?.call(0.5, 'Loading the Piper voice model');
    _tts = await PiperTts.open(modelPath, configPath, espeakDir, provider: provider, threads: threads);
    onProgress?.call(1.0, 'Ready');
  }

  @override
  Future<Float32List> speak(String text, {required String voice, required double speed}) async {
    final tts = _tts ?? (throw StateError('PiperBackend.ensureReady() must succeed first'));
    return tts.synthesize(text, sid: piperSpeakerId(voice), speed: speed);
  }

  @override
  Future<void> dispose() async {
    await _tts?.dispose();
    _tts = null;
  }
}
