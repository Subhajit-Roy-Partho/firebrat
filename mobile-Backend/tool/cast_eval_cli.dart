// Desktop evaluation of an LLM on the casting task through a running
// `llama-server` (OpenAI-compatible API). Uses exactly the same prompts,
// parsing, retry/fallback and scoring code as the phone (lib/src/cast).
//
//   llama-server -m model.gguf -c 8192 -ngl 99 --port 8099 --jinja &
//   dart run tool/cast_eval_cli.dart --url http://127.0.0.1:8099 --label qwen3-4b \
//       --fixture test/fixtures/cast_eval_sample.json --attr 14 --roster 6
//
// `--baseline` skips the model and scores the regex/narrator fallbacks instead.
import 'dart:convert';
import 'dart:io';

import '../lib/src/cast/cast_engine.dart';
import '../lib/src/cast/cast_eval.dart';

Future<void> main(List<String> args) async {
  String arg(String name, String def) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
  }

  final baseline = args.contains('--baseline');
  final url = arg('url', 'http://127.0.0.1:8099');
  final label = arg('label', 'model');
  final fixture = arg('fixture', 'test/fixtures/cast_eval_sample.json');
  final attrN = int.parse(arg('attr', '14'));
  final rosterN = int.parse(arg('roster', '6'));
  final out = arg('out', '');
  final dump = int.parse(arg('dump', '0'));
  final books = parseCastEvalFixture(await File(fixture).readAsString());
  final client = HttpClient();

  var promptTokens = 0, genTokens = 0;
  var promptMs = 0.0, genMs = 0.0;
  var calls = 0;
  final wall = Stopwatch();

  Future<String> generate(String system, String user, {required int maxTokens, required String label}) async {
    if (baseline) return '';
    final req = await client.postUrl(Uri.parse('$url/v1/chat/completions'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      'temperature': 0.2,
      'seed': 42,
      'max_tokens': maxTokens,
      'chat_template_kwargs': {'enable_thinking': false},
    }));
    final resp = await req.close();
    final body = jsonDecode(await resp.transform(utf8.decoder).join()) as Map;
    final timings = (body['timings'] as Map?) ?? const {};
    final usage = (body['usage'] as Map?) ?? const {};
    promptTokens += (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
    genTokens += (usage['completion_tokens'] as num?)?.toInt() ?? 0;
    promptMs += (timings['prompt_ms'] as num?)?.toDouble() ?? 0;
    genMs += (timings['predicted_ms'] as num?)?.toDouble() ?? 0;
    calls++;
    final choices = body['choices'] as List?;
    final reply = choices == null || choices.isEmpty ? '' : ((choices.first as Map)['message'] as Map)['content']?.toString() ?? '';
    if (dump > 0 && calls <= dump) stderr.writeln('--- $label\n${user.length > 1500 ? user.substring(0, 1500) : user}\n=> $reply\n');
    return reply;
  }

  CastEngine engine() => CastEngine(
      generate: generate, cache: MemoryCastCache(), limits: evalLimits(), modelId: label);

  wall.start();
  // --- attribution (reference roster) ---
  final cases = [for (final b in books) for (final c in b.cases) (b, c)];
  final picked = evenIndices(cases.length, attrN);
  final totals = EvalTotals();
  var ok = 0, tot = 0;
  for (final i in picked) {
    final (book, c) = cases[i];
    final e = engine();
    final t = await scoreAttributionCase(c, caseRoster(book, c), e);
    totals
      ..quotes += t.quotes
      ..speakerOk += t.speakerOk
      ..emotionExact += t.emotionExact
      ..emotionGroup += t.emotionGroup
      ..missing += t.missing
      ..named += t.named
      ..namedOk += t.namedOk;
    ok += e.firstTryOk;
    tot += e.firstTryTotal;
  }
  // --- roster ---
  var rosterValid = 0, rosterN2 = 0, expected = 0, found = 0, invented = 0;
  for (final i in evenIndices(cases.length, rosterN)) {
    final (book, c) = cases[i];
    final s = await scoreRosterCase(c, book.roster, generate);
    rosterN2++;
    if (s.validJson) rosterValid++;
    expected += s.expected;
    found += s.found;
    invented += s.invented;
  }
  wall.stop();
  final row = {
    'label': label,
    'baseline': baseline,
    'attr_passages': picked.length,
    'attr_json_first_try': tot == 0 ? null : ok / tot,
    ...totals.toJson(),
    'roster_passages': rosterN2,
    'roster_json_valid': rosterN2 == 0 ? null : rosterValid / rosterN2,
    'roster_recall': expected == 0 ? null : found / expected,
    'roster_invented_per_passage': rosterN2 == 0 ? null : invented / rosterN2,
    'calls': calls,
    'prompt_tokens': promptTokens,
    'gen_tokens': genTokens,
    'prefill_tok_s': promptMs == 0 ? null : promptTokens / (promptMs / 1000),
    'gen_tok_s': genMs == 0 ? null : genTokens / (genMs / 1000),
    'wall_s': wall.elapsedMilliseconds / 1000,
  };
  final line = jsonEncode(row);
  stdout.writeln(line);
  if (out.isNotEmpty) File(out).writeAsStringSync('$line\n', mode: FileMode.append);
  client.close();
}
