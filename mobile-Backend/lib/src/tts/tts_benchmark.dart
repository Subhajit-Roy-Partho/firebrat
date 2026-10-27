// ignore_for_file: implementation_imports
/// On-device speech benchmark: runs Kokoro ONNX graphs with every ONNX Runtime
/// execution provider the plugin offers and reports real-time factor,
/// correctness against the CPU run of the same graph, and failures.
///
/// Driven by `<dir>/bench_config.json` so a run can change models/providers
/// without rebuilding the APK. Run it with the integration test in the app
/// (`frontend/firebrat_app/integration_test/tts_benchmark_test.dart`); every
/// result line is printed as `BENCH|{json}` so it can be grepped from logs.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_kokoro_tts/src/phonemizer.dart';
import 'package:flutter_kokoro_tts/src/text_cleaner.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'espeak_data.dart';
import 'ort_bridge.dart';
import 'piper_runtime.dart';
import 'wav_utils.dart';

/// Texts in increasing length (public-domain prose, Alice in Wonderland).
const kBenchTexts = <String, String>{
  'short': 'Alice was beginning to get very tired.',
  'mid':
      'So she was considering in her own mind, whether the pleasure of making a daisy-chain would be worth the trouble.',
  'long':
      '"Oh dear! Oh dear! I shall be late!" said the White Rabbit, and he hurried away down the long dark passage '
      'with his watch in his hand, while Alice ran after him as fast as she could.',
};

class BenchSpec {
  final String label;
  final String model;

  /// cpu | xnnpack | nnapi
  final String provider;
  final int threads;

  /// Pad the token sequence with zeros to this length (fixed-shape graphs).
  final int? padTo;
  final String voice;

  /// `plugin` (flutter_onnxruntime) or `bridge` (OrtBridge: NNAPI flags + profiling).
  final String engine;
  final int nnapiFlags;
  final bool profile;

  /// `kokoro` (whole model) or `decoder` (the vocoder half cut out of Kokoro,
  /// fixed to [frames] frames of 600 samples; fp16 IO when [halfIo]).
  final String mode;
  final int frames;
  final bool halfIo;

  /// Idle seconds before this spec (lets the phone cool between runs).
  final int pauseS;

  /// Marks the run every other result is compared with (`corr_vs_ref`).
  final bool reference;
  const BenchSpec(
    this.label,
    this.model,
    this.provider, {
    this.mode = 'kokoro',
    this.frames = 128,
    this.halfIo = false,
    this.threads = 4,
    this.padTo,
    this.voice = 'af_heart',
    this.engine = 'plugin',
    this.nnapiFlags = 0,
    this.profile = false,
    this.pauseS = 0,
    this.reference = false,
  });

  factory BenchSpec.fromJson(Map j) => BenchSpec(
    (j['label'] ?? '${j['model']}/${j['provider']}').toString(),
    j['model'].toString(),
    (j['provider'] ?? 'cpu').toString(),
    threads: (j['threads'] as num?)?.toInt() ?? 4,
    padTo: (j['padTo'] as num?)?.toInt(),
    voice: (j['voice'] ?? 'af_heart').toString(),
    engine: (j['engine'] ?? 'plugin').toString(),
    nnapiFlags: (j['nnapiFlags'] as num?)?.toInt() ?? 0,
    profile: j['profile'] == true,
    mode: (j['mode'] ?? 'kokoro').toString(),
    frames: (j['frames'] as num?)?.toInt() ?? 128,
    halfIo: j['halfIo'] == true,
    pauseS: (j['pauseS'] as num?)?.toInt() ?? 0,
    reference: j['reference'] == true,
  );
}

String _providerName(String p) => p;

List<OrtProvider> _providers(String p) => switch (p) {
  'nnapi' => [OrtProvider.NNAPI, OrtProvider.CPU],
  'xnnpack' => [OrtProvider.XNNPACK, OrtProvider.CPU],
  _ => [OrtProvider.CPU],
};

double _rms(Float32List x) {
  if (x.isEmpty) return 0;
  var s = 0.0;
  for (final v in x) {
    s += v * v;
  }
  return math.sqrt(s / x.length);
}

/// Pearson correlation of the overlapping part (1.0 = same waveform).
double _corr(Float32List a, Float32List b) {
  final n = math.min(a.length, b.length);
  if (n == 0) return 0;
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < n; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= n;
  mb /= n;
  var sab = 0.0, saa = 0.0, sbb = 0.0;
  for (var i = 0; i < n; i++) {
    final x = a[i] - ma, y = b[i] - mb;
    sab += x * y;
    saa += x * x;
    sbb += y * y;
  }
  return saa == 0 || sbb == 0 ? 0 : sab / math.sqrt(saa * sbb);
}

