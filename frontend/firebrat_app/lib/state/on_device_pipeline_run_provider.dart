import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
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

/// Runs one on-device conversion end to end, reporting progress into
/// [onDeviceRunProvider] and invalidating the local library on success so
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

  final booksDir = await ref.read(downloadManagerProvider).booksDir();
  final pipeline = MobileConversionPipeline(
    settings: OnDeviceModeSettings(
      llmBaseUrl: settings.onDeviceLlmUrl,
      llmApiKey: settings.onDeviceLlmApiKey,
      llmModel: settings.onDeviceLlmModel,
    ),
    onProgress: (p) => notifier.set(OnDeviceRunState(stage: p.stage, detail: p.detail, fraction: p.fraction)),
  );

  try {
    final bookId = await pipeline.convert(pdfPath: pdfPath, booksRootDir: booksDir.path);
    notifier.set(const OnDeviceRunState(stage: 'done', detail: 'complete', fraction: 1.0, done: true));
    invalidateLibrary(ref);
    return bookId;
  } catch (e) {
    notifier.set(OnDeviceRunState(error: e.toString(), done: true));
    rethrow;
  }
}
