import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';

const _pages = [
  RawPage(pageIdx: 0, text: '“Come here,” Alice said. “Not now,” Bob replied. “Hurry,” Carol whispered. “Quiet,” Dan said.'),
];

void main() {
  overrideMatchingTests();
  test('user trait words in an override become traits, the rest is the voice', () {
    final plan = NovelBookPlan.analyze(_pages, voiceOverrides: {'Bob': 'Michael, elder gruff', 'Dan': 'child cheerful'});
    final bob = plan.characters.firstWhere((c) => c.name == 'Bob');
    expect(bob.voiceOverride, 'Michael');
    expect((bob.traits.age, bob.traits.temperament), ('elder', 'gruff'));
    final dan = plan.characters.firstWhere((c) => c.name == 'Dan');
    expect(dan.voiceOverride, isNull);
    expect(dan.traits.age, 'child');
  });

  test('age and temperament change delivery speed and pitch', () {
    final plan = NovelBookPlan.analyze(_pages, voiceOverrides: {'Bob': 'elder gruff', 'Dan': 'child energetic'});
    final plain = plan.characters.firstWhere((c) => c.name == 'Alice').style;
    final bob = plan.characters.firstWhere((c) => c.name == 'Bob').style;
    final dan = plan.characters.firstWhere((c) => c.name == 'Dan').style;
    expect(bob.rate / 0.48, lessThan(0.95)); // slower than the 0.48 baseline
    expect(dan.rate, greaterThan(plain.rate));
    expect(bob.pitch, lessThan(dan.pitch));
  });

  test('researched traits fill gaps but never override the user', () {
    final plan = NovelBookPlan.analyze(_pages, voiceOverrides: {'Bob': 'young'}).withResearch({
      'Bob': const CharacterTraits(gender: 'male', age: 'elder', temperament: 'stern', source: 'web'),
      'Carol': const CharacterTraits(gender: 'female', age: 'adult', temperament: 'calm', source: 'web'),
    });
    final bob = plan.characters.firstWhere((c) => c.name == 'Bob');
    expect(bob.traits.age, 'young'); // user wins
    expect(bob.traits.temperament, 'stern'); // research fills the rest
    expect(bob.voiceGender, 'male'); // only because it was unknown
    expect(plan.characters.firstWhere((c) => c.name == 'Carol').voiceGender, 'female');
    expect(plan.characters.firstWhere((c) => c.name == 'Alice').traits.hasStyle, isFalse);
  });

  test('characters with traits spread across voices and avoid the narrator voice', () {
    final researched = {
      for (final n in ['Alice', 'Carol']) n: const CharacterTraits(gender: 'female', age: 'adult', temperament: 'calm', source: 'web'),
      for (final n in ['Bob', 'Dan']) n: const CharacterTraits(gender: 'male', age: 'elder', temperament: 'gruff', source: 'web'),
    };
    final plan = NovelBookPlan.analyze(_pages).withResearch(researched);
    final voices = {for (final c in plan.characters)
      c.name: resolveKokoroCharacterVoice(c, narrator: 'Bella', male: 'Adam', female: 'Sarah')};
    expect(voices.values.contains('Bella'), isFalse);
    expect(voices['Alice'] != voices['Carol'] || voices['Bob'] != voices['Dan'], isTrue);
    expect(['Adam', 'Michael'], containsAll([voices['Bob'], voices['Dan']].toSet()));
    // Without traits behaviour is unchanged: the single configured voice.
    final legacy = NovelBookPlan.analyze(_pages);
    expect(resolveKokoroCharacterVoice(legacy.characters.first, narrator: 'Bella', male: 'Adam', female: 'Sarah'), 'Bella');
  });

  test('LLM reply parsing is tolerant and vocabulary-checked', () {
    final out = CharacterResearcher.parseTraitsJson(
      'Sure!\n```json\n{"alice":{"gender":"Female","age":"child","temperament":"cheerful"},'
      '"Bob":{"gender":"robot","age":"ancient","temperament":"grumpy"},"Zed":{"age":"elder"}}\n```', ['Alice', 'Bob']);
    expect(out.keys, ['Alice']); // Bob had nothing valid; Zed is not a character
    expect(out['Alice']!.gender, 'female');
    expect(CharacterResearcher.parseTraitsJson('no json here', ['Alice']), isEmpty);
  });

  test('research is non-fatal and sends no book text', () async {
    final requests = <RequestOptions>[];
    final dio = Dio()..httpClientAdapter = _Fake((o) {
      requests.add(o);
      if (o.uri.host == 'en.wikipedia.org' && o.queryParameters['list'] == 'search') {
        return {'query': {'search': [{'title': 'A Test Novel'}]}};
      }
      if (o.uri.host == 'en.wikipedia.org') {
        return {'query': {'pages': {'1': {'extract': 'Intro.\n== Characters ==\nAlice is a cheerful young girl. Bob is a gruff old man.'}}}};
      }
      return {'choices': [{'message': {'content': '{"Alice":{"gender":"female","age":"child","temperament":"cheerful"},"Bob":{"gender":"male","age":"elder","temperament":"gruff"}}'}}]};
    });
    final llm = LlmEndpoint(baseUrl: 'openrouter.ai/api/v1/', apiKey: 'k', dio: dio);
    final result = await CharacterResearcher(llm: llm, model: 'm', dio: dio)
        .research(title: 'A Test Novel', names: ['Alice', 'Bob']);
    expect(result.skipped, isNull);
    expect(result.traits['Bob']!.temperament, 'gruff');
    final llmCall = requests.firstWhere((r) => r.uri.path.endsWith('/chat/completions'));
    expect(llmCall.uri.toString(), startsWith('https://openrouter.ai/api/v1/chat/completions'));
    expect(llmCall.data.toString(), isNot(contains('Come here')));

    final failing = Dio()..httpClientAdapter = _Fake((o) => throw DioException(requestOptions: o, type: DioExceptionType.connectionError));
    final skipped = await CharacterResearcher(llm: LlmEndpoint(baseUrl: 'x.test', apiKey: 'k', dio: failing), model: 'm', dio: failing)
        .research(title: 'T', names: ['Alice']);
    expect(skipped.traits, isEmpty);
    expect(skipped.skipped, isNotNull);
  });

  test('model listing: sorted with free first, friendly errors', () async {
    final ok = Dio()..httpClientAdapter = _Fake((o) => {'data': [{'id': 'b/pro'}, {'id': 'a/x:free'}, {'id': 'models/gemini-2'}]});
    expect(await LlmEndpoint(baseUrl: 'https://p.test/v1', apiKey: 'k', dio: ok).listModels(), ['a/x:free', 'b/pro', 'gemini-2']);
    final bad = Dio()..httpClientAdapter = _Fake((o) => {'error': {'message': 'No auth'}}, status: 401);
    await expectLater(LlmEndpoint(baseUrl: 'https://p.test/v1', apiKey: 'k', dio: bad).listModels(),
        throwsA(isA<LlmEndpointException>().having((e) => e.message, 'message', contains('API key was rejected'))));
    expect(LlmEndpoint.normalizeBaseUrl(' openrouter.ai/api/v1/ '), 'https://openrouter.ai/api/v1');
  });
}

