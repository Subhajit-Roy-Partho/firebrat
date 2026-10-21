import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  BackgroundConversionRunner.initialize();
  runApp(const MaterialApp(home: Probe()));
}
class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}
class _ProbeState extends State<Probe> {
  String status = 'Ready: Qwen3 1.7B, local CPU inference, no cloud credentials. Turn networking off, then start.';
  bool running = false;
  Future<void> run({bool novel = false}) async {
    setState(() => running = true);
    final support = await getApplicationSupportDirectory();
    final docs = await getApplicationDocumentsDirectory();
    final configFile = File('${support.path}/local_conversion_probe_config.json');
    final config = await configFile.exists() ? jsonDecode(await configFile.readAsString()) as Map : {};
    final report = File('${support.path}/local_conversion_probe.json');
    final started = DateTime.now();
    Future<void> pendingLog = Future.value();
    Future<void> log(Map<String, dynamic> data) {
      return pendingLog = pendingLog.then((_) async {
      final temp = File('${report.path}.tmp');
      await temp.writeAsString(jsonEncode({...data, 'elapsed_seconds': DateTime.now().difference(started).inSeconds}));
      await temp.rename(report.path);
      });
    }
    try {
      await BackgroundConversionRunner.requestPermissions();
      final done = Completer<String>();
      void listener(Object data) {
        if (data is! Map) return;
        if (data['error'] != null) {
          if (!done.isCompleted) done.completeError(StateError(data['error'].toString()));
        } else if (data['done'] == true) {
          if (!done.isCompleted) done.complete(data['bookId'] as String);
        } else {
          final message = '${data['stage']}: ${data['detail']}';
          debugPrint('LOCAL_PROBE $message');
          if (mounted) setState(() => status = message);
          log(Map<String, dynamic>.from(data));
        }
      }
      BackgroundConversionRunner.addProgressListener(listener);
      late final String id;
      try {
        await BackgroundConversionRunner.start(ConversionRequest(
          pdfPath: config['pdf_path'] as String? ?? (novel ? '/data/local/tmp/firebrat-novel.pdf' : '/data/local/tmp/firebrat-apollo.pdf'),
          booksRootDir: '${docs.path}/books', modelsDir: '${support.path}/firebrat_models',
          titleOverride: config['title'] as String? ?? (novel ? 'Offline Novel Voice Test' : 'Apollo Offline Test'),
          voiceEngine: config['voice_engine'] as String? ?? 'stockTts',
          kokoroVoice: config['kokoro_voice'] as String? ?? 'Bella',
          maleVoice: config['male_voice'] as String? ?? 'Adam',
          femaleVoice: config['female_voice'] as String? ?? 'Sarah',
          characterVoices: Map<String, String>.from(config['character_voices'] as Map? ?? {}),
          contentMode: novel ? 'novel' : 'illustrated', llmBaseUrl: '', llmApiKey: '', llmModel: '',
          onDeviceGpuLayers: config['gpu_layers'] as int? ?? 0, onDeviceLlmModelId: config['model'] as String? ?? 'qwen3-1.7b',
        ));
        id = await done.future;
      } finally { BackgroundConversionRunner.removeProgressListener(listener); }
      final root = '${docs.path}/books/$id';
      final manifest = jsonDecode(await File('$root/manifest.json').readAsString()) as Map<String, dynamic>;
      var voicedBytes = 0;
      for (final section in manifest['sections'] as List) {
        final wav = WavAudio.parse(await File('$root/${section['audio_path']}').readAsBytes());
        if (wav.durationMs < 1000 || !wav.pcmData.any((b) => b != 0)) throw StateError('Silent or incomplete narration');
        voicedBytes += wav.pcmData.length;
      }
      await log({'stage': 'verified', 'book_id': id, 'sections': (manifest['sections'] as List).length,
        'figures': (manifest['figures'] as List).length, 'duration_ms': manifest['total_duration_ms'],
        'non_silent_audio_bytes': voicedBytes, 'cloud_fallback': false});
      if (novel) {
        final roster = jsonDecode(await File('$root/character_roster.json').readAsString()) as Map;
        if ((roster['characters'] as List).length != 2) throw StateError('Expected two named characters');
      }
      if (mounted) setState(() => status = 'Verified offline conversion: $id. See local_conversion_probe.json.');
    } catch (e, st) {
      await log({'stage': 'error', 'error': e.toString(), 'stack': st.toString()});
      debugPrint('LOCAL_PROBE ERROR $e\n$st');
      if (mounted) setState(() => status = 'Failed: $e');
    } finally { if (mounted) setState(() => running = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Local conversion test')),
    body: Padding(padding: const EdgeInsets.all(24), child: Column(children: [Text(status),
      const SizedBox(height: 24), FilledButton(onPressed: running ? null : () => run(), child: const Text('Start offline test')),
      FilledButton(onPressed: running ? null : () => run(novel: true), child: const Text('Test novel voices'))])));
}
