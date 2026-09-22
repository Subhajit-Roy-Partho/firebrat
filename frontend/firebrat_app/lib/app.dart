import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/analytics_service.dart';
import '../services/auth_service.dart';
import 'screens/library_screen.dart';
import 'screens/sign_in_screen.dart';
import 'state/theme_providers.dart';
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
      navigatorObservers: AnalyticsService.observerOrNull(),
      home: const AuthGate(),
    );
  }
}

/// Signed-out users land on SignInScreen; the stream flips to the library
/// the moment Firebase reports a user. No route pushing — the gate rebuilds.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: AuthService.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasData) return const LibraryScreen();
        return const SignInScreen();
      },
    );
  }
}
