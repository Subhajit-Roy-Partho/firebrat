import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_engine.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_json.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_models.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_prompts.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_segmenter.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_voices.dart';
import 'package:mobile_backend_pipeline/src/models/model_tier.dart';
import 'package:mobile_backend_pipeline/src/models/raw_page.dart';

const page0 = '“Good morning,” said Alice. “How are you?”\n'
    '“Quite well,” replied the Rabbit, hurrying on. “I am late!”\n'
    '“Wait!” cried Alice.';
const page1 = 'Alice ran after him down the hole.\n“Oh dear, oh dear,” muttered the Rabbit.\n'
    'He glanced at his watch. “No time at all!”';

final pages = [const RawPage(pageIdx: 0, text: page0), const RawPage(pageIdx: 1, text: page1)];

/// Scripted fake LLM. [roster] answers the roster prompt, attribution answers
/// come from [attribute] (given the parsed quote count and the user prompt).
class FakeLlm {
  int calls = 0;
  final List<String> labels = [];
  String Function(String user) roster;
  String Function(String user, int quotes) attribute;
  FakeLlm({String Function(String)? roster, String Function(String, int)? attribute})
      : roster = roster ?? ((_) => jsonEncode({
              'narrator': {'accent': 'british'},
              'characters': [
                {'name': 'Alice', 'aliases': [], 'gender': 'female', 'age': 'child', 'temperament': 'curious', 'accent': 'british', 'lines': 5},
                {'name': 'White Rabbit', 'aliases': ['the Rabbit'], 'gender': 'male', 'age': 'adult', 'temperament': 'anxious', 'accent': 'british', 'lines': 3},
              ]
            })),
        attribute = attribute ?? ((user, n) => jsonEncode({'utterances': [for (var i = 0; i < n; i++) [i, i.isEven ? 'c1' : 'c2', i == 0 ? 'joy' : 'fear', 'quickly']]}));

  Future<String> call(String system, String user, {required int maxTokens, required String label}) async {
    calls++;
    labels.add(label);
    if (system == kRosterSystem) return roster(user);
    final n = RegExp(r'^\[(\d+)\]', multiLine: true).allMatches(user).length;
    return attribute(user, n);
  }
}

CastEngine engine(FakeLlm llm, {CastCacheStore? cache, CastLimits? limits}) => CastEngine(
    generate: llm.call, cache: cache ?? MemoryCastCache(), limits: limits ?? CastLimits.forTier(ModelTier.balanced), modelId: 'fake-model');

