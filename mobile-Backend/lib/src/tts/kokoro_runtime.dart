// Adapted from flutter_kokoro_tts 0.0.1, Copyright (c) 2025 Pius Ikeoffiah.
// MIT license: see third_party/KOKORO_LICENSE in mobile-Backend.
// Keep upstream's phonemizer/model handling, but bound CPU parallelism and
// avoid logging complete book text/phonemes for every utterance.
// The helper imports below are pinned to the direct 0.0.1 dependency.
// ignore_for_file: implementation_imports

import 'dart:io';

import 'dart:convert';
import 'dart:typed_data';
import 'audio_trim.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_kokoro_tts/src/model_manager.dart';
import 'package:flutter_kokoro_tts/src/phonemizer.dart';
import 'package:flutter_kokoro_tts/src/text_cleaner.dart';
import 'package:flutter_kokoro_tts/src/text_preprocessor.dart';
import '../models/device_capabilities.dart';
import '../models/model_tier.dart';
import '../models/tts_model_catalog.dart';
import 'accelerator.dart';

/// Every selectable voice name (bundled six first, then the extra five).
final List<String> kokoroVoices = [for (final v in kKokoroVoiceCatalog) v.name];

/// Map of voice names to their corresponding file names
final Map<String, String> _kokoroVoiceMap = {for (final v in kKokoroVoiceCatalog) v.name: v.fileName};

const double _defaultSpeedPrior = 0.8;

class FirebratKokoroTts {
  final int cpuThreads;

  /// `auto`, `gpuNpu`/`nnapi` or `cpu` (see [AcceleratorPreference.parse]).
  final String acceleration;

  /// Catalog id of the Kokoro model file (see `tts_model_catalog.dart`).
  final String modelId;
  final DeviceCapabilities device;
  FirebratKokoroTts({
    this.cpuThreads = 2,
    this.acceleration = 'cpu',
    this.modelId = kDefaultTtsModelId,
    this.device = DeviceCapabilities.unknown,
  });

  AcceleratedSession<OrtSession>? _accel;

  /// "Running on" text, valid after initialisation (and meaningful after the
  /// first synthesis, which is when a runtime fallback can still happen).
  String get accelerationStatus => _accel?.statusLabel ?? 'Not started';
  AccelBackend? get activeBackend => _accel?.active;
  List<String> get accelerationNotes => List.unmodifiable(_accel?.notes ?? const []);
  /// Why a model other than the requested one was used, if it was.
  String? modelNote;
  final Stopwatch _synthWatch = Stopwatch();
  int _synthSamples = 0;
  final KokoroModelManager _modelManager = KokoroModelManager();
  final Phonemizer _phonemizer = Phonemizer();
  final TextCleaner _textCleaner = TextCleaner();
  final TextPreprocessor _textPreprocessor = TextPreprocessor();
  static const int _maxTokens = 500;

  bool _isInitialized = false;
  Future<void>? _initializing;

  /// Output sample rate (always 24 000 Hz)
  int sampleRate = 24000;

  /// Name of available voices.
  List<String> get availableVoices => List.unmodifiable(kokoroVoices);

  /// Voice cache
  final Map<String, Float32List> _voiceCache = {};

