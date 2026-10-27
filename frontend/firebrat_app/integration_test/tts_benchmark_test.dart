import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:path_provider/path_provider.dart';

/// On-device Kokoro / ONNX Runtime provider benchmark (CPU, XNNPACK, NNAPI).
///
/// Setup (debug app id shown; start the test first, it reinstalls the app, then push into the
/// app's external files dir, no permission needed, bench_config.json LAST):
///   adb push MODELS voices/ bench_config.json \
///     /sdcard/Android/data/com.firebrat.firebrat_app.debug/files/kokoro_bench/
///   flutter test integration_test/tts_benchmark_test.dart -d SERIAL | grep BENCH
/// Results are printed as `BENCH|{json}` lines; wavs land in kokoro_bench/out/.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Kokoro provider benchmark', (tester) async {
    final ext = await getExternalStorageDirectory();
    final dir = '${ext!.path}/kokoro_bench';
    // `flutter test` reinstalls the app (wiping its external files), so wait
    // for the files to be pushed AFTER the install. bench_config.json goes last.
    for (var i = 0; i < 300 && !File('$dir/bench_config.json').existsSync(); i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    expect(File('$dir/bench_config.json').existsSync(), isTrue, reason: 'push bench_config.json to $dir');
    await Future<void>.delayed(const Duration(seconds: 2));
    final rows = await runKokoroBenchmark(dir);
    await File('$dir/out/results.jsonl').writeAsString(rows.map((r) => r.toString()).join('\n'));
    expect(rows, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 40)));
}
