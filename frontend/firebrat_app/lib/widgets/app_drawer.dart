import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/app_network_gate.dart';
import '../services/update_checker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../screens/conversion_settings_screen.dart';
import '../screens/conversions_screen.dart';
import '../screens/information_screen.dart';
import '../screens/server_admin_screen.dart';
import '../screens/sync_screen.dart';
import '../screens/tour_screen.dart';
import '../services/auth_service.dart';
import '../state/server_admin_providers.dart';
import '../state/on_device_conversion_providers.dart';
import '../state/avatar_provider.dart';
import '../state/guest_access_provider.dart';

/// Bumped with `version:` in frontend/firebrat_app/pubspec.yaml on every
/// release (and passed as --dart-define=FIREBRAT_APP_VERSION=... by the
/// release workflow, which wins when present). package_info_plus was
/// tried for this and reverted: every 8.x needs win32 ^5 while this app
/// pins win32 ^6 for device_info_plus — unresolvable without forking one.
const _appVersion = String.fromEnvironment(
  'FIREBRAT_APP_VERSION',
  defaultValue: '1.8.0+33',
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
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Theme.of(context).colorScheme.primaryContainer,
                  Theme.of(context).colorScheme.tertiaryContainer,
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _ProfileAvatar(initial: initial),
                const SizedBox(height: 8),
                Text(
                  email ?? 'Guest mode',
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  email == null
                      ? 'Read, import and convert locally without an account.'
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
          ListTile(
            leading: const Icon(Icons.sync_rounded),
            title: const Text('Sync & backup'),
            subtitle: const Text('Reading position in Firebase; books in your Drive'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SyncScreen()));
            },
          ),
          // Admin-only: users, models, run pattern, queue. Hidden for
          // everyone else (and while IAM is off, unless legacy admin).
          if (ref.watch(showAdminSectionProvider))
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Server administration'),
              subtitle: const Text('Users, models, run pattern, queue'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ServerAdminScreen()),
                );
              },
            ),
          if (email != null)
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Sign out'),
              onTap: () async {
                Navigator.of(context).pop();
                await AuthService.instance.signOut();
                ref.read(serverAdminProvider.notifier).clear();
                // AuthGate flips to SignInScreen on authStateChanges.
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.login_rounded),
              title: const Text('Sign in'),
              onTap: () {
                Navigator.of(context).pop();
                ref.read(guestAccessProvider.notifier).setGuest(false);
                ref.read(conversionModeProvider.notifier).setMode(ConversionModePref.cloud);
              },
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.explore_outlined),
            title: const Text('App guide'),
            subtitle: const Text('Quick tour of where things are'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const TourScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy & support'),
            subtitle: const Text('Account deletion, help and bug reports'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const InformationScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.system_update_rounded),
            title: const Text('Check for updates'),
            onTap: () {
              final nav = Navigator.of(context);
              nav.pop();
              UpdateChecker.maybePrompt(AppNetworkGate.navigatorKey.currentContext ?? nav.context, force: true);
            },
          ),
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


/// Profile photo in the drawer header. Tap to choose or remove it; the small
/// camera badge says it is editable. Works signed in or as a guest.
class _ProfileAvatar extends ConsumerWidget {
  final String initial;
  const _ProfileAvatar({required this.initial});

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final files = await FilePicker.pickFiles(type: FileType.image);
      if (files.isEmpty) return;
      final file = files.single;
      final bytes = await file.readAsBytes();
      await ref.read(avatarProvider.notifier).setFromBytes(bytes);
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not set that photo.')));
    }
  }

  Future<void> _sheet(BuildContext context, WidgetRef ref, bool hasPhoto) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(hasPhoto ? 'Choose a different photo' : 'Choose a photo'),
              onTap: () {
                Navigator.of(ctx).pop();
                _pick(context, ref);
              },
            ),
            if (hasPhoto)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Remove photo'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  ref.read(avatarProvider.notifier).remove();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final photo = ref.watch(avatarProvider).value;
    return Semantics(
      button: true,
      label: 'Profile photo. Double tap to change.',
      child: GestureDetector(
        onTap: () => _sheet(context, ref, photo != null),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              backgroundImage: photo == null ? null : FileImage(photo),
              child: photo == null
                  ? Text(initial, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700))
                  : null,
            ),
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Icon(Icons.photo_camera_rounded, size: 14, color: scheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
