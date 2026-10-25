import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether Android lets Firebrat run without battery optimization ("Unrestricted").
/// A long conversion runs in a foreground service, but many phones still pause
/// or kill apps under battery optimization once the screen turns off, so the
/// Conversions screen warns when this is false. Anything we cannot check
/// (non-Android, tests, a plugin error) counts as fine, so nobody is nagged
/// over something we can't verify.
final batteryUnrestrictedProvider = FutureProvider.autoDispose<bool>((ref) async {
  if (!Platform.isAndroid) return true;
  try {
    return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
  } catch (_) {
    return true;
  }
});

/// Opens Android's "Battery optimization" list so the user can allow Firebrat.
/// This deliberately does not use the REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
/// permission (a Play-restricted permission); the settings page needs none.
Future<void> openBatterySettings() async {
  try {
    await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
  } catch (_) {}
}
