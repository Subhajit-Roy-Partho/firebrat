import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:path_provider/path_provider.dart';

/// Short NOVEL-mode (Kokoro, multi-voice by speaker detection) conversion on the phone.
/// Push `novel_short.epub` and then `novel_config.json` (e.g. {"threads":4}) into
///   /sdcard/Android/data/com.firebrat.firebrat_app.debug/files/e2e/
/// Prints `BENCH|{json}` lines and copies manifest + section audio to e2e/out_novel/.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('novel mode short text', (tester) async {
    final ext = (await getExternalStorageDirectory())!;
    final dir = '${ext.path}/e2e';
    for (var i = 0; i < 400 && !File('$dir/novel_config.json').existsSync(); i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    final config = jsonDecode(await File('$dir/novel_config.json').readAsString()) as Map;
    void emit(Map<String, Object?> row) => print('BENCH|${jsonEncode(row)}'); // ignore: avoid_print
    final support = (await getApplicationSupportDirectory()).path;
    final books = Directory('${Directory.systemTemp.path}/novel_books')..createSync(recursive: true);
    final settings = OnDeviceModeSettings(
      contentMode: BookContentMode.novel,
      researchCharacters: false,
      kokoroCpuThreads: (config['threads'] as num?)?.toInt() ?? 4,
      ttsModelId: (config['model'] ?? 'kokoro-int8').toString(),
    );
    final sw = Stopwatch()..start();
    final pipeline = MobileConversionPipeline(
      settings: settings,
      onProgress: (p) => emit({'kind': 'progress', 't_s': sw.elapsedMilliseconds ~/ 1000, 'stage': p.stage, 'detail': p.detail, 'f': p.fraction}),
    );
    final bookId = await pipeline.convert(pdfPaths: ['$dir/novel_short.epub'], booksRootDir: books.path, modelsDir: '$support/firebrat_models');
    final bookDir = '${books.path}/$bookId';
    final manifest = jsonDecode(await File('$bookDir/manifest.json').readAsString()) as Map<String, dynamic>;
    emit({'kind': 'result', 'total_s': sw.elapsedMilliseconds / 1000, 'audio_s': (manifest['total_duration_ms'] as int) / 1000, 'sections': (manifest['sections'] as List).length});
    final out = Directory('$dir/out_novel')..createSync(recursive: true);
    await File('$bookDir/manifest.json').copy('${out.path}/manifest.json');
    for (final s in Directory('$bookDir/sections').listSync().whereType<Directory>()) {
      final name = s.uri.pathSegments.where((p) => p.isNotEmpty).last;
      for (final f in s.listSync().whereType<File>()) {
        final base = f.uri.pathSegments.last;
        if (base.startsWith('audio') || base == 'segments.json') await f.copy('${out.path}/$name.$base');
      }
    }
    emit({'kind': 'done'});
  }, timeout: const Timeout(Duration(minutes: 40)));
}
