// ignore_for_file: implementation_imports
/// Piper (VITS) voices on plain ONNX Runtime: no extra native library.
///
/// Piper models are ordinary ONNX graphs (`input`, `input_lengths`, `scales`,
/// optional `sid`) fed with espeak-ng IPA phoneme ids. The phonemizer is the
/// espeak-ng FFI that `flutter_kokoro_tts` already bundles (same `en-us`
/// voice Piper's en_US models were trained with), and the session runs through
/// [OrtBridgeSession], so the whole engine is ~150 lines and adds no
/// dependency. A multi-speaker model (libritts_r: 904 voices) gives the
/// casting pass far more distinct voices than Kokoro, at roughly 8x the speed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_kokoro_tts/src/phonemizer.dart';

import 'ort_bridge.dart';

class PiperVoiceConfig {
  final int sampleRate;
  final double noiseScale;
  final double lengthScale;
  final double noiseW;
  final int numSpeakers;
  final Map<String, List<int>> idMap;
  final String espeakVoice;
  const PiperVoiceConfig({
    required this.sampleRate,
    required this.noiseScale,
    required this.lengthScale,
    required this.noiseW,
    required this.numSpeakers,
    required this.idMap,
    required this.espeakVoice,
  });

  factory PiperVoiceConfig.fromJson(Map<String, dynamic> j) {
    final inf = (j['inference'] as Map?) ?? const {};
    return PiperVoiceConfig(
      sampleRate: ((j['audio'] as Map)['sample_rate'] as num).toInt(),
      noiseScale: (inf['noise_scale'] as num?)?.toDouble() ?? 0.667,
      lengthScale: (inf['length_scale'] as num?)?.toDouble() ?? 1.0,
      noiseW: (inf['noise_w'] as num?)?.toDouble() ?? 0.8,
      numSpeakers: (j['num_speakers'] as num?)?.toInt() ?? 1,
      idMap: {
        for (final e in (j['phoneme_id_map'] as Map).entries) e.key as String: [for (final i in e.value as List) (i as num).toInt()]
      },
      espeakVoice: ((j['espeak'] as Map?)?['voice'] ?? 'en-us').toString(),
    );
  }

  static Future<PiperVoiceConfig> load(String path) async =>
      PiperVoiceConfig.fromJson(jsonDecode(await File(path).readAsString()) as Map<String, dynamic>);
}

/// `^` + each known phoneme followed by the pad id + `$` (Piper's encoding).
/// Phonemes missing from the model's map are skipped, as Piper does.
List<int> piperPhonemeIds(String phonemes, PiperVoiceConfig cfg) {
  final bos = cfg.idMap['^'] ?? const [1];
  final eos = cfg.idMap[r'$'] ?? const [2];
  final pad = cfg.idMap['_'] ?? const [0];
  final ids = <int>[...bos];
  for (final rune in phonemes.runes) {
    final m = cfg.idMap[String.fromCharCode(rune)];
    if (m == null) continue;
    ids
      ..addAll(m)
      ..addAll(pad);
  }
  ids.addAll(eos);
  return ids;
}

/// Splits [text] into sentence-sized pieces for synthesis (keeps punctuation).
List<String> piperSentences(String text, {int maxLen = 220}) {
  final sentences = text.split(RegExp(r'(?<=[.!?…])\s+'));
  final out = <String>[];
  final buf = StringBuffer();
  for (final s in sentences) {
    final t = s.trim();
    if (t.isEmpty) continue;
    if (buf.isNotEmpty && buf.length + t.length + 1 > maxLen) {
      out.add(buf.toString());
      buf.clear();
    }
    if (buf.isNotEmpty) buf.write(' ');
    buf.write(t);
    // a single very long sentence: break at commas / semicolons
    while (buf.length > maxLen) {
      final cur = buf.toString();
      var cut = cur.lastIndexOf(RegExp(r'[,;:] '), maxLen);
      if (cut < 40) cut = cur.lastIndexOf(' ', maxLen);
      if (cut < 1) cut = maxLen;
      out.add(cur.substring(0, cut + 1).trim());
      buf
        ..clear()
        ..write(cur.substring(cut + 1).trim());
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

class PiperTts {
  final String modelPath;
  final PiperVoiceConfig config;
  final Phonemizer phonemizer;
  final OrtBridgeSession session;
  PiperTts._(this.modelPath, this.config, this.phonemizer, this.session);

  /// [espeakDataDir] holds `espeak-ng-data/` (see `ensureEspeakData`).
  static Future<PiperTts> open(String modelPath, String configPath, String espeakDataDir,
      {String provider = 'cpu', int threads = 4}) async {
    final cfg = await PiperVoiceConfig.load(configPath);
    final pm = Phonemizer()..initialize(dataPath: espeakDataDir);
    final session = await OrtBridgeSession.create(modelPath, provider: provider, threads: threads);
    return PiperTts._(modelPath, cfg, pm, session);
  }

  int get sampleRate => config.sampleRate;

  /// Synthesises [text] for speaker [sid]. [speed] > 1 is faster.
  Future<Float32List> synthesize(String text, {int sid = 0, double speed = 1.0}) async {
    final parts = <Float32List>[];
    for (final sentence in piperSentences(text)) {
      final ph = phonemizer.phonemize(sentence);
      final ids = piperPhonemeIds(ph, config);
      if (ids.length <= 3) continue;
      final inputs = <String, (List<int>, Object)>{
        'input': ([1, ids.length], Int64List.fromList(ids)),
        'input_lengths': ([1], Int64List.fromList([ids.length])),
        'scales': ([3], Float32List.fromList([config.noiseScale, config.lengthScale / speed, config.noiseW])),
      };
      if (config.numSpeakers > 1) inputs['sid'] = ([1], Int64List.fromList([sid]));
      final r = await session.run(inputs);
      parts.add(r.outputs.first.floats);
    }
    final total = parts.fold<int>(0, (a, p) => a + p.length);
    final out = Float32List(total);
    var o = 0;
    for (final p in parts) {
      out.setRange(o, o + p.length, p);
      o += p.length;
    }
    return out;
  }

  Future<void> dispose() async {
    phonemizer.dispose();
    await session.close();
  }
}
