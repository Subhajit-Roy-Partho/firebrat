import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Playback + reading settings, persisted locally. Font size and line
/// spacing matter a lot here — Firebrat is built with dyslexic readers in
/// mind (long, dense technical text is exhausting to read on the page;
/// the whole point of this app is to make listening the primary path and
/// keep on-screen text short, high-contrast, and adjustable).
class ReaderSettings {
  final double playbackSpeed; // 0.75 - 2.0
  final bool autoplayEnabled;
  final int autoplayDelaySeconds; // delay after a segment/section finishes
  final double fontScale; // 0.85 - 1.6, applied on top of theme text sizes

  const ReaderSettings({
    this.playbackSpeed = 1.0,
    this.autoplayEnabled = true,
    this.autoplayDelaySeconds = 1,
    this.fontScale = 1.15,
  });

  ReaderSettings copyWith({
    double? playbackSpeed,
    bool? autoplayEnabled,
    int? autoplayDelaySeconds,
    double? fontScale,
  }) =>
      ReaderSettings(
        playbackSpeed: playbackSpeed ?? this.playbackSpeed,
        autoplayEnabled: autoplayEnabled ?? this.autoplayEnabled,
        autoplayDelaySeconds: autoplayDelaySeconds ?? this.autoplayDelaySeconds,
        fontScale: fontScale ?? this.fontScale,
      );
}

class ReaderSettingsNotifier extends Notifier<ReaderSettings> {
  static const _kSpeed = 'reader.playbackSpeed';
  static const _kAutoplay = 'reader.autoplayEnabled';
  static const _kDelay = 'reader.autoplayDelaySeconds';
  static const _kFontScale = 'reader.fontScale';

  @override
  ReaderSettings build() {
    _load();
    return const ReaderSettings();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = ReaderSettings(
      playbackSpeed: prefs.getDouble(_kSpeed) ?? 1.0,
      autoplayEnabled: prefs.getBool(_kAutoplay) ?? true,
      autoplayDelaySeconds: prefs.getInt(_kDelay) ?? 1,
      fontScale: prefs.getDouble(_kFontScale) ?? 1.15,
    );
  }

  Future<void> setPlaybackSpeed(double v) async {
    state = state.copyWith(playbackSpeed: v);
    (await SharedPreferences.getInstance()).setDouble(_kSpeed, v);
  }

  Future<void> setAutoplayEnabled(bool v) async {
    state = state.copyWith(autoplayEnabled: v);
    (await SharedPreferences.getInstance()).setBool(_kAutoplay, v);
  }

  Future<void> setAutoplayDelaySeconds(int v) async {
    state = state.copyWith(autoplayDelaySeconds: v);
    (await SharedPreferences.getInstance()).setInt(_kDelay, v);
  }

  Future<void> setFontScale(double v) async {
    state = state.copyWith(fontScale: v);
    (await SharedPreferences.getInstance()).setDouble(_kFontScale, v);
  }
}

final readerSettingsProvider =
    NotifierProvider<ReaderSettingsNotifier, ReaderSettings>(ReaderSettingsNotifier.new);