  /// Initialize the Kokoro TTS engine.
  ///
  /// [espeakDataPath] Optional. Directory that contains espeak-ng-data (with
  /// phontab, etc.), or the espeak-ng-data directory itself. If null, uses
  /// the kokoro base dir (parent of the model dir); you must place
  /// espeak-ng-data there or pass a valid path. See README for obtaining data.
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
    String? espeakDataPath,
  }) {
    // If already initialized → return completed future
    if (_isInitialized) return Future.value();

    // If initialization is in progress → return same future
    if (_initializing != null) return _initializing!;

    _initializing = _doInitialize(onProgress, espeakDataPath);

    return _initializing!;
  }

  Future<void> _doInitialize(
    void Function(double progress, String status)? onProgress,
    String? espeakDataPath,
  ) async {
    try {
      onProgress?.call(0.0, 'Downloading model...');

      await _modelManager.download(
        onProgress: (p, status) {
          onProgress?.call(p, status);
        },
      );

      if (espeakDataPath == null) {
        onProgress?.call(0.9, 'Ensuring espeak-ng data...');
        await _modelManager.ensureEspeakData();
      }
      final dataPath = espeakDataPath ?? _modelManager.kokoroBaseDir;
      _phonemizer.initialize(dataPath: dataPath);

      onProgress?.call(0.97, 'Loading ONNX session...');
      final ort = OnnxRuntime();
      final threads = cpuThreads.clamp(1, 4);
      // Model file: the requested variant when it is on disk, else the always
      // present int8 model (never fail a conversion over a missing variant).
      final requested = findTtsModel(modelId);
      var modelFile = _modelManager.modelPath;
      if (!requested.bundledWithBase) {
        final candidate = File('${_modelManager.modelDir}/${requested.fileName}');
        if (await candidate.exists() && await candidate.length() == requested.approxSizeBytes) {
          modelFile = candidate.path;
        } else {
          modelNote = '${requested.displayName} is not downloaded; using the default int8 model.';
          onProgress?.call(0.97, modelNote!);
        }
      }
      final servedModel = modelFile == _modelManager.modelPath ? findTtsModel(kDefaultTtsModelId) : requested;
      var providers = <String>{};
      if (Platform.isAndroid) {
        try {
          providers = {for (final p in await ort.getAvailableProviders()) p.name};
        } catch (_) {}
      }
      final caps = DeviceCapabilities(
        totalRamMb: device.totalRamMb,
        supportedAbis: device.supportedAbis,
        androidSdk: device.androidSdk,
        ortProviders: providers.isNotEmpty ? providers : device.ortProviders,
      );
      final plan = Platform.isAndroid
          ? planAccelerators(
              preference: AcceleratorPreference.parse(acceleration), device: caps, model: servedModel)
          : const [AccelBackend.cpu];
      onProgress?.call(0.97, 'Loading ONNX session (${plan.first.label})...');
      _accel = AcceleratedSession<OrtSession>(
        plan: plan,
        create: (backend) => ort.createSession(modelFile,
            options: OrtSessionOptions(
                intraOpNumThreads: threads,
                interOpNumThreads: 1,
                providers: switch (backend) {
                  AccelBackend.nnapi => [OrtProvider.NNAPI, OrtProvider.CPU],
                  AccelBackend.xnnpack => [OrtProvider.XNNPACK, OrtProvider.CPU],
                  _ => [OrtProvider.CPU],
                })),
        close: (session) => session.close(),
      );
      await _accel!.open();
      if (_accel!.notes.isNotEmpty) onProgress?.call(0.98, _accel!.notes.last);

      _isInitialized = true;
      onProgress?.call(1.0, 'Ready');
    } catch (e) {
      _initializing = null; // allow retry if failed
      rethrow;
    }
  }

  Future<Float32List> _getVoice(String voice) async {
    if (_voiceCache.containsKey(voice)) {
      return _voiceCache[voice]!;
    }

    final path = '${_modelManager.modelDir}/voices/${_kokoroVoiceMap[voice]!}';

    if (!await File(path).exists()) {
      throw StateError('Voice "$voice" is not downloaded. Download the extra voices in Conversion settings, or pick another voice.');
    }
    final bytes = await File(path).readAsBytes();
    final embedding = bytes.buffer.asFloat32List();

    _voiceCache[voice] = embedding;
    return embedding;
  }

  Future<Float32List> generate(
    String text, {
    String voice = 'Default',
    double speed = 1.0,
  }) async {
    if (text.trim().isEmpty) return Float32List(0);

    await initialize();

    if (!availableVoices.contains(voice)) {
      throw Exception('Invalid voice: $voice');
    }

    final chunks = _splitIntoChunks(text);
    final parts = <Float32List>[];

    for (final chunk in chunks) {
      final audio = await _generateChunk(chunk, voice: voice, speed: speed);
      if (audio.isNotEmpty) parts.add(audio);
    }

    if (parts.isEmpty) return Float32List(0);
    if (parts.length == 1) return parts.first;

    // Chunks are trimmed tight, so put back a short natural pause between sentences.
    final gap = silenceSamples(sampleRate, 170);
    final total = parts.fold<int>(0, (sum, part) => sum + part.length) + gap.length * (parts.length - 1);
    final result = Float32List(total);
    var offset = 0;
    for (var i = 0; i < parts.length; i++) {
      result.setRange(offset, offset + parts[i].length, parts[i]);
      offset += parts[i].length;
      if (i < parts.length - 1) offset += gap.length; // zeros already
    }
    return result;
  }

  Future<Float32List> _generateChunk(
    String chunk, {
    required String voice,
    required double speed,
  }) async {
    // --Text Cleaning & Preprocessing--
    final cleanText = _textPreprocessor.process(chunk);
    final cleanTextWithPunctuation = _addTrailingPunctuation(cleanText.trim());

    // --Phonemization--
    final phonemes = _phonemizer.phonemize(cleanTextWithPunctuation);

    // --Encoding--
    final encodedTokens = _textCleaner.encodeAndWrap(phonemes);

    // -- Guard: split if tokens exceed model capacity --
    if (encodedTokens.length > _maxTokens) {
      final mid = encodedTokens.length ~/ 2;
      int splitAt = chunk.indexOf(RegExp(r'[.!?,;:\s]'), mid);
      if (splitAt < 0 || splitAt == chunk.length - 1) splitAt = mid;
      final firstHalf = chunk.substring(0, splitAt);
      final secondHalf = chunk.substring(splitAt);

      final parts = <Float32List>[];
      if (firstHalf.isNotEmpty) {
        parts.add(await _generateChunk(firstHalf, voice: voice, speed: speed));
      }
      if (secondHalf.isNotEmpty) {
        parts.add(await _generateChunk(secondHalf, voice: voice, speed: speed));
      }

      if (parts.isEmpty) return Float32List(0);
      if (parts.length == 1) return parts.first;

      final total = parts.fold<int>(0, (sum, part) => sum + part.length);
      final result = Float32List(total);
      var offset = 0;
      for (final part in parts) {
        result.setRange(offset, offset + part.length, part);
        offset += part.length;
      }
      return result;
    }

    // -- Voice: .bin files are (N, 256); model expects style [1, 256]. Pick row by token length.
    const styleDim = 256;
    final styleAll = await _getVoice(voice);
    final numVectors = styleAll.length ~/ styleDim;
    if (numVectors == 0) {
      throw Exception(
        'Voice file for "$voice" has no style vectors (expected multiple of $styleDim floats)',
      );
    }
    final tokenLen = encodedTokens.length.clamp(0, numVectors - 1);
    final style = Float32List.sublistView(
      styleAll,
      tokenLen * styleDim,
      (tokenLen + 1) * styleDim,
    );

    // -- Speed Adjustment --
    const speedFactor = _defaultSpeedPrior;

    final effectiveSpeed = speed * speedFactor;

    // - ONNX inference --
    final inputIds = await OrtValue.fromList(
      Int64List.fromList(encodedTokens),
      [1, encodedTokens.length],
    );

    final styleTensor = await OrtValue.fromList(style, [1, styleDim]);

    final speedTensor = await OrtValue.fromList([effectiveSpeed], [1]);

    if (!_synthWatch.isRunning) _synthWatch.start();
    final Map<String, OrtValue> outputs;
    try {
      outputs = await _accel!.run((session) => session.run({
            'input_ids': inputIds,
            'style': styleTensor,
            'speed': speedTensor,
          }));
    } catch (_) {
      await inputIds.dispose();
      await styleTensor.dispose();
      await speedTensor.dispose();
      rethrow;
    }

    // Dispose inputs
    await inputIds.dispose();
    await styleTensor.dispose();
    await speedTensor.dispose();

    // Find the audio output tensor (largest)

    OrtValue? audioOut;
    int audioLen = 0;
    for (final entry in outputs.entries) {
      final len = entry.value.shape.fold<int>(1, (a, b) => a * b);
      if (len > audioLen) {
        audioOut = entry.value;
        audioLen = len;
      }
    }

    if (audioOut == null) {
      return Float32List(0);
    }

    final rawList = await audioOut.asFlattenedList();

    // Dispose all output tensors
    for (final v in outputs.values) {
      await v.dispose();
    }

    Float32List audio;

    if (rawList is List<double>) {
      audio = Float32List.fromList(rawList.cast<double>());
    } else {
      audio = Float32List.fromList(
        rawList.map((e) => (e as num).toDouble()).toList(),
      );
    }

    // Trim the silent head/tail the model leaves around each sentence (a fixed
    // 5000-sample cut left ~0.7 s of dead air after every sentence).
    audio = trimSilence(audio, sampleRate);
    _synthSamples += audio.length;


    return audio;
  }

  /// Records what the last run used so the settings screen can show
  /// "Running on: ...". Best effort; never throws.
  Future<void> _writeStatus() async {
    try {
      final accel = _accel;
      if (accel == null) return;
      final seconds = _synthWatch.elapsedMilliseconds / 1000;
      final audioSeconds = _synthSamples / sampleRate;
      await File('${_modelManager.modelDir}/last_run.json').writeAsString(jsonEncode({
        'status': accel.statusLabel,
        'backend': accel.active?.name,
        'requested': accel.requested.name,
        'model': modelId,
        'notes': [...accel.notes, if (modelNote != null) modelNote],
        'realtime_factor': audioSeconds > 0 ? double.parse((seconds / audioSeconds).toStringAsFixed(2)) : null,
        'audio_seconds': double.parse(audioSeconds.toStringAsFixed(1)),
      }));
    } catch (_) {}
  }

  /// Persists the status after the first synthesis finished (call once).
  Future<void> recordStatus() => _writeStatus();

  // ── Helpers ──

  List<String> _splitIntoChunks(String text, {int maxLen = 200}) {
    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final chunks = <String>[];
    final buf = StringBuffer();

    for (final s in sentences) {
      final trimmed = s.trim();
      if (trimmed.isEmpty) continue;
      if (buf.length + trimmed.length + 1 > maxLen && buf.isNotEmpty) {
        chunks.add(_addTrailingPunctuation(buf.toString().trim()));
        buf.clear();
      }
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(trimmed);
    }
    if (buf.isNotEmpty) {
      chunks.add(_addTrailingPunctuation(buf.toString().trim()));
    }
    return chunks.isEmpty ? [_addTrailingPunctuation(text.trim())] : chunks;
  }

  static String _addTrailingPunctuation(String t) {
    t = t.trim();
    if (t.isEmpty) return t;
    return '.!?,;:'.contains(t[t.length - 1]) ? t : '$t,';
  }

  // static String _trunc(String s, [int n = 60]) =>
  //     s.length <= n ? s : '${s.substring(0, n)}…';

  Future<void> dispose() async {
    if (!_isInitialized) return;

    // Dispose ONNX session
    await _writeStatus();
    await _accel?.close();
    _accel = null;

    // Dispose phonemizer
    _phonemizer.dispose();

    // clear voice cache
    _voiceCache.clear();

    _isInitialized = false;
    _initializing = null;
  }
}