int _rssMb() {
  try {
    for (final line in File('/proc/self/status').readAsLinesSync()) {
      if (line.startsWith('VmRSS:')) {
        return int.parse(line.split(RegExp(r'\s+'))[1]) ~/ 1024;
      }
    }
  } catch (_) {}
  return -1;
}

int _peakRssMb() {
  try {
    for (final line in File('/proc/self/status').readAsLinesSync()) {
      if (line.startsWith('VmHWM:')) {
        return int.parse(line.split(RegExp(r'\s+'))[1]) ~/ 1024;
      }
    }
  } catch (_) {}
  return -1;
}

Object? _jsonSafe(Object? v) => v is double && !v.isFinite ? 'NaN' : v;

/// Which execution provider ran how many nodes and for how long (ms), from an
/// ONNX Runtime profile JSON. Nodes delegated to NNAPI show up as fused
/// `NnapiExecutionProvider` nodes; everything else is `CPUExecutionProvider`.
Future<Map<String, Object?>> summarizeOrtProfile(String path) async {
  try {
    final events = jsonDecode(await File(path).readAsString()) as List;
    final nodes = <String, int>{};
    final micros = <String, int>{};
    final ops = <String, Map<String, int>>{};
    for (final e in events) {
      if (e is! Map ||
          e['cat'] != 'Node' ||
          !(e['name'] as String).endsWith('_kernel_time')) {
        continue;
      }
      final args = (e['args'] as Map?) ?? const {};
      final provider = (args['provider'] ?? 'unknown').toString().replaceAll(
        'ExecutionProvider',
        '',
      );
      nodes[provider] = (nodes[provider] ?? 0) + 1;
      micros[provider] = (micros[provider] ?? 0) + (e['dur'] as num).toInt();
      final op = (args['op_name'] ?? '').toString();
      final m = ops.putIfAbsent(provider, () => {});
      m[op] = (m[op] ?? 0) + (e['dur'] as num).toInt();
    }
    final top = {
      for (final p in ops.entries)
        p.key:
            (p.value.entries.toList()
                  ..sort((a, b) => b.value.compareTo(a.value)))
                .take(4)
                .map((e) => '${e.key}:${e.value ~/ 1000}ms')
                .toList(),
    };
    return {
      'nodes': nodes,
      'kernel_ms_total': {
        for (final e in micros.entries) e.key: e.value ~/ 1000,
      },
      'top_ops_ms': top,
    };
  } catch (e) {
    return {'profile_error': '$e'};
  }
}

void _emit(Map<String, Object?> row, void Function(String) sink) => sink(
  'BENCH|${jsonEncode({for (final e in row.entries) e.key: _jsonSafe(e.value)})}',
);

