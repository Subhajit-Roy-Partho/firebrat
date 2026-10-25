// Development-only entry point. The normal app continues to use lib/main.dart.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mobile_backend_pipeline/src/extraction/ocr_fallback.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: ModelBenchmark()));
}

class ModelBenchmark extends StatefulWidget {
  const ModelBenchmark({super.key});
  @override
  State<ModelBenchmark> createState() => _ModelBenchmarkState();
}

class _ModelBenchmarkState extends State<ModelBenchmark> {
  String status = 'Ready for a configured offline model benchmark.';
  bool running = false;

  Future<void> run() async {
    setState(() => running = true);
    final support = await getApplicationSupportDirectory();
    final config = jsonDecode(await File('${support.path}/model_benchmark_config.json').readAsString()) as Map;
    final model = findOnDeviceLlmModel(config['model'] as String);
    final compiler = OnDeviceCompiler(model: model, gpuLayers: config['gpu_layers'] as int? ?? 0);
    final report = File('${support.path}/model_benchmark.json');
    final started = DateTime.now();
    final result = <String, dynamic>{
      'model': model.id, 'model_file': model.fileName,
      'model_bytes': model.approxSizeBytes, 'gpu_layers': compiler.gpuLayers,
      'started_utc': started.toUtc().toIso8601String(),
      'context': 4096, 'batch': 1536, 'microbatch': 128,
      'threads': 4, 'max_output_tokens': 2400, 'temperature': 0.2,
      'source': config['label'] ?? 'NASA 20160002392, Introduction excerpt', 'cloud': false, 'seed': 42,
    };
    Future<void> pending = Future.value();
    Future<void> write(String stage, [String? detail]) => pending = pending.then((_) async {
      result['stage'] = stage;
      result['detail'] = detail;
      result['elapsed_ms'] = DateTime.now().difference(started).inMilliseconds;
      final temp = File('${report.path}.tmp');
      await temp.writeAsString(jsonEncode(result));
      await temp.rename(report.path);
      if (mounted) setState(() => status = '$stage: ${detail ?? model.displayName}');
    });
    try {
      final extraction = await MobilePdfTextExtractor.extractPages(config['pdf_path'] as String? ?? '/data/local/tmp/firebrat-apollo.pdf');
      final page = extraction.pages[config['page_index'] as int? ?? 0];
      final start = page.text.indexOf(config['source_start'] as String? ?? 'Introduction:');
      if (start < 0) throw StateError('Benchmark introduction not found');
      var source = page.text.substring(start);
      final endMarker = config['source_end'] as String?;
      if (endMarker != null) {
        final end = source.indexOf(endMarker);
        if (end < 0) throw StateError('Benchmark end marker not found');
        source = source.substring(0, end).trim();
      }
      final maxChars = config['source_chars'] as int? ?? 900;
      if (source.length > maxChars) {
        source = source.substring(0, maxChars);
        final end = source.lastIndexOf('.');
        if (end >= 0) source = source.substring(0, end + 1);
      }
      final chunk = PageChunk(chunkIdx: 0, pages: [RawPage(pageIdx: 0, text: source)]);
      result['source_pages'] = chunk.pages.map((p) => p.pageIdx).toList();
      result['source_text'] = chunk.pages.map((p) => p.text).join('\n');
      await write('loading');
      final load = Stopwatch()..start();
      await compiler.ensureReady(modelsDir: '${support.path}/firebrat_models/llm',
        onProgress: (_, detail) { write('running', detail); });
      result['load_ms'] = load.elapsedMilliseconds;
      var formula = 0;
      final output = await compiler.compileChunk(chunk, nextFormulaNumber: () => ++formula);
      result['compiled'] = {'sections': output.sections.map((s) => {
        'title': s.title, 'source_pages': s.sourcePages,
        'segments': s.segments.map((x) => {'type': segmentKindToString(x.type),
          'text': x.text, 'latex': x.latex, 'ref': x.ref}).toList(),
      }).toList()};
      result['valid_json'] = true;
      result['nonempty_narration'] = output.sections.isNotEmpty &&
          output.sections.every((s) => s.segments.isNotEmpty && s.segments.every((x) => x.text.trim().isNotEmpty));
      await write('complete');
    } catch (error, stack) {
      result['error'] = error.toString();
      result['stack'] = stack.toString();
      result['valid_json'] = false;
      await write('error', error.toString());
    } finally {
      result['generation'] = compiler.lastGenerationStats;
      result['raw_response'] = compiler.lastRawResponse;
      await compiler.dispose();
      await write(result['stage'] as String, result['detail'] as String?);
      if (mounted) setState(() => running = false);
    }
  }

  Future<void> extractionDiagnostics() async {
    setState(() { running = true; status = 'Checking textbook text, OCR, and original visuals'; });
    final support = await getApplicationSupportDirectory();
    final results = <Map<String, dynamic>>[];
    try {
      for (final fixture in ['technical-example', 'technical-scanned']) {
        final watch = Stopwatch()..start();
        final path = '/data/local/tmp/firebrat-$fixture.pdf';
        final extracted = await MobilePdfTextExtractor.extractPages(path);
        final extractionMs = watch.elapsedMilliseconds;
        var pages = extracted.pages;
        var ocrMs = 0;
        if (extracted.ocrCandidatePageIndices.isNotEmpty) {
          final ocr = OcrFallback();
          final ocrWatch = Stopwatch()..start();
          try {
            pages = await ocr.reExtractPages(path, extracted.ocrCandidatePageIndices,
                '${support.path}/extraction_diagnostics/$fixture/ocr');
          } finally { ocr.dispose(); }
          ocrMs = ocrWatch.elapsedMilliseconds;
        }
        final visualWatch = Stopwatch()..start();
        final visuals = await PageVisuals.render(pdfPaths: [path],
            bookDir: '${support.path}/extraction_diagnostics/$fixture', pages: pages);
        final text = pages.map((p) => p.text).join('\n');
        results.add({'fixture': fixture, 'text': text, 'characters': text.length,
          'extraction_ms': extractionMs, 'ocr_ms': ocrMs,
          'visual_ms': visualWatch.elapsedMilliseconds, 'total_ms': watch.elapsedMilliseconds,
          'ocr_candidates': extracted.ocrCandidatePageIndices, 'visuals': visuals.length,
          'numeric_strings_present': {for (final n in ['1.02','0.69','2.84','3.15','3.84','1.35']) n: text.contains(n)}});
      }
      await File('${support.path}/extraction_benchmark.json').writeAsString(jsonEncode(results));
      setState(() => status = 'Text, scanned OCR, and source visuals checked. See extraction_benchmark.json.');
    } catch (error) { setState(() => status = 'Extraction check failed: $error'); }
    finally { if (mounted) setState(() => running = false); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Offline model benchmark')),
    body: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(children: [
      Text(status), const SizedBox(height: 24),
      FilledButton(onPressed: running ? null : run, child: const Text('Run configured model')),
      FilledButton(onPressed: running ? null : extractionDiagnostics, child: const Text('Check text, OCR and pictures')),
    ])),
  );
}