class _Fake implements HttpClientAdapter {
  final Object Function(RequestOptions) handler;
  final int status;
  _Fake(this.handler, {this.status = 200});
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    final body = handler(options);
    return ResponseBody.fromString(jsonEncodeBody(body), status, headers: {Headers.contentTypeHeader: ['application/json']});
  }
  @override
  void close({bool force = false}) {}
}

String jsonEncodeBody(Object o) => const JsonEncoderHelper().encode(o);
class JsonEncoderHelper { const JsonEncoderHelper(); String encode(Object o) => _enc(o); }
String _enc(Object? o) {
  if (o is Map) return '{${o.entries.map((e) => '"${e.key}":${_enc(e.value)}').join(',')}}';
  if (o is List) return '[${o.map(_enc).join(',')}]';
  if (o is String) return '"${o.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n')}"';
  return '$o';
}

void overrideMatchingTests() {
  test('override names match ignoring case and by whole word; typos are reported', () {
    const pages = [RawPage(pageIdx: 0, text: '“Tea,” Hatter said. “Off,” the Queen said. “Hmm,” Alice replied.')];
    final plan = NovelBookPlan.analyze(pages, voiceOverrides: {
      'mad hatter': 'Michael, elder',
      'ALICE': 'child',
      'Cheshire': 'mysterious',
    });
    final hatter = plan.characters.firstWhere((c) => c.name == 'Hatter');
    expect(hatter.voiceOverride, 'Michael');
    expect(hatter.traits.age, 'elder');
    expect(plan.characters.firstWhere((c) => c.name == 'Alice').traits.age, 'child');
    expect(plan.unmatchedOverrides, ['Cheshire']);
    expect(plan.toJson()['unmatched_overrides'], ['Cheshire']);
    expect(resolveKokoroCharacterVoice(
        NovelBookPlan.analyze(pages, voiceOverrides: {'Alice': 'nicole'}).characters.first,
        narrator: 'Bella', male: 'Adam', female: 'Sarah'), 'Nicole');
  });
}
