import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Modern Material 3 theme. Generous contrast and spacing throughout —
/// Firebrat's on-screen text is meant to be a light companion to the audio,
/// not something you have to squint through, which matters most for readers
/// who find sustained silent reading difficult.
class AppTheme {
  static const seedColor = Color(0xFF5B45E0);
  static const accent = Color(0xFFFFB547);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.light)
        .copyWith(tertiary: const Color(0xFFB86E00), tertiaryContainer: const Color(0xFFFFDDB0));
    return _base(scheme);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark)
        .copyWith(tertiary: accent, tertiaryContainer: const Color(0xFF5A3A00));
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: const TextTheme(
        headlineSmall: TextStyle(fontWeight: FontWeight.w800, height: 1.25, letterSpacing: -.3),
        titleLarge: TextStyle(fontWeight: FontWeight.w600, height: 1.3),
        titleMedium: TextStyle(fontWeight: FontWeight.w600, height: 1.35),
        bodyLarge: TextStyle(height: 1.55, fontSize: 17),
        bodyMedium: TextStyle(height: 1.5, fontSize: 15),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -.3,
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
    );
  }

  /// Responsive breakpoint: phone vs larger (tablet/desktop) layouts.
  static bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 720;
}
