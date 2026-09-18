import 'package:flutter/material.dart';
import '../services/auth_service.dart';

/// First screen for signed-out users. Google sign-in only for now —
/// anonymous browsing stays available via "Continue without signing in",
/// which simply skips the account (server treats those calls as
/// anonymous; book downloads from the shelf keep working).
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.signInWithGoogle();
      // AuthGate flips to the library on authStateChanges — nothing to push.
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Sign-in failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Firebrat', style: Theme.of(context).textTheme.displaySmall),
              const SizedBox(height: 8),
              Text(
                'Technical books as narrated audiobooks — figures and formulas kept in view.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _busy ? null : _signIn,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login_rounded),
                label: const Text('Sign in with Google'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
