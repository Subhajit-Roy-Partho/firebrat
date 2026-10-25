import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';

const _pages = [
  RawPage(pageIdx: 0, text: '“Come here,” Alice said. “Not now,” Bob replied. “Hurry,” Carol whispered. “Quiet,” Dan said.'),
];

void main() {
  test('coverage: lines per speaker and how much dialogue was attributed', () {
    const pages = [RawPage(pageIdx: 0, text: '“One,” Alice said. “Two,” Alice said. “Three,” said Bob. “Nobody tags this one.” “Nor this.”')];
    final plan = NovelBookPlan.analyze(pages);
    expect(plan.dialogueTotal, 5);
    expect(plan.dialogueAttributed, 3);
    expect(plan.characters.firstWhere((c) => c.name == 'Alice').lines, 2);
    expect(plan.characters.firstWhere((c) => c.name == 'Bob').lines, 1);
    final json = plan.toJson();
    expect(json['dialogue'], {'total': 5, 'attributed': 3});
    expect((json['characters'] as List).first['lines'], isA<int>());
  });
  researchCoverageTests();
  test('titled speakers keep their whole name', () {
    const pages = [RawPage(pageIdx: 0, text: '“Indeed,” said Mr. Darcy. “Never,” Elizabeth replied. “Oh!” cried Mrs. Bennet. “Quite so,” said Lady Catherine de Bourgh.')];
    final names = NovelBookPlan.analyze(pages).characters.map((c) => c.name).toSet();
    expect(names, containsAll(['Mr. Darcy', 'Elizabeth', 'Mrs. Bennet']));
    expect(names, isNot(contains('Mr')));
  });
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

void researchCoverageTests() {
  test('a large cast is researched in batches, each with the paragraphs about those characters', () async {
    final names = [for (var i = 1; i <= 25; i++) 'Person$i'];
    final article = [for (final n in names) '${n.toLowerCase()} appears here. $n is a gruff old man in the story, described at length.'].join('\n');
    final prompts = <String>[];
    final dio = Dio()..httpClientAdapter = _Fake((o) {
      if (o.uri.host == 'en.wikipedia.org' && o.queryParameters['list'] == 'search') {
        return {'query': {'search': [{'title': 'Big Novel'}]}};
      }
      if (o.uri.host == 'en.wikipedia.org') {
        return {'query': {'pages': {'1': {'extract': article}}}};
      }
      final user = ((o.data as Map)['messages'] as List).last['content'] as String;
      prompts.add(user);
      final asked = RegExp(r'Characters: (.*)').firstMatch(user)!.group(1)!.split(', ');
      return {'choices': [{'message': {'content': '{${asked.map((n) => '"$n":{"gender":"male","age":"elder","temperament":"gruff"}').join(',')}}'}}]};
    });
    final result = await CharacterResearcher(llm: LlmEndpoint(baseUrl: 'x.test', apiKey: 'k', dio: dio), model: 'm', dio: dio)
        .research(title: 'Big Novel', names: names);
    expect(prompts.length, 3); // 10 + 10 + 5
    expect(result.traits.length, 25);
    expect(result.missing, isEmpty);
    expect(prompts.first, contains('Person1 is a gruff'));
    expect(prompts.first, isNot(contains('Person25 is a gruff'))); // not stuffed with the whole article
    expect(result.toJson()['described'], 25);
  });

  test('aliases with no matching paragraph still get context; unmatched names are reported missing', () async {
    final ctx = CharacterResearcher.contextFor(['Lizzy'], [(title: 'T', url: 'u', text: 'Elizabeth Bennet is the second daughter, witty and cheerful. ' * 3)]);
    expect(ctx, contains('Elizabeth Bennet'));
    final dio = Dio()..httpClientAdapter = _Fake((o) {
      if (o.uri.host == 'en.wikipedia.org' && o.queryParameters['list'] == 'search') {
        return {'query': {'search': [{'title': 'T'}]}};
      }
      if (o.uri.host == 'en.wikipedia.org') return {'query': {'pages': {'1': {'extract': 'Lizzy is young and cheerful. Zed is mentioned too.'}}}};
      return {'choices': [{'message': {'content': '{"Lizzy":{"gender":"female","age":"young","temperament":"cheerful"},"Zed":{}}'}}]};
    });
    final result = await CharacterResearcher(llm: LlmEndpoint(baseUrl: 'x.test', apiKey: 'k', dio: dio), model: 'm', dio: dio)
        .research(title: 'T', names: ['Lizzy', 'Zed']);
    expect(result.traits.keys, ['Lizzy']);
    expect(result.missing, ['Zed']);
  });

  test('a rate-limited LLM call is retried with backoff and then succeeds', () async {
    var calls = 0;
    final dio = Dio()..httpClientAdapter = _Fake((o) {
      calls++;
      return {'choices': [{'message': {'content': 'ready'}}]};
    }, statusFor: (n) => n < 3 ? 429 : 200);
    final llm = LlmEndpoint(baseUrl: 'x.test', apiKey: 'k', dio: dio, retryDelays: const [Duration.zero, Duration.zero]);
    expect(await llm.chat(model: 'm', messages: const [{'role': 'user', 'content': 'hi'}]), 'ready');
    expect(calls, 3);
    final dead = Dio()..httpClientAdapter = _Fake((o) => {'error': {'message': 'busy'}}, status: 429);
    await expectLater(LlmEndpoint(baseUrl: 'x.test', apiKey: 'k', dio: dead, retryDelays: const [Duration.zero]).chat(model: 'm', messages: const []),
        throwsA(isA<LlmEndpointException>().having((e) => e.message, 'm', contains('rate-limiting'))));
  });

  test('research defaults to on and does not need the cloud helper', () {
    expect(const OnDeviceModeSettings().researchCharacters, isTrue);
    expect(const OnDeviceModeSettings().allowCloudFallback, isFalse);
  });
}

class _Fake implements HttpClientAdapter {
  final Object Function(RequestOptions) handler;
  final int status;
  final int Function(int callNumber)? statusFor;
  int _n = 0;
  _Fake(this.handler, {this.status = 200, this.statusFor});
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    final body = handler(options);
    _n++;
    return ResponseBody.fromString(jsonEncodeBody(body), statusFor?.call(_n) ?? status, headers: {Headers.contentTypeHeader: ['application/json']});
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
