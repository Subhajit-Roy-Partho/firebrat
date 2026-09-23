import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart' show ServiceRequestFailure;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:path_provider/path_provider.dart';
import 'library_providers.dart';
import 'on_device_conversion_providers.dart';

/// Live state of the current (if any) on-device conversion — there is no
/// server job to poll for this path, so this is its own tiny piece of
/// state instead of going through `state/conversions_providers.dart`'s
/// server-backed `jobsProvider`.
class OnDeviceRunState {
  final String? stage;
  final String? detail;
  final double? fraction;
  final String? error;
  final bool done;

  const OnDeviceRunState({this.stage, this.detail, this.fraction, this.error, this.done = false});
}

class OnDeviceRunNotifier extends Notifier<OnDeviceRunState?> {
  @override
  OnDeviceRunState? build() => null;

  void set(OnDeviceRunState? s) => state = s;
}

final onDeviceRunProvider = NotifierProvider<OnDeviceRunNotifier, OnDeviceRunState?>(OnDeviceRunNotifier.new);

/// Runs one on-device conversion as a background task with a persistent
/// notification (`mobile_backend_pipeline`'s `BackgroundConversionRunner`
/// — see its doc comment: this is what lets the conversion keep running
/// if the user backgrounds the app or swipes it out of recents, not just
/// while it stays in the foreground). Reports progress into
/// [onDeviceRunProvider] and invalidates the local library on success so
/// the finished book shows up without a manual refresh — the same
/// convention `state/conversions_providers.dart`'s `JobsNotifier` uses for
/// cloud jobs finishing.
///
/// [pdfPaths] is one PDF, or a zipped book's chapters in reading order
/// (see [unpackZipChapters]) — the pipeline merges them at the text layer,
/// so no on-device PDF merge library is needed (none mature exists for
/// pure-Dart; the pipeline only ever reads the text layer anyway).
Future<String> runOnDeviceConversion(WidgetRef ref, List<String> pdfPaths,
    {String? titleOverride}) async {
  if (pdfPaths.isEmpty) {
    throw ArgumentError('runOnDeviceConversion needs at least one PDF');
  }
  final settings = ref.read(conversionModeProvider);
  if (!settings.isOnDeviceConfigured) {
    throw StateError('On-device LLM url/api key/model are not configured — see Conversion settings.');
  }
  final notifier = ref.read(onDeviceRunProvider.notifier);
  notifier.set(const OnDeviceRunState(stage: 'starting', detail: 'preparing'));

  await BackgroundConversionRunner.requestPermissions();
  final booksDir = await ref.read(downloadManagerProvider).booksDir();

  final completer = Completer<String>();
  late final void Function(Object data) listener;
  listener = (Object data) {
    if (data is! Map) return;
    if (data['error'] != null) {
      final error = data['error'].toString();
      notifier.set(OnDeviceRunState(error: error, done: true));
      BackgroundConversionRunner.removeProgressListener(listener);
      if (!completer.isCompleted) completer.completeError(StateError(error));
      return;
    }
    if (data['done'] == true) {
      notifier.set(const OnDeviceRunState(stage: 'done', detail: 'complete', fraction: 1.0, done: true));
      invalidateLibrary(ref);
      BackgroundConversionRunner.removeProgressListener(listener);
      if (!completer.isCompleted) completer.complete(data['bookId'] as String);
      return;
    }
    notifier.set(OnDeviceRunState(
      stage: data['stage'] as String?,
      detail: data['detail'] as String?,
      fraction: (data['fraction'] as num?)?.toDouble(),
    ));
  };
  BackgroundConversionRunner.addProgressListener(listener);

  final request = ConversionRequest(
    pdfPath: pdfPaths.first,
    pdfPaths: pdfPaths.length > 1 ? pdfPaths : null,
    booksRootDir: booksDir.path,
    titleOverride: titleOverride,
    // Stable app-storage dir (not temp) so multi-GB GGUF/ONNX weights
    // survive across conversions — see MobileConversionPipeline.convert.
    modelsDir: '${(await getApplicationSupportDirectory()).path}/firebrat_models',
    llmBaseUrl: settings.onDeviceLlmUrl,
    llmApiKey: settings.onDeviceLlmApiKey,
    llmModel: settings.onDeviceLlmModel,
    // Local model / voice choices from "On-device models & voice" —
    // previously hardcoded defaults, which is why the catalog and Kokoro
    // existed in the pipeline but were unreachable from the app.
    onDeviceLlmModelId: settings.onDeviceLlmModelId,
    onDeviceGpuLayers: settings.onDeviceGpuLayers,
    voiceEngine: settings.voiceEngine,
    kokoroVoice: settings.kokoroVoice,
  );
  final result = await BackgroundConversionRunner.start(request);
  if (result is ServiceRequestFailure) {
    BackgroundConversionRunner.removeProgressListener(listener);
    final error = result.error.toString();
    notifier.set(OnDeviceRunState(error: error, done: true));
    throw StateError('Could not start the background conversion service: $error');
  }

  return completer.future;
}

/// Unpacks a zipped book (one PDF per chapter) into a temp dir and returns
/// the chapter PDFs sorted by archive path — the order the pipeline merges
/// them in. Throws [StateError] when the zip holds no PDFs. Temp files
/// live under the system temp dir; the pipeline copies what it needs into
/// the book package, so leftovers are harmless (OS-managed temp).
Future<List<String>> unpackZipChapters(String zipPath) async {
  final bytes = await File(zipPath).readAsBytes();
  late final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw StateError('Could not read "$zipPath" as a .zip file.');
  }
  final pdfNames = archive.files
      .where((f) => f.isFile && f.name.toLowerCase().endsWith('.pdf'))
      .map((f) => f.name)
      .toList()
    ..sort();
  if (pdfNames.isEmpty) {
    throw StateError('Zip contains no .pdf files — add at least one chapter PDF.');
  }
  final dir = await Directory(
          '${(await getTemporaryDirectory()).path}/firebrat_chapters_${DateTime.now().millisecondsSinceEpoch}')
      .create(recursive: true);
  final out = <String>[];
  for (final name in pdfNames) {
    final file = archive.files.firstWhere((f) => f.name == name);
    // Flatten subfolders; disambiguate repeat basenames (ch1/a.pdf, ch2/a.pdf).
    var target = '${dir.path}/${name.split('/').last}';
    var k = 2;
    while (await File(target).exists()) {
      final base = name.split('/').last.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
      target = '${dir.path}/$base-$k.pdf';
      k++;
    }
    await File(target).writeAsBytes(file.content as List<int>);
    out.add(target);
  }
  return out;
}
