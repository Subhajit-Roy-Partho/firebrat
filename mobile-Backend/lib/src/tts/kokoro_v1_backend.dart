// ignore_for_file: implementation_imports
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_kokoro_tts/src/phonemizer.dart';
import 'package:flutter_kokoro_tts/src/text_cleaner.dart';
import 'package:flutter_kokoro_tts/src/text_preprocessor.dart';

import '../cast/cast_voices.dart';
import '../models/model_tier.dart';
import 'accelerator.dart';
import 'ort_bridge.dart';
import 'speech_backend.dart';

/// Kokoro-82M v1.0 (28 English voices) on ONNX Runtime through [OrtBridgeSession]
/// (typed tensors, no boxed lists: measurably faster than the generic plugin).
///
/// Safety net: fp16 graphs can overflow to NaN on some inputs (seen on a
/// laptop and once on the phone). Every chunk is checked; a NaN/Inf or a
/// silent result is re-run once on [fallbackModelPath] (fp32/int8, CPU).
class KokoroV1Backend implements SpeechBackend {
  final String modelPath;
  final String? fallbackModelPath;
  final String voicesDir;

  /// Directory that holds `espeak-ng-data/`.
  final String espeakDir;
  final int threads;
  final AcceleratorPreference accelerator;
  final bool modelIsFp16;
  final Set<String> installedVoices;
  KokoroV1Backend({
    required this.modelPath,
    required this.voicesDir,
    required this.espeakDir,
    this.fallbackModelPath,
    this.threads = 4,
    this.accelerator = AcceleratorPreference.auto,
    this.modelIsFp16 = false,
    this.installedVoices = const {},
  });

  AcceleratedSession<OrtBridgeSession>? _accel;
  OrtBridgeSession? _fallback;
  final Phonemizer _phonemizer = Phonemizer();
  final TextCleaner _cleaner = TextCleaner();
  final TextPreprocessor _pre = TextPreprocessor();
  final Map<String, Float32List> _styles = {};
  bool _ready = false;
  int fallbackChunks = 0;
  static const _maxTokens = 500;

  @override
  String get engineName => 'kokoro_v1';
  @override
  int get sampleRate => 24000;
  @override
  List<VoiceProfile> get voices =>
      [for (final v in kKokoroV1Voices) if (installedVoices.isEmpty || installedVoices.contains(v.name)) v];
  @override
  String get defaultNarratorVoice => 'af_heart';
  @override
  String get accelerationStatus =>
      '${_accel?.statusLabel ?? 'Not started'}${fallbackChunks > 0 ? '; $fallbackChunks chunk(s) re-run on the safe model' : ''}';

  /// Plan for the Kokoro v1 graphs, from measurements on a Pixel 9a (Tensor G4):
  /// NNAPI cannot run them (int8: session creation fails; fp16: 0 nodes accepted;
  /// fp32: ~2% of the compute) and the TPU refuses the model, so NNAPI is only
  /// tried when the user asks for GPU/NPU explicitly. XNNPACK has fp16 kernels
  /// and is the fastest CPU path for the fp16 graph.
  static List<AccelBackend> planFor({required AcceleratorPreference preference, required bool fp16, required bool nnapiUsable}) {
    switch (preference) {
      case AcceleratorPreference.cpu:
        return const [AccelBackend.cpu];
      case AcceleratorPreference.auto:
        return fp16 ? const [AccelBackend.xnnpack, AccelBackend.cpu] : const [AccelBackend.cpu];
      case AcceleratorPreference.gpuNpu:
        return [if (nnapiUsable) AccelBackend.nnapi, if (fp16) AccelBackend.xnnpack, AccelBackend.cpu];
    }
  }

  @override
  Future<void> ensureReady({void Function(double progress, String status)? onProgress}) async {
    if (_ready) return;
    onProgress?.call(0.1, 'Starting the phonemizer');
    _phonemizer.initialize(dataPath: espeakDir);
    final plan = planFor(preference: accelerator, fp16: modelIsFp16, nnapiUsable: Platform.isAndroid);
    onProgress?.call(0.4, 'Loading the Kokoro voice model (${plan.first.label})');
    _accel = AcceleratedSession<OrtBridgeSession>(
      plan: plan,
      create: (b) => OrtBridgeSession.create(modelPath,
          threads: threads,
          provider: switch (b) {
            AccelBackend.nnapi => 'nnapi',
            AccelBackend.xnnpack => 'xnnpack',
            _ => 'cpu',
          }),
      close: (s) => s.close(),
    );
    await _accel!.open();
    _ready = true;
    onProgress?.call(1.0, 'Ready');
  }

