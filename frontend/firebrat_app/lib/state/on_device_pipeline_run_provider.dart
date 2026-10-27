import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart' show ServiceRequestFailure;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:path_provider/path_provider.dart';
import '../services/app_network_gate.dart';
import '../services/device_probe.dart';
import 'library_providers.dart';
import 'on_device_conversion_providers.dart';

/// Live state of the current (if any) on-device conversion — there is no
/// server job to poll for this path, so this is its own tiny piece of
/// state instead of going through `state/conversions_providers.dart`'s
/// server-backed `jobsProvider`.
/// One line of the conversion's activity log.
class RunEvent {
  final DateTime at;
  final String stage;
  final String detail;
  const RunEvent(this.at, this.stage, this.detail);
}

class OnDeviceRunState {
  final String? stage;
  final String? detail;
  final double? fraction;
  final String? error;
  final bool done;

  /// What happened so far (newest last), kept for the book's detail screen.
  final List<RunEvent> events;
  final DateTime? startedAt;

  const OnDeviceRunState({
    this.stage,
    this.detail,
    this.fraction,
    this.error,
    this.done = false,
    this.events = const [],
    this.startedAt,
  });

  /// The next state after a progress report, extending the activity log
  /// (only when the message changed, capped so a long book stays small).
  OnDeviceRunState next({String? stage, String? detail, double? fraction, String? error, bool done = false}) {
    final last = events.isEmpty ? null : events.last;
    final changed = stage != null && detail != null && (last == null || last.stage != stage || last.detail != detail);
    final log = changed ? [...events, RunEvent(DateTime.now(), stage, detail)] : events;
    return OnDeviceRunState(
      stage: stage ?? this.stage,
      detail: detail ?? this.detail,
      fraction: fraction ?? this.fraction,
      error: error,
      done: done,
      events: log.length > 120 ? log.sublist(log.length - 120) : log,
      startedAt: startedAt ?? DateTime.now(),
    );
  }
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
    {String? titleOverride}) {
  // The conversion outlives its screen. Do not retain its WidgetRef in a
  // completion callback: navigating back would prevent the library refresh.
  final container = ProviderScope.containerOf(ref.context, listen: false);
  return runOnDeviceConversionIn(container, pdfPaths, titleOverride: titleOverride);
}

/// How many sections are narrated, from a "N/M sections" progress line.
int? _sectionsReady(String? stage, String? detail) {
  if (stage != 'synthesizing' || detail == null) return null;
  final m = RegExp(r'^(\d+)/\d+ sections').firstMatch(detail);
  return m == null ? null : int.parse(m.group(1)!);
}

/// Thrown by the running conversion's future when the user stops it.
class ConversionCancelled implements Exception {
  @override
  String toString() => 'Conversion stopped.';
}

/// Cancels the conversion started by [runOnDeviceConversionIn], if any: ends the
/// background service, removes what it had written so far (only if the book was
/// never completed, and not when [keepProgress] is set for a pause), and makes
/// the running future throw [ConversionCancelled].
Future<void> cancelOnDeviceConversion(ProviderContainer container, {bool keepProgress = false}) async {
  final active = _active;
  await BackgroundConversionRunner.cancel();
  if (active != null) {
    // Pausing keeps everything written so far; the next run resumes from it.
    if (!keepProgress) await _removePartialBook(active.request);
    active.cancel();
  }
  container.read(onDeviceRunProvider.notifier).set(null);
}

class _ActiveRun {
  final ConversionRequest request;
  final void Function() cancel;
  _ActiveRun(this.request, this.cancel);
}

_ActiveRun? _active;

Future<void> _removePartialBook(ConversionRequest request) async {
  try {
    final dir = Directory('${request.booksRootDir}/${request.bookId}');
    // Never delete a finished book that is merely being re-converted.
    if (await dir.exists() && !await File('${dir.path}/manifest.json').exists()) {
      await dir.delete(recursive: true);
    }
  } catch (_) {}
}

/// Bytes of on-device model files this conversion would still download.
Future<int> _missingModelBytes(ConversionModeSettings settings) async {
  var total = 0;
  try {
    final base = '${(await getApplicationSupportDirectory()).path}/firebrat_models';
    final expressive = settings.contentMode == 'expressive';
    final needsLlm = expressive || (settings.contentMode != 'novel' && !(settings.allowCloudFallback && settings.cloudForAll));
    if (needsLlm) {
      final m = findOnDeviceLlmModel(settings.onDeviceLlmModelId);
      final f = File('$base/llm/${m.fileName}');
      final ok = await f.exists() && ((await f.length()) - m.approxSizeBytes).abs() < m.approxSizeBytes * 0.02;
      if (!ok) total += m.approxSizeBytes;
    }
    if (expressive) {
      final assets = await ExpressiveAssets.forApp();
      total += await assets.missingBytes(
          ExpressiveEngine.parse(settings.expressiveEngine), findKokoroV1Model(settings.expressiveKokoroModelId));
    } else if (settings.isKokoroVoice) {
      if (!await KokoroTtsEngine.isDownloaded()) total += 110 * 1024 * 1024;
      total += await KokoroAssets.missingBytes(findTtsModel(settings.ttsModelId));
    }
  } catch (_) {}
  return total;
}

