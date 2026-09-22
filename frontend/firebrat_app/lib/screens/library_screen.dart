import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/book.dart';
import '../models/manifest.dart';
import '../services/analytics_service.dart';
import '../services/download_manager.dart';
import '../services/drive_sync_service.dart';
import '../services/firestore_sync_service.dart';
import '../state/library_providers.dart';
import '../state/on_device_conversion_providers.dart';
import '../state/theme_providers.dart';
import '../widgets/app_drawer.dart';
import '../widgets/book_card.dart';
import 'chapter_reader_screen.dart';
import 'conversions_screen.dart';
import 'reader_screen.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localAsync = ref.watch(localBooksProvider);
    final catalogAsync = ref.watch(catalogProvider);
    final progress = ref.watch(downloadProgressProvider);
    final importing = ref.watch(importInProgressProvider);
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Firebrat'),
        actions: [
          PopupMenuButton<ThemeMode>(
            icon: Icon(switch (themeMode) {
              ThemeMode.light => Icons.light_mode_rounded,
              ThemeMode.dark => Icons.dark_mode_rounded,
              ThemeMode.system => Icons.brightness_auto_rounded,
            }),
            tooltip: 'Theme',
            initialValue: themeMode,
            onSelected: (mode) => ref.read(themeModeProvider.notifier).setThemeMode(mode),
            itemBuilder: (context) => const [
              PopupMenuItem(value: ThemeMode.system, child: Text('Match system')),
              PopupMenuItem(value: ThemeMode.light, child: Text('Light')),
              PopupMenuItem(value: ThemeMode.dark, child: Text('Dark')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.cloud_upload_rounded),
            tooltip: 'Convert a new book (upload to server)',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ConversionsScreen()),
            ),
          ),
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
                  coverPath: isLocal
                      ? ref.watch(bookCoverProvider(book.bookId)).value
                      : null,
                  onTap: () => _openOrDownload(context, ref, book, isLocal),
                  onPauseDownload: progress[book.bookId] == null
                      ? null
                      : () => _pauseDownload(context, ref, book),
                  onDiscardDownload: progress[book.bookId] == null
                      ? null
                      : () => _discardDownload(context, ref, book),
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
      // Chapter-PDF books have no audio — open the chapter list instead
      // of the narrated reader (which would have nothing to play).
      final repo = ref.read(libraryRepositoryProvider);
      Manifest? manifest;
      try {
        manifest = await repo.loadLocalManifest(book.bookId);
      } catch (_) {}
      await FirestoreSyncService.instance.touchOpened(book.bookId);
      await AnalyticsService.instance.logBookOpened(sectionCount: book.sectionCount);
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => (manifest != null && manifest.isChapters)
              ? ChapterReaderScreen(bookId: book.bookId)
              : ReaderScreen(bookId: book.bookId)));
      return;
    }
    final dm = ref.read(downloadManagerProvider);
    final notifier = ref.read(downloadProgressProvider.notifier);
    // Tap guard: an in-flight download for this book already exists
    // (single-flight in DownloadManager) — don't stack another one.
    if (DownloadManager.isDownloading(book.bookId)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download already in progress…')),
        );
      }
      return;
    }
    try {
      await dm.downloadAndExtract(
        book.bookId,
        onProgress: (p) => notifier.setProgress(book.bookId, p),
        onZipReady: (id, zipPath) => _backupZipToDrive(ref, id, zipPath),
      );
      notifier.clear(book.bookId);
      invalidateLibrary(ref);
      await FirestoreSyncService.instance.upsertBook(
        bookId: book.bookId,
        title: book.title,
        source: 'server',
      );
      await AnalyticsService.instance.logBookDownloaded();
    } catch (e) {
      notifier.clear(book.bookId);
      if (context.mounted) {
        // User-initiated pause surfaces as a Dio cancellation — the .part
        // file stays, and tapping the card resumes. Not an error.
        final paused = e is DioException && e.type == DioExceptionType.cancel;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(paused
                ? 'Download paused — tap the book to resume.'
                : 'Download failed: $e')));
      }
    }
  }

  void _pauseDownload(BuildContext context, WidgetRef ref, BookSummary book) {
    DownloadManager.pauseDownload(book.bookId);
    ref.read(downloadProgressProvider.notifier).clear(book.bookId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Download paused — tap the book to resume.')),
      );
    }
  }

  Future<void> _discardDownload(BuildContext context, WidgetRef ref, BookSummary book) async {
    final dm = ref.read(downloadManagerProvider);
    await dm.discardPartial(book.bookId);
    ref.read(downloadProgressProvider.notifier).clear(book.bookId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Download cancelled and cleared.')),
      );
    }
  }

  /// Drive backup hook: after a verified zip lands (before extraction
  /// deletes it), copy it to the user's Drive so other devices can pull
  /// it. Only when storage is set to Drive and sync is enabled — and
  /// failures never fail the download.
  Future<void> _backupZipToDrive(WidgetRef ref, String bookId, String zipPath) async {
    try {
      final settings = ref.read(conversionModeProvider);
      if (settings.storageBackend != 'drive') return;
      if (!await DriveSyncService.instance.isEnabled()) return;
      await DriveSyncService.instance.uploadBook(bookId: bookId, zipPath: zipPath);
      await FirestoreSyncService.instance.upsertBook(
        bookId: bookId,
        title: bookId,
        source: 'drive',
      );
    } catch (_) {}
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
      await FirestoreSyncService.instance.upsertBook(
        bookId: bookId,
        title: bookId,
        source: 'import',
      );
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
