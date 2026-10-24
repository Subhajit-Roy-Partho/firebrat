import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Public privacy and support paths remain available without an account.
class InformationScreen extends StatelessWidget {
  final Future<bool> Function(Uri)? openLink;
  const InformationScreen({super.key, this.openLink});

  Future<void> _open(BuildContext context, String path) async {
    final uri = Uri.parse(
      'https://subhajit-roy-partho.github.io/firebrat/$path/',
    );
    try {
      final opened =
          await (openLink?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (opened) return;
    } catch (_) {}
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the page. Visit $uri')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Privacy & support')),
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Read how Firebrat handles your books and account, request data removal, '
            'or get help. These pages open in your browser and need an internet connection.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: const Text('Privacy policy'),
          subtitle: const Text('Data collection, retention and your controls'),
          onTap: () => _open(context, 'privacy'),
        ),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Data use & safety'),
          subtitle: const Text(
            'Local processing, Firebase and optional servers',
          ),
          onTap: () => _open(context, 'data-safety'),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.person_remove_outlined),
          title: const Text('Request account deletion'),
          subtitle: const Text(
            'Request removal of your Firebrat account and cloud-library data. '
            'Requests are verified and processed manually.',
          ),
          onTap: () => _open(context, 'delete-account'),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Text(
            'Deleting a local book does not delete remote copies. '
            'Downloaded books and models stay on this device until you remove them. '
            'Drive backups and independently operated servers have separate deletion controls.',
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.menu_book_outlined),
          title: const Text('Conversion guide'),
          subtitle: const Text(
            'Offline reading, device models and server setup',
          ),
          onTap: () => _open(context, 'help'),
        ),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Support & bug reports'),
          subtitle: const Text('GitHub issues or royduck@duck.com'),
          onTap: () => _open(context, 'support'),
        ),
      ],
    ),
  );
}
