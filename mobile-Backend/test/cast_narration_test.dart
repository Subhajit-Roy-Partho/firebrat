import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_models.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_plan.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_voices.dart';
import 'package:mobile_backend_pipeline/src/models/compiled_models.dart';
import 'package:mobile_backend_pipeline/src/models/conversion_settings.dart';
import 'package:mobile_backend_pipeline/src/models/raw_page.dart';
import 'package:mobile_backend_pipeline/src/pipeline/expressive_conversion.dart';
import 'package:mobile_backend_pipeline/src/pipeline/expressive_estimate.dart';
import 'package:mobile_backend_pipeline/src/compilation/model_catalog.dart';
import 'package:mobile_backend_pipeline/src/models/model_tier.dart';
import 'package:mobile_backend_pipeline/src/tts/accelerator.dart';
import 'package:mobile_backend_pipeline/src/tts/cast_narration_engine.dart';
import 'package:mobile_backend_pipeline/src/tts/expressive_assets.dart';
import 'package:mobile_backend_pipeline/src/tts/kokoro_v1_backend.dart';
import 'package:mobile_backend_pipeline/src/tts/piper_runtime.dart';
import 'package:mobile_backend_pipeline/src/tts/speech_backend.dart';

/// Tone generator standing in for a speech engine: records every call.
class FakeBackend implements SpeechBackend {
  final calls = <({String text, String voice, double speed})>[];
  @override
  String get engineName => 'fake_engine';
  @override
  int get sampleRate => 8000;
  @override
  List<VoiceProfile> get voices => kKokoroV1Voices;
  @override
  String get defaultNarratorVoice => 'af_heart';
  @override
  String get accelerationStatus => 'CPU';
  @override
  Future<void> ensureReady({void Function(double, String)? onProgress}) async {}
  @override
  Future<Float32List> speak(String text, {required String voice, required double speed}) async {
    calls.add((text: text, voice: voice, speed: speed));
    final n = (text.length * 40 / speed).round(); // 5 ms per character at speed 1
    return Float32List.fromList(List.generate(n, (i) => 0.3 * math.sin(i * 0.05)));
  }

  @override
  Future<void> dispose() async {}
}

const page0 = '“Good morning,” said Alice quietly. “How are you?”\n'
    '“I am late!” cried the Rabbit.';

CastResult castFor() => CastResult(
      narrator: const CastNarrator(accent: 'british'),
      characters: [
        const CastCharacter(id: 'char_001', name: 'Alice', gender: 'female', age: 'child', importance: 5),
        const CastCharacter(id: 'char_002', name: 'White Rabbit', gender: 'male', age: 'adult', importance: 3),
      ],
      utterances: const [
        CastUtterance(0, 0, 'char_001', 'sadness', 'whispered'),
        CastUtterance(0, 2, 'char_001', 'neutral', ''),
        CastUtterance(0, 3, 'char_002', 'fear', 'hurried'),
      ],
      pageMood: const {0: (emotion: 'suspense', delivery: '')},
      llmModel: 'fake',
      quotesTotal: 3,
      quotesByLlm: 3,
    );

