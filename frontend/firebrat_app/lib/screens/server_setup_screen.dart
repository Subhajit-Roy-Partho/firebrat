import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api_client.dart';
import '../state/server_admin_providers.dart';

/// First-run server setup: shown only while GET /me reports needs_setup
/// (IAM on, no admin yet). The user pastes the one-time 10-char setup
/// code from the server log; POST /admin/bootstrap makes this signed-in
/// account the admin and the screen closes. The code is never logged on
/// the client — it travels only in the bootstrap POST body.
class ServerSetupScreen extends ConsumerStatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  ConsumerState<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends ConsumerState<ServerSetupScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the setup code from the server log.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Bootstraps, then reloads /me so the account is admin everywhere.
      await ref.read(serverAdminProvider.notifier).bootstrap(code);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This account is now the server admin.'),
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = ApiClient.friendlyAdminError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up this server')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionTitle('1 · Claim the admin account'),
          const _HelpText(
            'This server has no admin yet. Enter the one-time setup code '
            'printed in the server log (and in SETUP_CODE.txt next to the '
            'server data). This signed-in account becomes the admin; the '
            'code stops working afterwards.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('setup-code'),
            controller: _code,
            decoration: const InputDecoration(
              labelText: 'Setup code',
              hintText: '10 characters from the server log',
              border: OutlineInputBorder(),
            ),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !_busy,
            onSubmitted: (_) => _bootstrap(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              key: const ValueKey('setup-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('setup-submit'),
            onPressed: _busy ? null : _bootstrap,
            child: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Set up this server'),
          ),
          const SizedBox(height: 12),
          const _HelpText(
            'Lost the code? Restarting the server prints a fresh one. '
            'Codes expire after 5 wrong tries (10-minute lockout).',
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.titleMedium);
  }
}

class _HelpText extends StatelessWidget {
  final String text;
  const _HelpText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.bodySmall);
  }
}
