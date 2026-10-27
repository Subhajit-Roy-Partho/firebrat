import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/analytics_service.dart';
import '../services/auth_service.dart';
import 'screens/library_screen.dart';
import 'screens/server_setup_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/tour_screen.dart';
import 'state/library_providers.dart' show apiClientProvider;
import 'state/server_admin_providers.dart';
import 'state/theme_providers.dart';
import 'state/tour_providers.dart';
import 'state/on_device_conversion_providers.dart';
import 'state/on_device_queue_provider.dart';
import 'state/guest_access_provider.dart';
import 'theme/app_theme.dart';

class FirebratApp extends ConsumerWidget {
  const FirebratApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    // Start the conversion queue with the app, so a book that was converting
    // when the app was updated or closed carries on without opening Conversions.
    ref.read(onDeviceQueueProvider);
    return MaterialApp(
      title: 'Firebrat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      // Transparent system bars with icons that stay readable in light and dark.
      builder: (context, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
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
class _Home extends ConsumerStatefulWidget {
  const _Home();

  @override
  ConsumerState<_Home> createState() => _HomeState();
}

class _HomeState extends ConsumerState<_Home> {
  bool _setupShown = false;

  @override
  void initState() {
    super.initState();
    _maybeShowTour();
    // GET /me once signed in on a server-backed mode: roles, IAM flag and
    // the first-run "needs setup" flag. Failures (old server, offline)
    // leave everything in the old permissive state.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshMe());
  }

  void _refreshMe() {
    if (!mounted) return;
    if (ref.read(conversionModeProvider).mode == ConversionModePref.cloud &&
        AuthService.instance.currentUser != null) {
      ref.read(serverAdminProvider.notifier).refreshMe();
    }
  }

  Future<void> _maybeShowTour() async {
    if (await TourStore.hasSeen() || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const TourScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A new server URL means a different account/role context.
    ref.listen(apiClientProvider, (_, _) {
      ref.read(serverAdminProvider.notifier).clear();
      _refreshMe();
    });
    // First-run: the server has no admin, so offer the setup-code screen
    // once (a banner on Conversions stays available afterwards).
    ref.listen(needsSetupProvider, (_, needs) {
      if (needs && !_setupShown) {
        _setupShown = true;
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const ServerSetupScreen()));
      }
    });
    return const LibraryScreen();
  }
}