void main() {
  final cast = castFor();
  final voices = assignVoices(cast.characters, narratorVoice: 'af_heart');
  final plan = CastPlan(cast: cast, voices: voices, narratorVoice: 'af_heart', engine: 'fake_engine');

  group('cast plan', () {
    test('each quote goes to its character; spans of narration join; the narrator never voices a character', () {
      final lines = plan.linesForPage(0, page0);
      final quotes = lines.where((l) => !l.isNarration).toList();
      expect(quotes.map((l) => l.speakerId), ['char_001', 'char_001', 'char_002']);
      expect(quotes.every((l) => l.voice != 'af_heart'), isTrue);
      expect(quotes.first.voice, isNot(quotes.last.voice));
      expect(lines.where((l) => l.isNarration).every((l) => l.voice == 'af_heart'), isTrue);
      // the original text is preserved verbatim, in order
      expect(lines.map((l) => l.text).join(), page0);
    });

    test('emotion drives delivery: sad whispered quote is slower and quieter than the fearful hurried one', () {
      final q = plan.linesForPage(0, page0).where((l) => !l.isNarration).toList();
      expect(q.first.delivery.speed, lessThan(q.last.delivery.speed));
      expect(q.first.delivery.gainDb, lessThan(q.last.delivery.gainDb));
    });

    test('manifest cast key and roster json have the expected shape', () {
      final m = plan.toManifestJson();
      expect(m['engine'], 'fake_engine');
      expect((m['narrator'] as Map)['voice'], 'af_heart');
      final chars = m['characters'] as List;
      expect(chars.length, 2);
      expect((chars.first as Map).keys, containsAll(['id', 'name', 'gender', 'age', 'voice']));
      final roster = plan.toRosterJson(scannedPages: 1);
      expect((roster['assigned_voices'] as Map)['Alice'], voices['char_001']!.voice);
      expect(((roster['characters'] as List).first as Map)['lines'], 2);
      expect((roster['dialogue'] as Map)['total'], 3);
    });
  });

  group('cast narration engine', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('cast_narr'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('writes standard section audio + segments, voices per speaker, delivery applied to engine speed', () async {
      final backend = FakeBackend();
      final engine = CastNarrationEngine(backend: backend, plan: plan);
      final r = await engine.narrateSection(
        sectionId: 'section_001',
        segments: [const CompiledSegment(type: SegmentKind.prose, text: page0)],
        sectionDir: '${tmp.path}/s1',
        sourcePages: const [0],
      );
      expect(File(r.audioPath).existsSync(), isTrue);
      expect(r.segmentsFile.sampleRate, 8000);
      final seg = r.segmentsFile.segments.single;
      expect(seg.endMs, greaterThan(seg.startMs));
      final byText = {for (final c in backend.calls) c.text.trim(): c};
      final sad = byText['“Good morning,”']!;
      final plain = byText['“How are you?”']!;
      expect(sad.voice, voices['char_001']!.voice);
      expect(plain.voice, sad.voice, reason: 'a character keeps one voice');
      expect(sad.speed, lessThan(plain.speed), reason: 'sadness/whispered is slower than neutral');
      expect(byText['“I am late!”']!.voice, voices['char_002']!.voice);
      // WAV header + PCM of the combined clip
      final bytes = File(r.audioPath).readAsBytesSync();
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    });

    test('without source pages the text is read in the narrator voice', () async {
      final backend = FakeBackend();
      await CastNarrationEngine(backend: backend, plan: plan).narrateSection(
        sectionId: 'section_002',
        segments: [const CompiledSegment(type: SegmentKind.prose, text: 'Just one plain line.')],
        sectionDir: '${tmp.path}/s2',
      );
      expect(backend.calls.single.voice, 'af_heart');
    });

    test('pitch shifting by resampling is compensated in the engine speed', () async {
      final backend = FakeBackend();
      final shifted = CastPlan(
          cast: cast, narratorVoice: 'af_heart', engine: 'fake_engine',
          voices: {'char_001': const VoiceAssignment('af_bella', semitones: 2), 'char_002': const VoiceAssignment('am_adam')});
      final engine = CastNarrationEngine(backend: backend, plan: shifted);
      final audio = await engine.speakLine(const PlannedLine('hello there friend', 'char_001', 'af_bella', 1.0, 2.0, Delivery()));
      // +2 semitones raises the playback rate by 12%: speak that much slower so the tempo stays natural
      final ratio = math.pow(2, 2 / 12);
      expect(backend.calls.single.speed, closeTo(1 / ratio, 0.01));
      expect(audio.length, closeTo('hello there friend'.length * 40, 60));
      expect(ratioForSemitones(0), 1.0);
    });
  });

  group('expressive pipeline stage', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('expr'));
    tearDown(() => tmp.deleteSync(recursive: true));
    final pages = [const RawPage(pageIdx: 0, text: page0)];

    test('casts with the LLM once, persists cast + voices, and resumes without any LLM call', () async {
      var llmCalls = 0;
      Future<String> fake(String system, String user, {required int maxTokens, required String label}) async {
        llmCalls++;
        if (user.contains('Excerpt')) {
          return jsonEncode({
            'narrator': {'accent': 'british'},
            'characters': [
              {'name': 'Alice', 'gender': 'female', 'age': 'child', 'lines': 4},
              {'name': 'White Rabbit', 'aliases': ['the Rabbit'], 'gender': 'male', 'age': 'adult', 'lines': 2},
            ]
          });
        }
        return jsonEncode({'utterances': [[0, 'c1', 'sadness', 'whispered'], [1, 'c1', 'neutral', ''], [2, 'c2', 'fear', 'hurried']]});
      }

      const settings = OnDeviceModeSettings(contentMode: BookContentMode.expressive, deviceRamMb: 7000);
      final first = await prepareExpressive(
          settings: settings, pages: pages, bookDir: tmp.path, modelsDir: tmp.path, report: (s, d, f) {},
          generateOverride: fake, backendOverride: FakeBackend());
      expect(llmCalls, greaterThan(0));
      expect(File('${tmp.path}/cast/cast.json').existsSync(), isTrue);
      expect(File('${tmp.path}/cast/voices.json').existsSync(), isTrue);
      final before = llmCalls;
      final second = await prepareExpressive(
          settings: settings, pages: pages, bookDir: tmp.path, modelsDir: tmp.path, report: (s, d, f) {},
          generateOverride: fake, backendOverride: FakeBackend());
      expect(llmCalls, before, reason: 'a finished cast is reused');
      expect(second.signature, first.signature, reason: 'the voices stay fixed for the whole book');
      expect(first.plan.cast.characters.map((c) => c.name), containsAll(['Alice', 'White Rabbit']));
    });
  });

  group('catalog, estimate and engines', () {
    test('time estimate: Piper narrates ~8x faster than Kokoro; casting scales with the model speed', () {
      final model = findOnDeviceLlmModel('qwen3-4b');
      final piper = estimateExpressive(words: 10000, model: model, tier: ModelTier.balanced, engine: ExpressiveEngine.piper);
      final kokoro = estimateExpressive(words: 10000, model: model, tier: ModelTier.balanced, engine: ExpressiveEngine.kokoro);
      expect(kokoro.narrationMinutes, greaterThan(piper.narrationMinutes * 5));
      expect(piper.castingMinutes, kokoro.castingMinutes);
      final small = estimateExpressive(words: 10000, model: findOnDeviceLlmModel('qwen3-1.7b'), tier: ModelTier.balanced, engine: ExpressiveEngine.piper);
      expect(small.castingMinutes, lessThan(piper.castingMinutes));
      expect(piper.audioMinutes, closeTo(10000 / 155, 0.5));
    });

    test('asset catalog: unique names, checksums everywhere, 28 Kokoro voices, 27 curated Piper voices', () {
      expect(kKokoroV1VoiceFiles.length, 28);
      expect(kKokoroV1VoiceFiles.every((f) => f.sha256.length == 64), isTrue);
      expect(kKokoroV1Models.every((m) => m.file.sha256.length == 64), isTrue);
      expect({for (final f in kKokoroV1VoiceFiles) f.fileName}.length, 28);
      expect(kPiperLibrittsModel.downloadUrl, contains(kPiperRevision));
      expect(kKokoroV1Models.first.file.downloadUrl, contains(kKokoroV1Revision));
      expect(kPiperLibrittsVoices.length, 27);
      expect({for (final v in kPiperLibrittsVoices) v.name}.length, 27);
      expect(kPiperLibrittsVoices.where((v) => v.female).length, 14);
      for (final v in kKokoroV1Voices) {
        expect(kKokoroV1VoiceFiles.any((f) => f.fileName == '${v.name}.bin'), isTrue, reason: v.name);
      }
    });

    test('Kokoro v1 accelerator plan follows the measurements: no NNAPI unless asked, XNNPACK only for fp16', () {
      List<String> plan(AcceleratorPreference p, bool fp16) =>
          KokoroV1Backend.planFor(preference: p, fp16: fp16, nnapiUsable: true).map((b) => b.name).toList();
      expect(plan(AcceleratorPreference.auto, false), ['cpu']);
      expect(plan(AcceleratorPreference.auto, true), ['xnnpack', 'cpu']);
      expect(plan(AcceleratorPreference.cpu, true), ['cpu']);
      expect(plan(AcceleratorPreference.gpuNpu, true), ['nnapi', 'xnnpack', 'cpu']);
    });

    test('Piper encoding: ^ + phoneme/pad pairs + \$, unknown phonemes skipped; sentences split under the limit', () {
      final cfg = PiperVoiceConfig.fromJson({
        'audio': {'sample_rate': 22050},
        'num_speakers': 2,
        'phoneme_id_map': {'^': [1], '\$': [2], '_': [0], 'a': [10], 'b': [11]},
      });
      expect(piperPhonemeIds('abz', cfg), [1, 10, 0, 11, 0, 2]);
      final text = List.filled(30, 'The rabbit hurried on and on.').join(' ');
      final parts = piperSentences(text, maxLen: 100);
      expect(parts.every((p) => p.length <= 100), isTrue);
      expect(parts.join(' ').replaceAll(RegExp(r'\s+'), ' '), text);
      expect(piperSentences('x' * 500, maxLen: 120).every((p) => p.length <= 121), isTrue);
    });

    test('Kokoro chunking keeps sentences and adds closing punctuation', () {
      expect(splitForKokoro('One. Two! Three'), ['One. Two! Three,']);
      final many = splitForKokoro(List.filled(40, 'A short sentence here.').join(' '), maxLen: 100);
      expect(many.every((c) => c.length <= 101), isTrue);
    });
  });
}
