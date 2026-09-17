import 'dart:async';
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
Future<String> runOnDeviceConversion(WidgetRef ref, String pdfPath) async {
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
    pdfPath: pdfPath,
    booksRootDir: booksDir.path,
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
