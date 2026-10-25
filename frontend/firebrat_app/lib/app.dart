import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/analytics_service.dart';
import '../services/auth_service.dart';
import 'screens/library_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/tour_screen.dart';
import 'state/theme_providers.dart';
import 'state/tour_providers.dart';
import 'state/on_device_conversion_providers.dart';
import 'state/guest_access_provider.dart';
import 'theme/app_theme.dart';

class FirebratApp extends ConsumerWidget {
  const FirebratApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Firebrat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      // Automatic screen-view tracking (screen names only, no content).
      navigatorObservers: ref.watch(conversionModeProvider).mode != ConversionModePref.cloud
          ? const [] : AnalyticsService.observerOrNull(),
      home: const AuthGate(),
    );
  }
}

/// Local modes and explicit guests can use the library without an account.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(guestAccessProvider) ||
        ref.watch(conversionModeProvider).mode != ConversionModePref.cloud) {
      return const _Home();
    }
    return StreamBuilder<User?>(
      stream: AuthService.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasData) return const _Home();
        return SignInScreen(onContinueAsGuest: () {
          final settings = ref.read(conversionModeProvider);
          if (settings.cloudServerUrl.isEmpty) {
            ref.read(conversionModeProvider.notifier).setMode(ConversionModePref.offline);
          }
          ref.read(guestAccessProvider.notifier).setGuest(true);
        });
      },
    );
  }
}

/// Library plus the one-time first-run guide: opens over the library the
/// first time it is shown, never again once seen or skipped.
class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  @override
  void initState() {
    super.initState();
    _maybeShowTour();
  }

  Future<void> _maybeShowTour() async {
    if (await TourStore.hasSeen() || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const TourScreen()),
    );
  }

  @override
  Widget build(BuildContext context) => const LibraryScreen();
}
