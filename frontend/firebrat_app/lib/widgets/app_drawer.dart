import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../screens/conversion_settings_screen.dart';
import '../screens/conversions_screen.dart';
import '../screens/on_device_models_screen.dart';
import '../services/auth_service.dart';

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
            title: const Text('On-device models & voice'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const OnDeviceModelsScreen()),
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
        ],
      ),
    );
  }
}