/// Runs every spec of `<dir>/bench_config.json`:
/// `{"specs":[{"model":"model_fp16.onnx","provider":"nnapi","padTo":128}], "runs":3}`.
/// Waveforms of the first text are written to `<dir>/out/<label>.wav`.
Future<List<Map<String, Object?>>> runKokoroBenchmark(
  String dir, {
  void Function(String) log = print,
}) async {
  final config =
      jsonDecode(await File('$dir/bench_config.json').readAsString()) as Map;
  final specs = [
    for (final s in (config['specs'] as List)) BenchSpec.fromJson(s as Map),
  ];
  final runs = (config['runs'] as num?)?.toInt() ?? 3;
  final textKeys = [
    for (final t in (config['texts'] as List? ?? kBenchTexts.keys.toList()))
      t.toString(),
  ];
  await ensureEspeakData(dir);
  final phonemizer = Phonemizer()..initialize(dataPath: dir);
  final cleaner = TextCleaner();
  final rows = <Map<String, Object?>>[];
  final ort = OnnxRuntime();
  try {
    _emit({
      'kind': 'providers',
      'available': [for (final p in await ort.getAvailableProviders()) p.name],
    }, log);
  } catch (e) {
    _emit({'kind': 'providers', 'error': '$e'}, log);
  }
  await Directory('$dir/out').create(recursive: true);
  final cpuRef = <String, Float32List>{};
  for (final spec in specs) {
    if (spec.pauseS > 0) await Future<void>.delayed(Duration(seconds: spec.pauseS));
    Future<Float32List> Function(List<int> ids, Float32List style)? infer;
    int sampleRate = 24000;
    String currentText = '';
    Future<String?> Function()? closeSession;
    final base = <String, Object?>{
      'kind': 'run',
      'label': spec.label,
      'model': spec.model,
      'provider': _providerName(spec.provider),
      'padTo': spec.padTo,
      'threads': spec.threads,
    };
    final sw = Stopwatch()..start();
    try {
      if (spec.engine == 'bridge') {
        final bs = await OrtBridgeSession.create(
          '$dir/${spec.model}',
          provider: spec.provider,
          threads: spec.threads,
          nnapiFlags: spec.nnapiFlags,
          profilePrefix: spec.profile ? '$dir/out/prof_${spec.label}' : null,
        );
        if (spec.mode == 'piper') {
          final cfg = await PiperVoiceConfig.load('$dir/${spec.model}.json');
          sampleRate = cfg.sampleRate;
          final sid = int.tryParse(spec.voice) ?? 0;
          infer = (ids, style) async {
            final parts = <Float32List>[];
            for (final sentence in piperSentences(currentText)) {
              final pids = piperPhonemeIds(phonemizer.phonemize(sentence), cfg);
              final inputs = <String, (List<int>, Object)>{
                'input': ([1, pids.length], Int64List.fromList(pids)),
                'input_lengths': ([1], Int64List.fromList([pids.length])),
                'scales': (
                  [3],
                  Float32List.fromList([
                    cfg.noiseScale,
                    cfg.lengthScale,
                    cfg.noiseW,
                  ]),
                ),
              };
              if (cfg.numSpeakers > 1) {
                inputs['sid'] = ([1], Int64List.fromList([sid]));
              }
              parts.add((await bs.run(inputs)).outputs.first.floats);
            }
            final out = Float32List(parts.fold<int>(0, (a, p) => a + p.length));
            var o = 0;
            for (final p in parts) {
              out.setRange(o, o + p.length, p);
              o += p.length;
            }
            return out;
          };
        } else {
          infer = spec.mode == 'decoder'
              ? (ids, style) async {
                  final f = spec.frames;
                  final asr = Float32List(512 * f),
                      f0 = Float32List(2 * f),
                      n = Float32List(2 * f);
                  for (var c = 0; c < 512; c++) {
                    for (var t = 0; t < f; t++) {
                      asr[c * f + t] = 0.25 * math.sin(0.07 * c + 0.11 * t);
                    }
                  }
                  for (var t = 0; t < 2 * f; t++) {
                    f0[t] = 150 + 30 * math.sin(0.05 * t);
                    n[t] = -9.5 + 0.2 * math.sin(0.3 * t);
                  }
                  Object enc(Float32List v) =>
                      spec.halfIo ? floatsToHalfBytes(v) : v;
                  final r = await bs.run({
                    '/encoder/MatMul_1_output_0': ([1, 512, f], enc(asr)),
                    '/encoder/Reshape_output_0': ([1, 2 * f], enc(f0)),
                    '/encoder/Reshape_1_output_0': ([1, 2 * f], enc(n)),
                    spec.halfIo ? 'graph_input_cast_1' : 'style': (
                      [1, 256],
                      enc(style),
                    ),
                  });
                  return r.outputs.first.floats;
                }
              : (ids, style) async {
                  final r = await bs.run({
                    'input_ids': ([1, ids.length], Int64List.fromList(ids)),
                    'style': ([1, 256], style),
                    'speed': ([1], Float32List.fromList([0.8])),
                  });
                  return r.outputs.first.floats;
                };
        }
        closeSession = () => bs.close(profile: spec.profile);
      } else {
        final session = await ort.createSession(
          '$dir/${spec.model}',
          options: OrtSessionOptions(
            intraOpNumThreads: spec.threads,
            interOpNumThreads: 1,
            providers: _providers(spec.provider),
          ),
        );
        infer = (ids, style) async {
          final a = await OrtValue.fromList(Int64List.fromList(ids), [
            1,
            ids.length,
          ]);
          final st = await OrtValue.fromList(style, [1, 256]);
          final sp = await OrtValue.fromList([0.8], [1]);
          try {
            final out = await session.run({
              'input_ids': a,
              'style': st,
              'speed': sp,
            });
            final flat = await out.values.first.asFlattenedList();
            for (final v in out.values) {
              await v.dispose();
            }
            return Float32List.fromList([
              for (final v in flat) (v as num).toDouble(),
            ]);
          } finally {
            await a.dispose();
            await st.dispose();
            await sp.dispose();
          }
        };
        closeSession = () async {
          await session.close();
          return null;
        };
      }
      base['create_ms'] = sw.elapsedMilliseconds;
      base['engine'] = spec.engine;
      base['nnapiFlags'] = spec.nnapiFlags;
    } catch (e) {
      final row = {
        ...base,
        'status': 'create_failed',
        'error': '$e'.split('\n').first,
      };
      rows.add(row);
      _emit(row, log);
      continue;
    }
    final voiceFile = File(spec.mode == 'piper' ? '$dir/voices/af_heart.bin' : '$dir/voices/${spec.voice}.bin');
    final styleAll = (await voiceFile.readAsBytes()).buffer.asFloat32List();
    for (final entry
        in kBenchTexts.entries
            .where((e) => textKeys.contains(e.key))
            .take(spec.mode == 'decoder' ? 1 : 99)) {
      currentText = entry.value;
      final ids = cleaner.encodeAndWrap(phonemizer.phonemize(entry.value));
      final n = ids.length;
      final padded = spec.padTo == null
          ? ids
          : [...ids, ...List.filled(math.max(0, spec.padTo! - n), 0)];
      if (spec.padTo != null && n > spec.padTo!) {
        final row = {
          ...base,
          'text': entry.key,
          'tokens': n,
          'status': 'skipped_too_long',
        };
        rows.add(row);
        _emit(row, log);
        continue;
      }
      final styleRow = n.clamp(0, styleAll.length ~/ 256 - 1);
      final style = Float32List.sublistView(
        styleAll,
        styleRow * 256,
        (styleRow + 1) * 256,
      );
      final times = <int>[];
      Float32List? audio;
      String? error;
      for (var r = 0; r < runs; r++) {
        final t = Stopwatch()..start();
        try {
          audio = await infer(padded, style);
          t.stop();
          times.add(t.elapsedMilliseconds);
        } catch (e) {
          error = '$e'.split('\n').first;
          break;
        }
      }
      if (error != null || audio == null) {
        final row = {
          ...base,
          'text': entry.key,
          'tokens': n,
          'status': 'run_failed',
          'error': error,
        };
        rows.add(row);
        _emit(row, log);
        break;
      }
      final secs = audio.length / sampleRate;
      final clean = Float32List.fromList([
        for (final v in audio) v.isNaN ? 0.0 : v,
      ]);
      final warm = times.length > 1 ? times.sublist(1) : times;
      final med = ([...warm]..sort())[warm.length ~/ 2];
      final key = entry.key; // all comparisons are against the reference run of the same text
      double? corr;
      if (spec.reference) cpuRef[key] = audio;
      final ref = cpuRef[key];
      if (ref != null && !identical(ref, audio)) corr = _corr(ref, audio);
      final row = {
        ...base,
        'text': entry.key,
        'status': 'ok',
        'tokens': n,
        'audio_s': double.parse(secs.toStringAsFixed(2)),
        'first_run_ms': times.first,
        'warm_ms': med,
        'rtf': double.parse((med / 1000 / secs).toStringAsFixed(3)),
        'rms': double.parse(_rms(clean).toStringAsFixed(4)),
        'nonsilent': _rms(clean) > 0.005,
        'nan_samples': audio.where((v) => v.isNaN).length,
        'corr_vs_ref': corr == null
            ? null
            : double.parse(corr.toStringAsFixed(4)),
        'len_ratio_vs_ref': ref == null
            ? null
            : double.parse((audio.length / ref.length).toStringAsFixed(3)),
        'rss_mb': _rssMb(),
        'peak_rss_mb': _peakRssMb(),
      };
      rows.add(row);
      _emit(row, log);
      if (entry.key == 'mid') {
        final pcm = Uint8List(clean.length * 2);
        final bd = ByteData.view(pcm.buffer);
        for (var i = 0; i < clean.length; i++) {
          bd.setInt16(
            i * 2,
            (clean[i].clamp(-1.0, 1.0) * 32767).round(),
            Endian.little,
          );
        }
        final wav = WavAudio(
          sampleRate: 24000,
          channels: 1,
          bitsPerSample: 16,
          pcmData: pcm,
        );
        await File(
          '$dir/out/${spec.label.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_')}.wav',
        ).writeAsBytes(wav.toBytes());
      }
    }
    String? profilePath;
    try {
      profilePath = await closeSession();
    } catch (e) {
      _emit({
        ...base,
        'status': 'close_failed',
        'error': '$e'.split('\n').first,
      }, log);
    }
    if (profilePath != null) {
      _emit({
        'kind': 'profile',
        'label': spec.label,
        'runs': runs,
        ...await summarizeOrtProfile(profilePath),
      }, log);
    }
  }
  phonemizer.dispose();
  _emit({'kind': 'done', 'rows': rows.length}, log);
  return rows;
}
