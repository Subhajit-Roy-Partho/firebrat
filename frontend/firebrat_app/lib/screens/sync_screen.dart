import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/book.dart';
import '../services/auth_service.dart';
import '../services/book_sync_coordinator.dart';
import '../services/firestore_sync_service.dart';
import '../services/integrity_service.dart';
import '../state/library_providers.dart';

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});
  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  bool _busy = false;
  bool _enabled = true;
  String? _message;
  Map<String, Map<String, dynamic>> _records = {};
  List<BookSummary> _local = [];
  final _metadata = FirestoreSyncService.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_metadata.currentUid == null) return;
    try {
      final enabled = await _metadata.syncEnabled();
      final local = await ref.read(localBooksProvider.future);
      final records = enabled
          ? await _metadata.fetchLibrary(strict: true)
          : <String, Map<String, dynamic>>{};
      if (mounted) {
        setState(() {
          _enabled = enabled;
          _local = local;
          _records = records;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Cloud metadata is unavailable. Local books and progress still work. Try Sync metadata when online.',
        );
      }
    }
  }

  Future<void> _run(
    String message,
    Future<void> Function(BookSyncCoordinator) action,
  ) async {
    setState(() {
      _busy = true;
      _message = message;
    });
    try {
      final coordinator = BookSyncCoordinator(
        ref.read(downloadManagerProvider),
        _metadata,
      );
      await action(coordinator);
      ref.invalidate(localBooksProvider);
      await _load();
      if (mounted) {
        setState(
          () =>
              _message = 'Sync complete. Book files remain in your own Drive.',
        );
      }
    } catch (e) {
      if (mounted) {
        // Fail-open local: books and progress on this device are untouched.
        // A retryable integrity mint surfaces as the offline-queued string
        // so users know the backup flush will retry when online.
        final msg = '$e';
        final queued = msg.contains('queued');
        setState(
          () => _message = queued
              ? '${IntegrityService.offlineQueuedMessage} Your local books remain available.'
              : 'Sync could not finish: $e. Your local books remain available.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentUser;
    final local = {for (final b in _local) b.bookId: b};
    final ids = {...local.keys, ..._records.keys}.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: const Text('Sync & backup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Firebase stores only library metadata and reading position. '
            'Book files stay on your device or in your own Google Drive. '
            'Back up on one device, then sign in with the same Google account on another and restore here.',
          ),
          const SizedBox(height: 12),
          if (user == null)
            const Text(
              'Guest mode: progress is saved only on this device. Sign in from the main menu to use cross-device sync.',
            )
          else ...[
            Text('Account: ${user.email ?? user.uid}'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sync metadata and reading position'),
              subtitle: const Text(
                'Reading resumes from the latest saved position when you open the same book. Disable to keep future progress local.',
              ),
              value: _enabled,
              onChanged: _busy
                  ? null
                  : (value) async {
                      await _metadata.setSyncEnabled(value);
                      if (mounted) setState(() => _enabled = value);
                      await _load();
                    },
            ),
            FilledButton.icon(
              onPressed: _busy || !_enabled
                  ? null
                  : () => _run('Syncing small library records…', (c) async {
                      final books = await ref.read(localBooksProvider.future);
                      _records = await c.syncMetadata(books);
                    }),
              icon: const Icon(Icons.sync),
              label: const Text('Sync metadata'),
            ),
            const Text(
              'Sync is bounded to 200 cloud library entries per fetch and 500 writes per account/device per day. '
              'Spark quotas are shared by the project; reaching a limit pauses sync, never local reading. No book bytes are stored in Firebase.',
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_message!),
              ),
            for (final id in ids)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        local[id]?.title ??
                            _records[id]?['title'] as String? ??
                            id,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        _records[id]?['driveFileId'] != null
                            ? 'Drive backup available'
                            : 'No Drive backup recorded',
                      ),
                      if (local[id] != null)
                        OutlinedButton(
                          onPressed: _busy || !_enabled
                              ? null
                              : () => _run(
                                  'Preparing backup in your Drive…',
                                  (c) => c.backup(local[id]!),
                                ),
                          child: const Text('Back up to my Drive'),
                        )
                      else if (_records[id]?['driveFileId'] != null)
                        OutlinedButton(
                          onPressed: _busy || !_enabled
                              ? null
                              : () => _run(
                                  'Restoring from your Drive…',
                                  (c) => c.restore(id, _records[id]!),
                                ),
                          child: const Text('Restore from my Drive'),
                        )
                      else
                        const Text(
                          'Back up this book on its original device before restoring here.',
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