/// Same as [runOnDeviceConversion] but driven by a container, so it can run
/// from the queue without any screen being open.
Future<String> runOnDeviceConversionIn(ProviderContainer container, List<String> pdfPaths,
    {String? titleOverride}) async {
  if (pdfPaths.isEmpty) {
    throw ArgumentError('runOnDeviceConversion needs at least one PDF');
  }
  final settings = container.read(conversionModeProvider);
  if (!settings.isOnDeviceConfigured) {
    throw StateError('On-device LLM url/api key/model are not configured — see Conversion settings.');
  }
  final notifier = container.read(onDeviceRunProvider.notifier);
  notifier.set(OnDeviceRunState(stage: 'starting', detail: 'preparing', startedAt: DateTime.now()));

  // Models the conversion would download on its own: hold them to the
  // "Download over" rule BEFORE the background service starts (it shows
  // "Waiting for Wi-Fi" instead of failing, and starts when allowed).
  final missing = await _missingModelBytes(settings);
  if (missing > 0) {
    await AppNetworkGate.instance.waitUntilAllowed(missing, onWaiting: (label) {
      final prev = container.read(onDeviceRunProvider) ?? const OnDeviceRunState();
      notifier.set(prev.next(stage: 'starting', detail: label ?? 'preparing'));
    });
  }
  final device = await probeDeviceCapabilities();

  await BackgroundConversionRunner.requestPermissions();
  final booksDir = await container.read(downloadManagerProvider).booksDir();

  final completer = Completer<String>();
  var lastReady = -1;
  late final void Function(Object data) listener;
  listener = (Object data) {
    if (data is! Map) return;
    final prev = container.read(onDeviceRunProvider) ?? const OnDeviceRunState();
    if (data['error'] != null) {
      final error = data['error'].toString();
      notifier.set(prev.next(error: error, done: true));
      BackgroundConversionRunner.removeProgressListener(listener);
      if (!completer.isCompleted) completer.completeError(StateError(error));
      return;
    }
    if (data['done'] == true) {
      notifier.set(prev.next(stage: 'done', detail: 'complete', fraction: 1.0, done: true));
      container.invalidate(localBooksProvider);
      container.invalidate(catalogProvider);
      BackgroundConversionRunner.removeProgressListener(listener);
      if (!completer.isCompleted) completer.complete(data['bookId'] as String);
      return;
    }
    final detail = data['detail'] as String?;
    notifier.set(prev.next(
      stage: data['stage'] as String?,
      detail: detail,
      fraction: (data['fraction'] as num?)?.toDouble(),
    ));
    // Each narrated section is playable at once: show it in the library as it lands.
    final ready = _sectionsReady(data['stage'] as String?, detail);
    if (ready != null && ready != lastReady) {
      lastReady = ready;
      container.invalidate(localBooksProvider);
    }
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
    contentMode: settings.contentMode,
    allowCloudFallback: settings.allowCloudFallback,
    cloudForAll: settings.cloudForAll,
    researchCharacters: settings.researchCharacters,
        localCharacterResearch: settings.localCharacterResearch,
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
        kokoroAcceleration: settings.kokoroAcceleration,
        ttsModelId: settings.ttsModelId,
        deviceRamMb: device.totalRamMb,
        androidSdk: device.androidSdk,
        kokoroCpuThreads: settings.kokoroCpuThreads,
        maleVoice: settings.maleVoice, femaleVoice: settings.femaleVoice, characterVoices: settings.characterVoices,
    expressiveEngine: settings.expressiveEngine,
    expressiveKokoroModelId: settings.expressiveKokoroModelId,
    expressiveNarratorVoice: settings.expressiveNarratorVoice,
  );
  final result = await BackgroundConversionRunner.start(request);
  if (result is ServiceRequestFailure) {
    BackgroundConversionRunner.removeProgressListener(listener);
    final error = result.error.toString();
    notifier.set((container.read(onDeviceRunProvider) ?? const OnDeviceRunState()).next(error: error, done: true));
    throw StateError('Could not start the background conversion service: $error');
  }

  _active = _ActiveRun(request, () {
    BackgroundConversionRunner.removeProgressListener(listener);
    if (!completer.isCompleted) completer.completeError(ConversionCancelled());
  });
  try {
    return await completer.future;
  } finally {
    _active = null;
  }
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
