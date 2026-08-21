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
    final catalog = ref.watch(catalogProvider);
    final downloadedAsync = ref.watch(downloadedBooksProvider);
    final progress = ref.watch(downloadProgressProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Firebrat')),
      body: catalog.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => _ErrorView(
          message: 'Could not reach the Firebrat server.\n$err',
          onRetry: () => ref.invalidate(catalogProvider),
        ),
        data: (books) {
          if (books.isEmpty) {
            return const Center(child: Text('No books available yet.'));
          }
          final downloaded = downloadedAsync.value ?? {};
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(catalogProvider);
              await ref.read(catalogProvider.future);
            },
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 320,
                mainAxisExtent: 190,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
              ),
              itemCount: books.length,
              itemBuilder: (context, i) {
                final book = books[i];
                return BookCard(
                  book: book,
                  isDownloaded: downloaded.contains(book.bookId),
                  downloadProgress: progress[book.bookId],
                  onTap: () => _openOrDownload(context, ref, book, downloaded.contains(book.bookId)),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _openOrDownload(BuildContext context, WidgetRef ref, BookSummary book, bool isDownloaded) async {
    if (isDownloaded) {
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
      ref.invalidate(downloadedBooksProvider);
    } catch (e) {
      notifier.clear(book.bookId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
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
            const Icon(Icons.cloud_off_rounded, size: 48),
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
