import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';

/// Reads RAM, ABIs, Android version and the ONNX Runtime providers once.
/// Any failure yields [DeviceCapabilities.unknown], which the recommendation
/// logic treats as a low-end phone (safe defaults, no scary warnings).
Future<DeviceCapabilities> probeDeviceCapabilities() async {
  if (!Platform.isAndroid) return DeviceCapabilities.unknown;
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    Set<String> providers = const {};
    try {
      providers = {
        for (final p in await KokoroTtsEngine.availableAcceleration())
          p.toUpperCase(),
      };
    } catch (_) {}
    return DeviceCapabilities(
      totalRamMb: info.physicalRamSize > 0 ? info.physicalRamSize : null,
      supportedAbis: info.supportedAbis,
      androidSdk: info.version.sdkInt,
      ortProviders: providers,
    );
  } catch (_) {
    return DeviceCapabilities.unknown;
  }
}

final deviceCapabilitiesProvider = FutureProvider<DeviceCapabilities>(
  (ref) => probeDeviceCapabilities(),
);
