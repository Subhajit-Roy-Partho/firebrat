import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../screens/conversion_settings_screen.dart';
import '../screens/conversions_screen.dart';
import '../services/auth_service.dart';

/// Bumped with `version:` in frontend/firebrat_app/pubspec.yaml on every
/// release (and passed as --dart-define=FIREBRAT_APP_VERSION=... by the
/// release workflow, which wins when present). package_info_plus was
/// tried for this and reverted: every 8.x needs win32 ^5 while this app
/// pins win32 ^6 for device_info_plus — unresolvable without forking one.
const _appVersion = String.fromEnvironment(
  'FIREBRAT_APP_VERSION',
  defaultValue: '1.5.9+20',
);

/// Left drawer: who is signed in, where to go, and the way out.
/// Previously the app had no visible account surface at all — no way to
/// see the signed-in email or sign out without clearing app data.
class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = AuthService.instance.currentUser;
    final email = user?.email ?? user?.displayName;
    final initial = (email?.isNotEmpty ?? false)
        ? email![0].toUpperCase()
        : '?';

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                CircleAvatar(child: Text(initial)),
                const SizedBox(height: 8),
                Text(
                  email ?? 'Not signed in',
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  email == null
                      ? 'Reads work offline; sign in to convert on the server.'
                      : 'Signed in',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.library_books_rounded),
            title: const Text('Library'),
            onTap: () => Navigator.of(context).pop(),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_upload_rounded),
            title: const Text('Conversions'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ConversionsScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Conversion settings'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const ConversionSettingsScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.memory_rounded),
            title: const Text('Models & voice'),
            subtitle: const Text('Local LLM, GPU, narrator — all on one settings page'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const ConversionSettingsScreen()),
              );
            },
          ),
          const Divider(),
          if (email != null)
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Sign out'),
              onTap: () async {
                Navigator.of(context).pop();
                await AuthService.instance.signOut();
                // AuthGate flips to SignInScreen on authStateChanges.
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.login_rounded),
              title: const Text('Sign in'),
              onTap: () => Navigator.of(context).pop(),
            ),
          const Divider(),
          AboutListTile(
            icon: const Icon(Icons.info_outline_rounded),
            applicationName: 'Firebrat',
            applicationVersion: _appVersion,
            aboutBoxChildren: const [
              Text('PDF → narrated, figure-synced audiobooks for technical books.'),
            ],
            child: Text(
              'About · v$_appVersion',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
