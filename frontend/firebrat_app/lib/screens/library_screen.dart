import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/book.dart';
import '../state/library_providers.dart';
import '../widgets/book_card.dart';
import 'reader_screen.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localAsync = ref.watch(localBooksProvider);
    final catalogAsync = ref.watch(catalogProvider);
    final progress = ref.watch(downloadProgressProvider);
    final importing = ref.watch(importInProgressProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Firebrat'),
        actions: [
          IconButton(
            icon: importing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.file_open_rounded),
            tooltip: 'Import a book file (.tar.gz / .zip)',
            onPressed: importing ? null : () => _importFile(context, ref),
          ),
        ],
      ),
      body: localAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => _ErrorView(
          message: 'Could not read local library.\n$err',
          onRetry: () => invalidateLibrary(ref),
        ),
        data: (localBooks) {
          final local = {for (final b in localBooks) b.bookId: b};
          final catalogBooks = catalogAsync.value ?? const <BookSummary>[];
          // Remote-only entries (not yet downloaded) show as download targets.
          final remoteOnly = catalogBooks.where((b) => !local.containsKey(b.bookId)).toList();
          final allEntries = [...localBooks, ...remoteOnly];

          if (allEntries.isEmpty) {
            return _EmptyLibrary(
              serverReachable: catalogAsync.hasValue,
              importing: importing,
              onImport: () => _importFile(context, ref),
              onRetryServer: () => ref.invalidate(catalogProvider),
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              invalidateLibrary(ref);
              await ref.read(localBooksProvider.future);
            },
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 320,
                mainAxisExtent: 190,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
              ),
              itemCount: allEntries.length,
              itemBuilder: (context, i) {
                final book = allEntries[i];
                final isLocal = local.containsKey(book.bookId);
                return BookCard(
                  book: book,
                  isDownloaded: isLocal,
                  downloadProgress: progress[book.bookId],
                  onTap: () => _openOrDownload(context, ref, book, isLocal),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _openOrDownload(BuildContext context, WidgetRef ref, BookSummary book, bool isLocal) async {
    if (isLocal) {
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(bookId: book.bookId)));
      return;
    }
    final dm = ref.read(downloadManagerProvider);
    final notifier = ref.read(downloadProgressProvider.notifier);
    notifier.setProgress(book.bookId, 0.0);
    try {
      await dm.downloadAndExtract(book.bookId, onProgress: (p) => notifier.setProgress(book.bookId, p));
      notifier.clear(book.bookId);
      invalidateLibrary(ref);
    } catch (e) {
      notifier.clear(book.bookId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  Future<void> _importFile(BuildContext context, WidgetRef ref) async {
    final importMgr = ref.read(importManagerProvider);
    final inProgress = ref.read(importInProgressProvider.notifier);
    try {
      final file = await importMgr.pickArchiveFile();
      if (file == null) return; // user cancelled
      inProgress.set(true);
      final bookId = await importMgr.importFromFile(file);
      invalidateLibrary(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported "$bookId"')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    } finally {
      inProgress.set(false);
    }
  }
}

class _EmptyLibrary extends StatelessWidget {
  final bool serverReachable;
  final bool importing;
  final VoidCallback onImport;
  final VoidCallback onRetryServer;

  const _EmptyLibrary({
    required this.serverReachable,
    required this.importing,
    required this.onImport,
    required this.onRetryServer,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book_outlined, size: 56),
            const SizedBox(height: 16),
            Text(
              serverReachable
                  ? 'No books yet — the server has none, and you haven\'t imported one.'
                  : 'No books yet, and the Firebrat server isn\'t reachable.\nYou can still import a book file directly.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: importing ? null : onImport,
              icon: const Icon(Icons.file_open_rounded),
              label: const Text('Import a book file'),
            ),
            if (!serverReachable) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onRetryServer, child: const Text('Retry server connection')),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
