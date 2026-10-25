// Opt-in live check against a real OpenAI-compatible endpoint. Skipped unless
// FIREBRAT_LIVE_LLM_KEY is set; never runs in CI. The key is read from the
// environment and is never printed.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';

void main() {
  final key = Platform.environment['FIREBRAT_LIVE_LLM_KEY'] ?? '';
  final url = Platform.environment['FIREBRAT_LIVE_LLM_URL'] ?? 'https://openrouter.ai/api/v1';
  final skip = key.isEmpty ? 'set FIREBRAT_LIVE_LLM_KEY to run' : false;

  test('lists models and a free model answers', () async {
    final llm = LlmEndpoint(baseUrl: url, apiKey: key);
    final models = await llm.listModels();
    stdout.writeln('models listed: ${models.length}; free: ${models.where((m) => m.endsWith(':free')).length}');
    expect(models, isNotEmpty);
    final free = models.where((m) => m.endsWith(':free')).toList();
    expect(free, isNotEmpty);
    // Free models are rate-limited or temporarily unavailable now and then,
    // so try a few before declaring failure.
    String? lastError;
    for (final m in free.take(6)) {
      try {
        stdout.writeln('test(${m}): ${await llm.test(model: m)}');
        return;
      } on LlmEndpointException catch (e) {
        lastError = '$m -> ${e.message}';
        stdout.writeln('  skipped $lastError');
      }
    }
    fail('no free model answered: $lastError');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('wrong key gives a friendly message', () async {
    final llm = LlmEndpoint(baseUrl: url, apiKey: 'sk-or-v1-not-a-real-key');
    await expectLater(llm.listModels().then((_) => llm.chat(model: 'x/y:free', messages: const [{'role': 'user', 'content': 'hi'}])),
        throwsA(isA<LlmEndpointException>()));
  }, skip: skip);

  test('researches a famous novel on Wikipedia with a free model', () async {
    final llm = LlmEndpoint(baseUrl: url, apiKey: key);
    final free = (await llm.listModels()).where((m) => m.endsWith(':free')).toList();
    for (final m in free.take(6)) {
      final r = await CharacterResearcher(llm: llm, model: m).research(
        title: "Alice's Adventures in Wonderland", names: ['Alice', 'Queen of Hearts', 'Mad Hatter', 'White Rabbit']);
      stdout.writeln('research with $m -> ${r.skipped ?? 'applied'}: '
          '${r.traits.map((k, v) => MapEntry(k, '${v.gender}/${v.age}/${v.temperament}'))}');
      if (r.skipped == null) {
        expect(r.traits, isNotEmpty);
        return;
      }
    }
    fail('research did not succeed with any free model');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
}