  Future<Float32List> _style(String voice) async {
    final cached = _styles[voice];
    if (cached != null) return cached;
    final file = File('$voicesDir/$voice.bin');
    if (!await file.exists()) throw StateError('Voice "$voice" is not downloaded.');
    final style = (await file.readAsBytes()).buffer.asFloat32List();
    return _styles[voice] = style;
  }

  @override
  Future<Float32List> speak(String text, {required String voice, required double speed}) async {
    if (!_ready) throw StateError('KokoroV1Backend.ensureReady() must succeed first');
    final parts = <Float32List>[];
    for (final chunk in splitForKokoro(text)) {
      final audio = await _chunk(chunk, voice, speed);
      if (audio.isNotEmpty) parts.add(audio);
    }
    final out = Float32List(parts.fold<int>(0, (a, p) => a + p.length));
    var o = 0;
    for (final p in parts) {
      out.setRange(o, o + p.length, p);
      o += p.length;
    }
    return out;
  }

  Future<Float32List> _chunk(String chunk, String voice, double speed) async {
    final clean = _pre.process(chunk);
    final phonemes = _phonemizer.phonemize(addTrailingPunctuation(clean.trim()));
    final ids = _cleaner.encodeAndWrap(phonemes);
    if (ids.length <= 2) return Float32List(0);
    if (ids.length > _maxTokens) {
      final mid = chunk.length ~/ 2;
      var cut = chunk.indexOf(RegExp(r'[.!?,;:\s]'), mid);
      if (cut < 0 || cut == chunk.length - 1) cut = mid;
      return Float32List.fromList([
        ...await _chunk(chunk.substring(0, cut), voice, speed),
        ...await _chunk(chunk.substring(cut), voice, speed),
      ]);
    }
    final styleAll = await _style(voice);
    final rows = styleAll.length ~/ 256;
    final row = ids.length.clamp(0, rows - 1);
    final style = Float32List.sublistView(styleAll, row * 256, (row + 1) * 256);
    final inputs = <String, (List<int>, Object)>{
      'input_ids': ([1, ids.length], Int64List.fromList(ids)),
      'style': ([1, 256], Float32List.fromList(style)),
      'speed': ([1], Float32List.fromList([speed * 0.8])), // 0.8 = Kokoro's natural-pace prior used by the stock path
    };
    var audio = (await _accel!.run((s) => s.run(inputs))).outputs.first.floats;
    if (!_healthy(audio) && fallbackModelPath != null) {
      fallbackChunks++;
      _fallback ??= await OrtBridgeSession.create(fallbackModelPath!, threads: threads);
      audio = (await _fallback!.run(inputs)).outputs.first.floats;
    }
    if (!_healthy(audio)) throw StateError('Kokoro produced invalid audio for "${chunk.length > 40 ? chunk.substring(0, 40) : chunk}"');
    // Kokoro leaves ~5000 samples of trailing silence per chunk.
    return audio.length > 6000 ? Float32List.sublistView(audio, 0, audio.length - 5000) : audio;
  }

  static bool _healthy(Float32List a) {
    if (a.isEmpty) return false;
    var energy = 0.0;
    for (var i = 0; i < a.length; i += 7) {
      final v = a[i];
      if (v.isNaN || v.isInfinite) return false;
      energy += v * v;
    }
    return energy / (a.length / 7) > 1e-7;
  }

  @override
  Future<void> dispose() async {
    await _accel?.close();
    await _fallback?.close();
    _fallback = null;
    _accel = null;
    _phonemizer.dispose();
    _ready = false;
  }
}

/// Sentence-sized chunks (<= [maxLen] chars) for Kokoro; punctuation is kept.
List<String> splitForKokoro(String text, {int maxLen = 200}) {
  final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
  final chunks = <String>[];
  final buf = StringBuffer();
  for (final s in sentences) {
    final t = s.trim();
    if (t.isEmpty) continue;
    if (buf.length + t.length + 1 > maxLen && buf.isNotEmpty) {
      chunks.add(addTrailingPunctuation(buf.toString().trim()));
      buf.clear();
    }
    if (buf.isNotEmpty) buf.write(' ');
    buf.write(t);
  }
  if (buf.isNotEmpty) chunks.add(addTrailingPunctuation(buf.toString().trim()));
  return chunks.isEmpty ? [addTrailingPunctuation(text.trim())] : chunks;
}

String addTrailingPunctuation(String t) {
  t = t.trim();
  if (t.isEmpty) return t;
  return '.!?,;:'.contains(t[t.length - 1]) ? t : '$t,';
}