void main() {
  group('segmenter', () {
    test('is lossless and keys quotes by (page, idx)', () {
      final segs = segmentPageText(0, page0);
      expect(segs.map((s) => s.text).join(), page0);
      expect(segs.where((s) => s.isQuote).length, 5);
      expect([for (final s in segs) s.idx], List.generate(segs.length, (i) => i));
    });
    test('splits very long narration at sentence ends without losing text', () {
      final long = List.filled(40, 'The rabbit hurried along the path.').join(' ');
      final segs = segmentPageText(3, long, limit: 120);
      expect(segs.every((s) => s.text.length <= 120), isTrue);
      expect(segs.map((s) => s.text).join(), long);
    });
  });

  group('json extraction', () {
    test('handles think blocks, fences, trailing commas and surrounding prose', () {
      expect(extractJsonObject('<think>hmm {not json}</think>```json\n{"a": [1,2,],}\n```')['a'], [1, 2]);
      expect(extractJsonObject('Sure! Here you go: {"a": 1} Hope it helps.')['a'], 1);
    });
    test('repairs output truncated by the token limit', () {
      final v = extractJsonValue('{"utterances":[[0,"c1","joy","fast"],[1,"c2","fear","whisp') as Map;
      expect((v['utterances'] as List).length, 2);
      expect(((v['utterances'] as List)[1] as List).length, 3); // the cut-off row keeps what was complete
      expect(() => extractJsonValue('no json at all'), throwsFormatException);
    });
  });

  group('roster helpers', () {
    test('normName strips honorifics and merges aliases', () {
      expect(normName('Mr. Darcy'), 'darcy');
      final merged = mergeCharacters(
          [const CastCharacter(id: '', name: 'Elizabeth Bennet', aliases: ['Lizzy'], importance: 4)],
          [const CastCharacter(id: '', name: 'Lizzy', gender: 'female', importance: 9)]);
      expect(merged.length, 1);
      expect(merged.single.gender, 'female');
      expect(merged.single.importance, 9);
    });
    test('assignIds is stable, most important first', () {
      final r = assignIds([
        const CastCharacter(id: '', name: 'B', importance: 1),
        const CastCharacter(id: '', name: 'A', importance: 7),
      ]);
      expect(r.map((c) => c.id), ['char_001', 'char_002']);
      expect(r.first.name, 'A');
    });
    test('emotion synonyms normalise, unknown becomes neutral', () {
      expect(normalizeEmotion('Angry'), 'anger');
      expect(normalizeEmotion('whatever'), 'neutral');
    });
  });

  group('casting engine', () {
    test('roster + attribution from the LLM, short ids resolved', () async {
      final llm = FakeLlm();
      final result = await engine(llm).cast(pages);
      expect(result.characters.map((c) => c.name), containsAll(['Alice', 'White Rabbit']));
      final alice = result.characters.firstWhere((c) => c.name == 'Alice');
      expect(result.utterances.length, 7);
      final first = result.utterances.first;
      expect(first.emotion, 'joy');
      expect(result.quotesByLlm, 7);
      expect(result.quotesByRegex, 0);
      expect(result.utterances.where((u) => u.speaker != kNarratorId), isNotEmpty);
      expect(result.characters.first.id, startsWith('char_'));
      expect(alice.id, isNotEmpty);
      expect(result.pageMood.containsKey(0), isTrue);
    });

    test('an interrupted conversion resumes from the cache with zero LLM calls', () async {
      final cache = MemoryCastCache();
      final first = FakeLlm();
      final a = await engine(first, cache: cache).cast(pages);
      expect(first.calls, greaterThan(0));
      final second = FakeLlm();
      final b = await engine(second, cache: cache).cast(pages);
      expect(second.calls, 0);
      expect(jsonEncode(b.toJson()['utterances']), jsonEncode(a.toJson()['utterances']));
    });

    test('malformed first reply triggers one repair retry', () async {
      var attempt = 0;
      final llm = FakeLlm(attribute: (user, n) {
        attempt++;
        if (attempt == 1) return 'I think the speakers are Alice and the rabbit.';
        return jsonEncode({'utterances': [for (var i = 0; i < n; i++) [i, 'c1', 'neutral', '']]});
      });
      final result = await engine(llm).cast([pages.first]);
      expect(result.quotesByLlm, 5);
      expect(llm.labels.where((l) => l.contains('retry')), isNotEmpty);
    });

    test('partial rows: only the missing quotes are re-asked', () async {
      final prompts = <String>[];
      var attribCall = 0;
      final llm = FakeLlm(attribute: (user, n) {
        prompts.add(user);
        attribCall++;
        if (attribCall == 1) return '{"utterances":[[0,"c1","joy",""],[1,"c1","joy",""]]}';
        return '{"utterances":[[2,"c2","fear",""],[3,"c1","neutral",""],[4,"c1","anger",""]]}';
      });
      final result = await engine(llm).cast([pages.first]);
      expect(prompts.length, 2);
      expect(prompts[1], contains('ONLY quotes 2, 3, 4'));
      expect(result.quotesByLlm, 5);
    });

    test('total LLM failure falls back to dialogue tags, then the narrator', () async {
      final llm = FakeLlm(roster: (_) => 'garbage', attribute: (_, __) => 'garbage');
      final result = await engine(llm).cast(pages);
      expect(result.quotesByLlm, 0);
      expect(result.quotesByRegex, 7);
      // "said Alice" / "cried Alice" tags still cast Alice from the regex roster
      final alice = result.characters.firstWhere((c) => c.name == 'Alice');
      expect(result.utterances.where((u) => u.speaker == alice.id), isNotEmpty);
      expect(result.utterances.every((u) => u.emotion == 'neutral'), isTrue);
    });

    test('a throwing LLM never aborts the book', () async {
      final result = await CastEngine(
        generate: (s, u, {required maxTokens, required label}) async => throw StateError('out of memory'),
        cache: MemoryCastCache(), limits: CastLimits.forTier(ModelTier.balanced), modelId: 'x').cast(pages);
      expect(result.utterances.length, 7);
      expect(result.notes.any((n) => n.contains('out of memory')), isTrue);
    });

    test('the call budget caps LLM use and says so', () async {
      final llm = FakeLlm();
      const tiny = CastLimits(chunkWords: 20, maxQuotesPerChunk: 2, rosterWindows: 1, windowWords: 500, maxLlmCalls: 3);
      final result = await engine(llm, limits: tiny).cast(pages);
      expect(llm.calls, lessThanOrEqualTo(3));
      expect(result.notes.any((n) => n.contains('limit for this phone')), isTrue);
      expect(result.utterances.length, 7);
    });

    test('cast result survives a JSON round trip', () async {
      final result = await engine(FakeLlm()).cast(pages);
      final back = CastResult.fromJson(jsonDecode(jsonEncode(result.toJson())) as Map);
      expect(back.characters.length, result.characters.length);
      expect(back.utterances.length, result.utterances.length);
      expect(back.pageMood.keys, result.pageMood.keys);
    });

    test('limits scale with the device class and light phones are not offered expressive mode', () {
      expect(CastLimits.allowedFor(ModelTier.light), isFalse);
      expect(CastLimits.allowedFor(ModelTier.balanced), isTrue);
      expect(CastLimits.forTier(ModelTier.powerful).maxLlmCalls, greaterThan(CastLimits.forTier(ModelTier.balanced).maxLlmCalls));
    });

    test('time estimate grows with the book and shrinks with a faster model', () {
      final long = [for (var i = 0; i < 200; i++) RawPage(pageIdx: i, text: page0 + ' ' + page1)];
      final lim = CastLimits.forTier(ModelTier.balanced);
      final slow = estimateCasting(long, lim, promptTokensPerSecond: 20, generationTokensPerSecond: 4);
      final fast = estimateCasting(long, lim, promptTokensPerSecond: 80, generationTokensPerSecond: 10);
      expect(slow.minutes, greaterThan(fast.minutes));
      expect(slow.quotes, 1400);
      expect(slow.attributionCalls + slow.rosterCalls, lessThanOrEqualTo(lim.maxLlmCalls));
    });
  });

  group('small-model output handling', () {
    final roster = assignIds([
      const CastCharacter(id: '', name: 'Alice', importance: 9),
      const CastCharacter(id: '', name: 'White Rabbit', aliases: ['the Rabbit'], importance: 5),
      const CastCharacter(id: '', name: 'Mouse', importance: 2),
    ]);

    test('unwraps one level too many of nesting', () {
      final rows = parseAttributionRows('{"utterances":[[[0,"c1","joy",""],[1,"c2","fear","fast"]]]}', 2, roster)!;
      expect(rows.map((r) => r.speaker), ['char_001', 'char_002']);
    });

    test('loose parsing salvages broken quoting, pipes and bare numbers', () {
      final broken = parseAttributionRows('{"utterances":[[0,"c1","sadness,""],[1,"c2","surprise,""]]}', 2, roster)!;
      expect(broken.map((r) => r.emotion), ['sadness', 'surprise']);
      final lines = parseAttributionRows('0|c3|angry|shouted\n1|n|neutral|', 2, roster)!;
      expect(lines.first.speaker, 'char_003');
      expect(lines.first.emotion, 'anger');
      expect(lines.last.speaker, kNarratorId);
      expect(parseAttributionRows('no rows here', 2, roster, loose: true), isNull);
      expect(parseAttributionRows('0|c1|joy|', 1, roster, loose: false), isNull, reason: 'strict mode is for the JSON-health metric');
    });

    test('short ids refer to the per-chunk subset, names and char ids to the whole roster', () {
      final subset = [roster[2], roster[0]]; // c1 = Mouse, c2 = Alice
      final rows = parseAttributionRows('[[0,"c1","neutral",""],[1,"Alice","joy",""],[2,"char_002","fear",""]]', 3, roster, shortIds: subset)!;
      expect(rows.map((r) => r.speaker), ['char_003', 'char_001', 'char_002']);
    });

    test('rosterForChunk: names in the passage, recent speakers and the leads; stable order; capped', () {
      final many = assignIds([for (var i = 0; i < 20; i++) CastCharacter(id: '', name: 'Person$i Surname$i', importance: 100 - i)]);
      final picked = rosterForChunk(many, 'Then Surname7 spoke to Person12.', [many[15].id]);
      expect(picked.map((c) => c.name), containsAll([many[0].name, many[1].name, many[7].name, many[12].name, many[15].name]));
      expect(picked.length, lessThanOrEqualTo(10));
      expect(picked, orderedEquals([...picked]..sort((a, b) => many.indexOf(a).compareTo(many.indexOf(b)))));
      expect(rosterForChunk(many, 'Nobody is named here at all.', []).length, 4);
    });
  });

  group('voice casting', () {
    final cast = assignIds([
      for (var i = 0; i < 6; i++)
        CastCharacter(id: '', name: 'F$i', gender: 'female', age: i == 0 ? 'child' : i == 1 ? 'elder' : 'adult', importance: 20 - i),
      for (var i = 0; i < 6; i++)
        CastCharacter(id: '', name: 'M$i', gender: 'male', age: i == 0 ? 'elder' : 'adult', importance: 10 - i),
    ]);

    test('every character gets a voice of their gender, never the narrator voice, all distinct', () {
      final a = assignVoices(cast, narratorVoice: 'af_heart');
      expect(a.length, cast.length);
      for (final c in cast) {
        final v = findV1Voice(a[c.id]!.voice)!;
        expect(v.gender, c.gender);
        expect(v.name, isNot('af_heart'));
      }
      expect({for (final x in a.values) x.voice}.length, cast.length);
    });

    test('age shapes pitch: a child gets a higher voice than an elder of the same gender', () {
      final a = assignVoices(cast, narratorVoice: 'af_heart');
      final child = cast.firstWhere((c) => c.name == 'F0');
      final elder = cast.firstWhere((c) => c.name == 'F1');
      expect(findV1Voice(a[child.id]!.voice)!.f0, greaterThan(findV1Voice(a[elder.id]!.voice)!.f0));
    });

    test('more characters than voices: voices are shared with a pitch offset, still never the narrator', () {
      final many = assignIds([for (var i = 0; i < 40; i++) CastCharacter(id: '', name: 'P$i', gender: 'male', importance: 40 - i)]);
      final a = assignVoices(many, narratorVoice: 'bm_george');
      expect(a.values.every((x) => x.voice != 'bm_george'), isTrue);
      expect(a.values.where((x) => x.semitones != 0), isNotEmpty);
    });

    test('user overrides win; decisions are stable across a resume', () {
      final first = assignVoices(cast, narratorVoice: 'af_heart', overrides: {'f3': 'am_onyx'});
      expect(first[cast.firstWhere((c) => c.name == 'F3').id]!.voice, 'am_onyx');
      final again = assignVoices(cast, narratorVoice: 'af_heart', existing: first);
      expect({for (final e in again.entries) e.key: e.value.voice}, {for (final e in first.entries) e.key: e.value.voice});
    });

    test('only installed voices are used', () {
      final a = assignVoices(cast, narratorVoice: 'af_heart', available: {'af_bella', 'af_nicole', 'am_adam', 'am_echo', 'am_onyx', 'am_puck', 'af_kore', 'af_sky'});
      expect(a.values.every((x) => {'af_bella', 'af_nicole', 'am_adam', 'am_echo', 'am_onyx', 'am_puck', 'af_kore', 'af_sky'}.contains(x.voice)), isTrue);
    });
  });

  group('emotion delivery', () {
    test('every emotion has a table entry; all stay in natural bounds', () {
      for (final e in kCastEmotions) {
        final d = deliveryFor(e);
        expect(kEmotionDelivery.containsKey(e), isTrue, reason: e);
        expect(d.speed, inInclusiveRange(0.78, 1.25));
        expect(d.semitones.abs(), lessThanOrEqualTo(1.8));
      }
    });
    test('sad is slower and quieter than angry; whispered lowers gain; stacked cues are clamped', () {
      expect(deliveryFor('sadness').speed, lessThan(deliveryFor('anger').speed));
      expect(deliveryFor('sadness').gainDb, lessThan(deliveryFor('anger').gainDb));
      expect(deliveryFor('neutral', 'whispered, trembling').gainDb, lessThan(deliveryFor('neutral').gainDb));
      final extreme = deliveryFor('fear', 'quickly, hurried, rushed, breathless, shouted');
      expect(extreme.speed, lessThanOrEqualTo(1.25));
    });
    test('gain and pitch post-processing', () {
      final tone = List<double>.generate(2400, (i) => 0.5 * (i.isEven ? 1 : -1));
      final quieter = applyGainAndPitch(tone, gainDb: -6);
      expect(quieter.first.abs(), closeTo(0.25, 0.01));
      final higher = applyGainAndPitch(tone, semitones: 12);
      expect(higher.length, closeTo(1200, 2));
      expect(applyGainAndPitch(tone).length, tone.length);
    });
  });
}
