import 'dart:convert';
import 'dart:io';

import '../cast/cast_engine.dart';
import '../cast/cast_models.dart';
import '../cast/cast_plan.dart';
import '../cast/cast_voices.dart';
import '../compilation/model_catalog.dart';
import '../compilation/on_device_compiler.dart';
import '../models/conversion_settings.dart';
import '../models/device_capabilities.dart';
import '../models/raw_page.dart';
import '../tts/accelerator.dart';
import '../tts/cast_narration_engine.dart';
import '../tts/espeak_data.dart';
import '../tts/expressive_assets.dart';
import '../tts/kokoro_v1_backend.dart';
import '../tts/piper_backend.dart';
import '../tts/speech_backend.dart';

typedef ExpressiveReport = void Function(String stage, String detail, double fraction);

/// Everything the narration stage needs, plus what to record in the package.
class ExpressivePrepared {
  final CastPlan plan;
  final SpeechBackend backend;
  final CastNarrationEngine engine;
  final String signature; // changes when the cast or voices change (resume fingerprint)
  const ExpressivePrepared(this.plan, this.backend, this.engine, this.signature);
}

/// Casting (LLM) + voice assignment + speech backend for one book. Resumable:
/// `cast/cache/*.json` holds every LLM answer, `cast/cast.json` the finished
/// casting and `cast/voices.json` the voices (fixed for the whole book).
Future<ExpressivePrepared> prepareExpressive({
  required OnDeviceModeSettings settings,
  required List<RawPage> pages,
  required String bookDir,
  required String modelsDir,
  required ExpressiveReport report,
  CastGenerate? generateOverride, // tests
  SpeechBackend? backendOverride, // tests
}) async {
  final tier = DeviceCapabilities(totalRamMb: settings.deviceRamMb).tier;
  final castDir = '$bookDir/cast';
  await Directory(castDir).create(recursive: true);
  final castFile = File('$castDir/cast.json');
  CastResult? cast;
  if (await castFile.exists()) {
    try {
      final j = jsonDecode(await castFile.readAsString()) as Map<String, dynamic>;
      if (j['complete'] == true) {
        cast = CastResult.fromJson(j);
        report('casting', 'reusing the cast from the earlier run (${cast.characters.length} characters)', 0.8);
      }
    } catch (_) {
      cast = null;
    }
  }
  if (cast == null) {
    final model = findOnDeviceLlmModel(settings.onDeviceLlmModelId);
    OnDeviceCompiler? local;
    CastGenerate generate;
    if (generateOverride != null) {
      generate = generateOverride;
    } else {
      local = OnDeviceCompiler(model: model, gpuLayers: settings.onDeviceGpuLayers);
      await local.ensureReady(modelsDir: '$modelsDir/llm', onProgress: (p, s) => report('casting', s, 0.02));
      report('casting', 'language model ready (${model.displayName})', 0.04);
      final llm = local;
      generate = (system, user, {required maxTokens, required label}) =>
          llm.generateText(systemPrompt: system, userMessage: user, maxTokens: maxTokens, label: label);
    }
    try {
      final engine = CastEngine(
        generate: generate,
        cache: FileCastCache('$castDir/cache'),
        limits: CastLimits.forTier(tier),
        modelId: model.id,
        onProgress: (status, f) => report('casting', status, 0.04 + 0.76 * f),
      );
      cast = await engine.cast(pages);
    } finally {
      // Never keep the language model resident while the speech model loads.
      await local?.dispose();
    }
    final j = cast.toJson()..['complete'] = true;
    await castFile.writeAsString(jsonEncode(j), flush: true);
    report('casting',
        '${cast.characters.length} characters; ${cast.quotesByLlm} of ${cast.quotesTotal} quotes attributed by the language model'
        '${cast.notes.isEmpty ? '' : ' (${cast.notes.first})'}',
        0.8);
  }

  // --- speech engine + voices ---
  final engineKind = ExpressiveEngine.parse(settings.expressiveEngine);
  SpeechBackend backend;
  if (backendOverride != null) {
    backend = backendOverride;
  } else {
    final assets = await ExpressiveAssets.forApp();
    final kModel = findKokoroV1Model(settings.expressiveKokoroModelId);
    if (await assets.missingBytes(engineKind, kModel) > 0) {
      report('casting', 'downloading the ${engineKind.label} voices', 0.82);
      await assets.download(engineKind, kModel, onProgress: (p, s) => report('casting', s, 0.82 + 0.1 * (p ?? 0)));
    }
    await ensureEspeakData(assets.espeakBase);
    final accel = AcceleratorPreference.parse(settings.kokoroAcceleration);
    final threads = settings.kokoroCpuThreads.clamp(2, 4);
    backend = engineKind == ExpressiveEngine.piper
        ? PiperBackend(
            modelPath: assets.piperModelPath, configPath: assets.piperConfigPath, espeakDir: assets.espeakBase,
            provider: accel == AcceleratorPreference.cpu ? 'cpu' : 'xnnpack', threads: threads)
        : KokoroV1Backend(
            modelPath: assets.kokoroModelPath(kModel),
            fallbackModelPath: kModel.fp16 ? assets.kokoroModelPath(findKokoroV1Model('kokoro1-fp32')) : null,
            voicesDir: assets.kokoroVoicesDir,
            espeakDir: assets.espeakBase,
            threads: threads,
            accelerator: accel,
            modelIsFp16: kModel.fp16,
            installedVoices: await assets.installedKokoroVoices());
  }
  report('casting', 'loading the ${backend.engineName} voice model', 0.93);
  await backend.ensureReady(onProgress: (p, s) => report('casting', s, 0.93 + 0.06 * p));

  final catalog = backend.engineName == 'piper_libritts' ? kPiperLibrittsVoices : kKokoroV1Voices;
  final narrator = (settings.expressiveNarratorVoice != null && catalog.any((v) => v.name == settings.expressiveNarratorVoice))
      ? settings.expressiveNarratorVoice!
      : backend.defaultNarratorVoice;
  final voicesFile = File('$castDir/voices.json');
  var existing = <String, VoiceAssignment>{};
  if (await voicesFile.exists()) {
    try {
      final j = jsonDecode(await voicesFile.readAsString()) as Map<String, dynamic>;
      if (j['engine'] == backend.engineName && j['narrator'] == narrator) {
        existing = {for (final e in (j['voices'] as Map).entries) e.key as String: VoiceAssignment.fromJson(e.value as Map)};
      }
    } catch (_) {
      existing = {};
    }
  }
  final voices = assignVoices(cast.characters,
      narratorVoice: narrator,
      catalog: catalog,
      available: {for (final v in backend.voices) v.name},
      overrides: settings.characterVoices,
      existing: existing);
  await voicesFile.writeAsString(jsonEncode({
    'engine': backend.engineName,
    'narrator': narrator,
    'voices': {for (final e in voices.entries) e.key: e.value.toJson()},
  }), flush: true);
  final plan = CastPlan(cast: cast, voices: voices, narratorVoice: narrator, engine: backend.engineName);
  final signature = '${backend.engineName}:$narrator:${voices.entries.map((e) => '${e.key}=${e.value.voice}/${e.value.semitones}').join(',')}:${cast.utterances.length}';
  return ExpressivePrepared(plan, backend, CastNarrationEngine(backend: backend, plan: plan), signature);
}
