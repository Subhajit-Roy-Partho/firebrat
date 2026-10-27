import 'model_tier.dart';

/// What the phone can do, probed by the host app (device_info_plus + ONNX
/// Runtime) and consumed by pure logic below so it is testable without a device.
class DeviceCapabilities {
  /// Total RAM in MB; null when unknown (treated as a low-end phone).
  final int? totalRamMb;
  final List<String> supportedAbis;
  final int? androidSdk;

  /// ONNX Runtime providers reported by the runtime, upper-case
  /// (e.g. `NNAPI`, `XNNPACK`, `CPU`). Empty when unknown.
  final Set<String> ortProviders;

  const DeviceCapabilities({
    this.totalRamMb,
    this.supportedAbis = const [],
    this.androidSdk,
    this.ortProviders = const {},
  });

  static const unknown = DeviceCapabilities();

  double? get totalRamGb => totalRamMb == null ? null : totalRamMb! / 1024;

  bool get is64Bit => supportedAbis.any((a) => a.contains('64'));

  /// Android reports total RAM slightly under the marketed size (an "8 GB"
  /// phone shows ~7.4 GB), so tiers use marketed-size boundaries with slack.
  ModelTier get tier {
    final gb = totalRamGb;
    if (gb == null || gb < 4.5) return ModelTier.light;
    if (gb < 7.2) return ModelTier.balanced;
    if (gb < 11) return ModelTier.powerful;
    return ModelTier.desktopClass;
  }

  /// NNAPI needs Android 10+ to be worth trying (8.1 technically works).
  bool get nnapiUsable =>
      ortProviders.contains('NNAPI') && (androidSdk ?? 0) >= 29;
  bool get xnnpackUsable => ortProviders.contains('XNNPACK');

  String get summary {
    final ram = totalRamGb == null
        ? 'unknown RAM'
        : '${totalRamGb!.toStringAsFixed(1)} GB RAM';
    final api = androidSdk == null ? '' : ', Android API $androidSdk';
    return '$ram$api, ${tier.label} class';
  }

  /// Back ends the TTS runtime could use on this phone.
  List<AccelBackend> get ttsBackends => [
    AccelBackend.cpu,
    if (xnnpackUsable) AccelBackend.xnnpack,
    if (nnapiUsable) AccelBackend.nnapi,
  ];
}

/// How well a model matches the phone.
enum ModelFit { good, tight, tooLarge }

class FitAssessment {
  final ModelFit fit;
  final String? warning;
  const FitAssessment(this.fit, this.warning);
}

/// Compares a model's RAM need with the phone. Pure function.
FitAssessment assessFit({
  required String name,
  required double minDeviceRamGb,
  required DeviceCapabilities device,
}) {
  final have = device.totalRamGb;
  if (have == null) {
    return minDeviceRamGb <= 4
        ? const FitAssessment(ModelFit.good, null)
        : FitAssessment(
            ModelFit.tight,
            "$name needs about ${_g(minDeviceRamGb)} GB RAM and this phone's RAM could not be read.",
          );
  }
  if (have >= minDeviceRamGb * 0.93) {
    return const FitAssessment(ModelFit.good, null);
  }
  if (have >= minDeviceRamGb * 0.75) {
    return FitAssessment(
      ModelFit.tight,
      '$name needs about ${_g(minDeviceRamGb)} GB RAM and this phone has ${_g(have)} GB. '
      'It may run slowly or be closed by Android; the default model is safer.',
    );
  }
  return FitAssessment(
    ModelFit.tooLarge,
    '$name needs about ${_g(minDeviceRamGb)} GB RAM but this phone has ${_g(have)} GB. '
    'It will very likely fail; choose a smaller model.',
  );
}

String _g(double v) => v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);
