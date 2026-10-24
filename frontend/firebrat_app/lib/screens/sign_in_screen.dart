import 'package:flutter/material.dart';
import '../services/analytics_service.dart';
import '../services/auth_service.dart';

/// Sign in or create an account with Google or email. Google authentication
/// creates a Firebase account on the first successful sign-in.
class SignInScreen extends StatefulWidget {
  final VoidCallback onContinueAsGuest;
  const SignInScreen({super.key, required this.onContinueAsGuest});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  bool _registerMode = false;
  String? _error;
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(String method, Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await AnalyticsService.instance.logLogin(method);
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

  Future<void> _signIn() =>
      _run('google', AuthService.instance.signInWithGoogle);

  Future<void> _emailAuth() {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.length < 6) {
      setState(
        () => _error = 'Enter an email and a password of 6+ characters.',
      );
      return Future.value();
    }
    return _run(
      _registerMode ? 'password_signup' : 'password',
      () => _registerMode
          ? AuthService.instance.registerWithEmail(email, password)
          : AuthService.instance.signInWithEmail(email, password),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 48).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Firebrat',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Technical books as narrated audiobooks — figures and formulas kept in view.',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : widget.onContinueAsGuest,
                    icon: const Icon(Icons.person_outline),
                    label: const Text('Continue as guest'),
                  ),
                  const SizedBox(height: 8),
                  const Text('Read, import and convert on this device without an account. '
                      'Sign in later for server conversion and account sync.'),
                  const SizedBox(height: 24),
                  Text(
                    _registerMode ? 'Create your account' : 'Welcome back',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _signIn,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login_rounded),
                    label: Text(
                      _registerMode
                          ? 'Sign up with Google'
                          : 'Sign in with Google',
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  TextField(
                    controller: _email,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _busy ? null : _emailAuth,
                    child: Text(
                      _registerMode ? 'Create account' : 'Sign in with email',
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _registerMode = !_registerMode;
                            _error = null;
                          }),
                    child: Text(
                      _registerMode
                          ? 'Have an account? Sign in'
                          : 'New here? Create an account',
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
