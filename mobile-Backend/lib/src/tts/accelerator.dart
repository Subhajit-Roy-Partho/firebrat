import '../models/device_capabilities.dart';
import '../models/model_tier.dart';
import '../models/tts_model_catalog.dart';

/// User-facing accelerator choice for speech synthesis.
enum AcceleratorPreference {
  /// Let the app decide (CPU unless the phone and model are a good NNAPI fit).
  auto('auto', 'Auto'),

  /// Ask for hardware acceleration (NNAPI: GPU / NPU / DSP where the driver
  /// supports the model's operators), falling back to CPU automatically.
  gpuNpu('gpuNpu', 'GPU / NPU'),

  /// Always CPU (the verified, most compatible path).
  cpu('cpu', 'CPU');

  final String storageValue;
  final String label;
  const AcceleratorPreference(this.storageValue, this.label);

  /// Parses stored/legacy values. Legacy `nnapi` meant "NNAPI (experimental)",
  /// legacy `cpu` meant CPU, a missing value was the old default (CPU, which
  /// is what [auto] resolves to for the default model).
  static AcceleratorPreference parse(String? raw) {
    switch (raw) {
      case 'gpuNpu':
      case 'nnapi':
      case 'gpu':
        return gpuNpu;
      case 'cpu':
        return cpu;
      case 'auto':
      default:
        return auto;
    }
  }
}

/// Ordered back ends to try for a model on a device; always ends with CPU.
List<AccelBackend> planAccelerators({
  required AcceleratorPreference preference,
  required DeviceCapabilities device,
  required OnDeviceTtsModel model,
}) {
  switch (preference) {
    case AcceleratorPreference.cpu:
      return const [AccelBackend.cpu];
    case AcceleratorPreference.auto:
      if (model.autoUsesNnapi &&
          device.nnapiUsable &&
          device.tier.index >= ModelTier.balanced.index) {
        return const [AccelBackend.nnapi, AccelBackend.cpu];
      }
      return const [AccelBackend.cpu];
    case AcceleratorPreference.gpuNpu:
      // Unknown provider list (probe failed): still try, the fallback is safe.
      final unknown = device.ortProviders.isEmpty;
      if (unknown || device.ortProviders.contains('NNAPI')) {
        return const [AccelBackend.nnapi, AccelBackend.cpu];
      }
      if (device.xnnpackUsable) {
        return const [AccelBackend.xnnpack, AccelBackend.cpu];
      }
      return const [AccelBackend.cpu];
  }
}

typedef SessionFactory<T> = Future<T> Function(AccelBackend backend);
typedef SessionCloser<T> = Future<void> Function(T session);

/// Owns an inference session created with automatic fallback:
/// - [open] tries each planned back end in order and keeps the first that loads;
/// - [run] retries once on the next back end (CPU last) if a run fails while
///   accelerated, so a flaky driver degrades to CPU instead of failing the book.
/// Pure Dart: the session type and factory are injected, so it is tested with
/// a fake runtime.
class AcceleratedSession<T> {
  final List<AccelBackend> plan;
  final SessionFactory<T> _create;
  final SessionCloser<T> _close;

  T? _session;
  AccelBackend? _active;
  final List<String> notes = [];
  int _planIndex = 0;
  bool _ranOnce = false;

  AcceleratedSession({
    required this.plan,
    required SessionFactory<T> create,
    required SessionCloser<T> close,
  }) : assert(plan.isNotEmpty),
       _create = create,
       _close = close;

  AccelBackend? get active => _active;
  AccelBackend get requested => plan.first;
  bool get fellBack => _active != null && _active != requested;
  bool get isOpen => _session != null;

  Future<void> open() async {
    Object? lastError;
    for (; _planIndex < plan.length; _planIndex++) {
      final backend = plan[_planIndex];
      try {
        _session = await _create(backend);
        _active = backend;
        return;
      } catch (e) {
        lastError = e;
        notes.add('${backend.label} unavailable: ${_short(e)}');
      }
    }
    throw StateError(
      'No inference back end could be opened. Last error: $lastError',
    );
  }

  Future<R> run<R>(Future<R> Function(T session) body) async {
    if (_session == null) await open();
    try {
      final r = await body(_session as T);
      _ranOnce = true;
      return r;
    } catch (e) {
      // Only an accelerated back end is retried; CPU errors are real errors.
      if (_active == AccelBackend.cpu || _planIndex + 1 >= plan.length) rethrow;
      notes.add(
        '${_active!.label} failed while running (${_short(e)}); switching to CPU',
      );
      final old = _session;
      _session = null;
      if (old != null) {
        try {
          await _close(old);
        } catch (_) {}
      }
      _planIndex++;
      await open();
      final r = await body(_session as T);
      _ranOnce = true;
      return r;
    }
  }

  Future<void> close() async {
    final s = _session;
    _session = null;
    if (s != null) await _close(s);
  }

  /// Text for "running on" status. Honest about NNAPI: the provider being
  /// attached does not prove every operator ran on the accelerator.
  String get statusLabel {
    final a = _active;
    if (a == null) return 'Not started';
    final base = switch (a) {
      AccelBackend.cpu => 'CPU',
      AccelBackend.nnapi =>
        'NNAPI (GPU/NPU where supported; other operations use CPU)',
      AccelBackend.xnnpack => 'XNNPACK (optimised CPU)',
      AccelBackend.vulkan => 'GPU (Vulkan)',
    };
    return fellBack ? '$base - fell back from ${requested.label}' : base;
  }

  bool get hasRun => _ranOnce;

  static String _short(Object e) {
    final s = e.toString().replaceAll('\n', ' ');
    return s.length > 140 ? '${s.substring(0, 140)}...' : s;
  }
}
