import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:path_provider/path_provider.dart';

/// End-to-end expressive conversion on the phone: EPUB -> on-device LLM casting
/// -> multi-voice narration -> package. Run it, then push (config LAST) into
///   /sdcard/Android/data/com.firebrat.firebrat_app.debug/files/e2e/
///     alice_excerpt.epub, models/CATALOG_FILE.gguf, piper/*.onnx(+.json) (or kokoro/ for engine kokoro),
///     e2e_config.json  {"llm":"qwen3-1.7b","engine":"piper","epub":"alice_excerpt.epub"}
/// Prints `BENCH|{json}` lines and copies the book to e2e/out/.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('expressive conversion end to end', (tester) async {
    final ext = (await getExternalStorageDirectory())!;
    final dir = '${ext.path}/e2e';
    for (var i = 0; i < 400 && !File('$dir/e2e_config.json').existsSync(); i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    final config = jsonDecode(await File('$dir/e2e_config.json').readAsString()) as Map;
    // ignore: avoid_print
    void emit(Map<String, Object?> row) => print('BENCH|${jsonEncode(row)}');

    final llmId = (config['llm'] ?? 'qwen3-1.7b').toString();
    final engine = (config['engine'] ?? 'piper').toString();
    final model = findOnDeviceLlmModel(llmId);
    final support = (await getApplicationSupportDirectory()).path;
    final docs = (await getApplicationDocumentsDirectory()).path;
    final modelsDir = '$support/firebrat_models';
    final llmDir = Directory('$modelsDir/llm')..createSync(recursive: true);
    final gguf = File('${llmDir.path}/${model.fileName}');
    if (!gguf.existsSync()) await File('$dir/models/${model.fileName}').copy(gguf.path);
    // speech assets: same layout the app's download writes
    final assets = ExpressiveAssets('$docs/kokoro');
    Future<void> place(String from, String to) async {
      final dst = File(to);
      if (dst.existsSync()) return;
      dst.parent.createSync(recursive: true);
      await File(from).copy(to);
    }

    final kokoroModel = findKokoroV1Model((config['kokoroModel'] ?? 'kokoro1-fp16').toString());
    if (engine == 'piper') {
      await place('$dir/piper/${kPiperLibrittsModel.fileName}', assets.piperModelPath);
      await place('$dir/piper/${kPiperLibrittsConfig.fileName}', assets.piperConfigPath);
    } else {
      await place('$dir/kokoro/${kokoroModel.file.fileName}', assets.kokoroModelPath(kokoroModel));
      if (kokoroModel.fp16) {
        final fb = findKokoroV1Model('kokoro1-fp32');
        if (File('$dir/kokoro/${fb.file.fileName}').existsSync()) await place('$dir/kokoro/${fb.file.fileName}', assets.kokoroModelPath(fb));
      }
      for (final v in kKokoroV1VoiceFiles) {
        await place('$dir/kokoro/voices/${v.fileName}', '${assets.kokoroVoicesDir}/${v.fileName}');
      }
    }
    final ramMb = int.parse(File('/proc/meminfo').readAsLinesSync().firstWhere((l) => l.startsWith('MemTotal:')).split(RegExp(r'\s+'))[1]) ~/ 1024;
    final books = Directory('${Directory.systemTemp.path}/e2e_books')..createSync(recursive: true);
    final settings = OnDeviceModeSettings(
      contentMode: BookContentMode.expressive,
      onDeviceLlmModelId: llmId,
      deviceRamMb: ramMb,
      expressiveEngine: engine,
      expressiveKokoroModelId: kokoroModel.id,
      kokoroCpuThreads: (config['threads'] as num?)?.toInt() ?? 4,
    );
    emit({'kind': 'start', 'llm': llmId, 'engine': engine, 'ram_mb': ramMb});
    final sw = Stopwatch()..start();
    final stages = <String, int>{};
    var lastStage = '';
    var stageStart = 0;
    final pipeline = MobileConversionPipeline(
      settings: settings,
      onProgress: (p) {
        if (p.stage != lastStage) {
          if (lastStage.isNotEmpty) stages[lastStage] = (stages[lastStage] ?? 0) + sw.elapsedMilliseconds - stageStart;
          lastStage = p.stage;
          stageStart = sw.elapsedMilliseconds;
        }
        emit({'kind': 'progress', 't_s': sw.elapsedMilliseconds ~/ 1000, 'stage': p.stage, 'detail': p.detail, 'f': p.fraction});
      },
    );
    final bookId = await pipeline.convert(
        pdfPaths: ['$dir/${config['epub'] ?? 'alice_excerpt.epub'}'], booksRootDir: books.path, modelsDir: modelsDir);
    sw.stop();
    stages[lastStage] = (stages[lastStage] ?? 0) + sw.elapsedMilliseconds - stageStart;
    final bookDir = '${books.path}/$bookId';
    final manifest = jsonDecode(await File('$bookDir/manifest.json').readAsString()) as Map<String, dynamic>;
    final cast = manifest['cast'] as Map?;
    final castFile = jsonDecode(await File('$bookDir/cast/cast.json').readAsString()) as Map<String, dynamic>;
    final audioMs = manifest['total_duration_ms'] as int;
    emit({
      'kind': 'result',
      'total_s': sw.elapsedMilliseconds / 1000,
      'stage_ms': stages,
      'audio_s': audioMs / 1000,
      'rtf_overall': sw.elapsedMilliseconds / audioMs,
      'cast_engine': cast?['engine'],
      'characters': cast?['characters'],
      'narrator': cast?['narrator'],
      'stats': castFile['stats'],
      'notes': castFile['notes'],
      'sections': (manifest['sections'] as List).length,
    });
    // copy the package out for inspection
    final out = Directory('$dir/out')..createSync(recursive: true);
    for (final f in [File('$bookDir/manifest.json'), File('$bookDir/character_roster.json'), File('$bookDir/cast/cast.json'), File('$bookDir/cast/voices.json')]) {
      await f.copy('${out.path}/${f.uri.pathSegments.last}');
    }
    for (final s in Directory('$bookDir/sections').listSync().whereType<Directory>().take(3)) {
      final name = s.uri.pathSegments.where((p) => p.isNotEmpty).last;
      await File('${s.path}/audio.wav').copy('${out.path}/$name.wav');
      await File('${s.path}/segments.json').copy('${out.path}/$name.segments.json');
    }
    expect(cast, isNotNull);
    expect((cast!['characters'] as List).length, greaterThan(1));
    expect(audioMs, greaterThan(10000));
    emit({'kind': 'done'});
  }, timeout: const Timeout(Duration(hours: 4)));
}
