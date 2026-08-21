import 'package:flutter/material.dart';

/// Modern Material 3 theme. Generous contrast and spacing throughout —
/// Firebrat's on-screen text is meant to be a light companion to the audio,
/// not something you have to squint through, which matters most for readers
/// who find sustained silent reading difficult.
class AppTheme {
  static const seedColor = Color(0xFF4F6BFF);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.light);
    return _base(scheme);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark);
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: const TextTheme(
        headlineSmall: TextStyle(fontWeight: FontWeight.w700, height: 1.3),
        titleLarge: TextStyle(fontWeight: FontWeight.w600, height: 1.3),
        titleMedium: TextStyle(fontWeight: FontWeight.w600, height: 1.35),
        bodyLarge: TextStyle(height: 1.55, fontSize: 17),
        bodyMedium: TextStyle(height: 1.5, fontSize: 15),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surface,
        elevation: 0,
        centerTitle: false,
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      ),
    );
  }

  /// Responsive breakpoint: phone vs larger (tablet/desktop) layouts.
  static bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 720;
}
