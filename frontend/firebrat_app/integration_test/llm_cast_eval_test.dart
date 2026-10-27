import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:path_provider/path_provider.dart';

/// On-device LLM evaluation on the casting task: valid-JSON rate, speaker and
/// emotion accuracy against test/fixtures/cast_eval_sample.json, throughput
/// and memory, one model after another. Results are printed as `BENCH|{json}`.
///
/// Setup: start this test (it reinstalls the app, wiping its external files),
/// then push into
///   /sdcard/Android/data/com.firebrat.firebrat_app.debug/files/llm_eval/
///   cast_eval_sample.json, models/CATALOG_FILE_NAME.gguf ..., llm_eval_config.json (LAST)
/// config: {"models":["qwen3-1.7b"],"attr":8,"roster":3,"gpuLayers":0}
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('LLM casting evaluation', (tester) async {
    final ext = (await getExternalStorageDirectory())!;
    final dir = '${ext.path}/llm_eval';
    for (var i = 0; i < 400 && !File('$dir/llm_eval_config.json').existsSync(); i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    final config = jsonDecode(await File('$dir/llm_eval_config.json').readAsString()) as Map;
    await Future<void>.delayed(const Duration(seconds: 2));
    // ignore: avoid_print
    void emit(Map<String, Object?> row) => print('BENCH|${jsonEncode(row)}');
    final books = parseCastEvalFixture(await File('$dir/cast_eval_sample.json').readAsString());
    final cases = [for (final b in books) for (final c in b.cases) (b, c)];
    final attrPicked = evenIndices(cases.length, (config['attr'] as num?)?.toInt() ?? 8);
    final rosterPicked = evenIndices(cases.length, (config['roster'] as num?)?.toInt() ?? 3);
    final gpuLayers = (config['gpuLayers'] as num?)?.toInt() ?? 0;
    final support = (await getApplicationSupportDirectory()).path;
    final llmDir = '$support/firebrat_models/llm';
    await Directory(llmDir).create(recursive: true);

    for (final id in (config['models'] as List).cast<String>()) {
      final model = findOnDeviceLlmModel(id);
      final src = File('$dir/models/${model.fileName}');
      if (!src.existsSync()) {
        emit({'kind': 'model', 'id': id, 'status': 'file_missing'});
        continue;
      }
      emit({'kind': 'model_start', 'id': id, 'file': model.fileName, 'avail_mb': _availMb()});
      final dst = File('$llmDir/${model.fileName}');
      if (!dst.existsSync()) await src.copy(dst.path);
      final compiler = OnDeviceCompiler(model: model, gpuLayers: gpuLayers);
      var minAvail = _availMb();
      var peakRss = _rssMb();
      final sampler = Timer.periodic(const Duration(seconds: 1), (_) {
        final a = _availMb();
        if (a > 0 && a < minAvail) minAvail = a;
        final r = _rssMb();
        if (r > peakRss) peakRss = r;
      });
      final load = Stopwatch()..start();
      try {
        await compiler.ensureReady(modelsDir: llmDir, allowDownload: false);
      } catch (e) {
        sampler.cancel();
        emit({'kind': 'model', 'id': id, 'status': 'load_failed', 'error': '$e'.split('\n').first});
        continue;
      }
      load.stop();
      emit({'kind': 'loaded', 'id': id, 'load_ms': load.elapsedMilliseconds, 'rss_mb': _rssMb(), 'avail_mb': _availMb()});

      var promptTokens = 0, genTokens = 0, calls = 0;
      var promptMs = 0.0, genMs = 0.0;
      Future<String> generate(String system, String user, {required int maxTokens, required String label}) async {
        final reply = await compiler.generateText(systemPrompt: system, userMessage: user, maxTokens: maxTokens, label: label);
        final st = compiler.lastGenerationStats;
        final pt = (st['prompt_tokens'] as num?)?.toInt() ?? 0;
        final gt = (st['generated_tokens'] as num?)?.toInt() ?? 0;
        final first = (st['first_token_ms'] as num?)?.toDouble() ?? 0;
        final total = (st['generation_ms'] as num?)?.toDouble() ?? 0;
        if (pt > 0) promptTokens += pt;
        genTokens += gt;
        promptMs += first;
        genMs += (total - first).clamp(0, double.infinity);
        calls++;
        return reply;
      }

      CastEngine engine() => CastEngine(generate: generate, cache: MemoryCastCache(), limits: evalLimits(), modelId: id);
      final totals = EvalTotals();
      var ok = 0, tot = 0;
      final wall = Stopwatch()..start();
      try {
        for (final i in attrPicked) {
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
          emit({'kind': 'passage', 'id': id, 'page': c.page, 'quotes': t.quotes, 'speaker_ok': t.speakerOk, 'avail_mb': _availMb()});
        }
        var rosterValid = 0, rosterN = 0, expected = 0, found = 0, invented = 0;
        for (final i in rosterPicked) {
          final (book, c) = cases[i];
          final s = await scoreRosterCase(c, book.roster, generate);
          rosterN++;
          if (s.validJson) rosterValid++;
          expected += s.expected;
          found += s.found;
          invented += s.invented;
        }
        wall.stop();
        emit({
          'kind': 'summary',
          'id': id,
          'gpu_layers': gpuLayers,
          'attr_passages': attrPicked.length,
          'attr_json_first_try': tot == 0 ? null : ok / tot,
          ...totals.toJson(),
          'roster_json_valid': rosterN == 0 ? null : rosterValid / rosterN,
          'roster_recall': expected == 0 ? null : found / expected,
          'roster_invented_per_passage': rosterN == 0 ? null : invented / rosterN,
          'calls': calls,
          'prompt_tokens': promptTokens,
          'gen_tokens': genTokens,
          'prefill_tok_s': promptMs == 0 ? null : promptTokens / (promptMs / 1000),
          'gen_tok_s': genMs == 0 ? null : genTokens / (genMs / 1000),
          'wall_s': wall.elapsedMilliseconds / 1000,
          'sec_per_passage': wall.elapsedMilliseconds / 1000 / (attrPicked.length + rosterN * 0.5),
          'peak_rss_mb': peakRss,
          'min_avail_mb': minAvail,
        });
      } catch (e) {
        emit({'kind': 'model', 'id': id, 'status': 'run_failed', 'error': '$e'.split('\n').first});
      } finally {
        sampler.cancel();
        await compiler.dispose();
        try {
          await dst.delete();
        } catch (_) {}
      }
    }
    emit({'kind': 'done'});
  }, timeout: const Timeout(Duration(hours: 6)));
}

int _availMb() => _meminfo('MemAvailable:');
int _rssMb() => _status('VmHWM:');

int _meminfo(String key) {
  try {
    for (final line in File('/proc/meminfo').readAsLinesSync()) {
      if (line.startsWith(key)) return int.parse(line.split(RegExp(r'\s+'))[1]) ~/ 1024;
    }
  } catch (_) {}
  return -1;
}

int _status(String key) {
  try {
    for (final line in File('/proc/self/status').readAsLinesSync()) {
      if (line.startsWith(key)) return int.parse(line.split(RegExp(r'\s+'))[1]) ~/ 1024;
    }
  } catch (_) {}
  return -1;
}
