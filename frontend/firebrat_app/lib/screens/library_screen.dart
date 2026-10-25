import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import '../models/book.dart';
import '../models/manifest.dart';
import '../services/analytics_service.dart';
import '../services/download_manager.dart';
import '../services/drive_sync_service.dart';
import '../services/firestore_sync_service.dart';
import '../services/integrity_service.dart';
import '../services/notification_service.dart';
import '../state/library_providers.dart';
import '../state/library_layout_provider.dart';
import '../state/on_device_conversion_providers.dart';
import '../state/theme_providers.dart';
import '../state/reader_providers.dart';
import '../widgets/app_drawer.dart';
import '../widgets/book_card.dart';
import '../widgets/book_cover.dart';
import 'chapter_reader_screen.dart';
import '../state/cast_provider.dart';
import 'cast_screen.dart';
import 'conversions_screen.dart';
import 'reader_screen.dart';
import 'tour_screen.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localAsync = ref.watch(localBooksProvider);
    final catalogAsync = ref.watch(catalogProvider);
    final progress = ref.watch(downloadProgressProvider);
    final importing = ref.watch(importProgressProvider);
    final layout = ref.watch(libraryLayoutProvider);
    final themeMode = ref.watch(themeModeProvider);
    final isCloud =
        ref.watch(conversionModeProvider).mode == ConversionModePref.cloud;

    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Firebrat', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<LibraryLayout>(
            tooltip: 'Library layout',
            icon: Icon(
              layout == LibraryLayout.list
                  ? Icons.view_list_rounded
                  : Icons.grid_view_rounded,
            ),
            initialValue: layout,
            onSelected: (value) =>
                ref.read(libraryLayoutProvider.notifier).select(value),
            itemBuilder: (_) => const [
              PopupMenuItem(value: LibraryLayout.list, child: Text('List')),
              PopupMenuItem(
                value: LibraryLayout.smallCards,
                child: Text('Small cards'),
              ),
              PopupMenuItem(
                value: LibraryLayout.largeCards,
                child: Text('Large cards'),
              ),
            ],
          ),
          PopupMenuButton<ThemeMode>(
            icon: Icon(switch (themeMode) {
              ThemeMode.light => Icons.light_mode_rounded,
              ThemeMode.dark => Icons.dark_mode_rounded,
              ThemeMode.system => Icons.brightness_auto_rounded,
            }),
            tooltip: 'Theme',
            initialValue: themeMode,
            onSelected: (mode) =>
                ref.read(themeModeProvider.notifier).setThemeMode(mode),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: ThemeMode.system,
                child: Text('Match system'),
              ),
              PopupMenuItem(value: ThemeMode.light, child: Text('Light')),
              PopupMenuItem(value: ThemeMode.dark, child: Text('Dark')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.cloud_upload_rounded),
            tooltip: 'Conversions and settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ConversionsScreen()),
            ),
          ),
          IconButton(
            icon: importing == null
                ? const Icon(Icons.file_open_rounded)
                : SizedBox(
                    width: 20,
                    height: 20,
                    // Zip imports never report a fraction (stays 0.0):
                    // indeterminate spinner. Tar.gz streams 0→1.
                    child: CircularProgressIndicator(
                      value: importing > 0 ? importing : null,
                      strokeWidth: 2,
                    ),
                  ),
            tooltip: 'Import a book file (.tar.gz / .zip)',
            onPressed: importing != null
                ? null
                : () => _importFile(context, ref),
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
          final remoteOnly = catalogBooks
              .where((b) => !local.containsKey(b.bookId))
              .toList();
          final allEntries = [...localBooks, ...remoteOnly];

          if (allEntries.isEmpty) {
            return _EmptyLibrary(
              isCloud: isCloud,
              serverReachable: catalogAsync.hasValue,
              importing: importing != null,
              onImport: () => _importFile(context, ref),
              onRetryServer: () => ref.invalidate(catalogProvider),
            );
          }

          return Column(
            children: [
              // The catalog fetch failing used to be silent whenever local
              // books existed (remote titles just never appeared, with no
              // way to retry) — surface it with a one-tap retry instead.
              if (isCloud && catalogAsync.hasError)
                Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Could not reach the server — showing on-device books only.',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: () => ref.invalidate(catalogProvider),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    invalidateLibrary(ref);
                    await ref.read(localBooksProvider.future);
                  },
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: _ShelfHeader(books: allEntries, downloaded: localBooks.length),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                        sliver: layout == LibraryLayout.list
                            ? SliverList.builder(
                                itemCount: allEntries.length,
                                itemBuilder: (context, i) => _Reveal(
                                  index: i,
                                  child: _buildBook(context, ref, allEntries[i],
                                      local, progress, layout),
                                ),
                              )
                            : SliverLayoutBuilder(
                                builder: (context, constraints) {
                                  const spacing = 14.0;
                                  final target =
                                      layout == LibraryLayout.smallCards ? 100.0 : 160.0;
                                  final cols = ((constraints.crossAxisExtent + spacing) /
                                          (target + spacing))
                                      .floor()
                                      .clamp(1, 8);
                                  final itemW = (constraints.crossAxisExtent -
                                          spacing * (cols - 1)) /
                                      cols;
                                  final textScale =
                                      MediaQuery.textScalerOf(context);
                                  return SliverGrid(
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: cols,
                                      mainAxisExtent: itemW * 1.5 +
                                          textScale.scale(86),
                                      crossAxisSpacing: spacing,
                                      mainAxisSpacing: 14,
                                    ),
                                    delegate: SliverChildBuilderDelegate(
                                      (context, i) => _Reveal(
                                        index: i,
                                        child: _buildBook(context, ref,
                                            allEntries[i], local, progress, layout),
                                      ),
                                      childCount: allEntries.length,
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBook(
    BuildContext context,
    WidgetRef ref,
    BookSummary book,
    Map<String, BookSummary> local,
    Map<String, DownloadProgress> progress,
    LibraryLayout layout,
  ) {
    final isLocal = local.containsKey(book.bookId);
    return BookCard(
      book: book,
      layout: layout,
      isDownloaded: isLocal,
      downloadProgress: progress[book.bookId],
      coverPath: isLocal
          ? ref.watch(bookCoverProvider(book.bookId)).value
          : null,
      onTap: () => _openOrDownload(context, ref, book, isLocal),
      onLongPress: () => _showBookActions(context, ref, book, isLocal),
      onPauseDownload: progress[book.bookId] == null
          ? null
          : () => _pauseDownload(context, ref, book),
      onDiscardDownload: progress[book.bookId] == null
          ? null
          : () => _discardDownload(context, ref, book),
    );
  }

  Future<void> _openOrDownload(BuildContext context, WidgetRef ref, BookSummary book, bool isLocal) async {
    // Tapping a card mid-download used to fall through into a second
    // download attempt (or a half-opened reader on some timings) — say
    // plainly that it's still coming instead.
    final inFlight = ref.read(downloadProgressProvider)[book.bookId];
    if (inFlight != null && !isLocal) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Still downloading… ${(inFlight.fraction * 100).round()}% (${inFlight.phase}).')),
        );
      }
      return;
    }
    if (isLocal) {
      if (!context.mounted) return;
      // Chapter-PDF books have no audio — open the chapter list instead
      // of the narrated reader (which would have nothing to play).
      final repo = ref.read(libraryRepositoryProvider);
      Manifest? manifest;
      try {
        manifest = await repo.loadLocalManifest(book.bookId);
      } catch (_) {}
      // Cloud writes may stay pending indefinitely offline or when Firestore
      // is disabled. Local reading must never wait for metadata or analytics.
      if (ref.read(conversionModeProvider).mode == ConversionModePref.cloud) {
        unawaited(ref.read(firestoreSyncServiceProvider).touchOpened(book.bookId));
        unawaited(AnalyticsService.instance.logBookOpened(sectionCount: book.sectionCount));
      }
      if (!context.mounted) return;
      // Re-open from the persisted account-specific checkpoint, rather than
      // reusing a cached controller belonging to another book/account session.
      ref.invalidate(readerControllerProvider(book.bookId));
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
    // A complete book on disk (e.g. the listing just hasn't refreshed,
    // or a previous run finished while the UI lagged) must never be
    // re-downloaded — re-downloading wipes it first. Open it instead.
    if (await dm.isDownloaded(book.bookId)) {
      invalidateLibrary(ref);
      if (context.mounted) {
        await _openOrDownload(context, ref, book, true);
      }
      return;
    }
    try {
      await dm.downloadAndExtract(
        book.bookId,
        onProgress: (p) {
          notifier.setProgress(book.bookId, p);
          unawaited(NotificationService.showDownloadProgress(
            bookId: book.bookId,
            title: book.title,
            fraction: p.fraction,
            receivedBytes: p.receivedBytes,
            totalBytes: p.totalBytes,
            phase: p.phase,
          ));
        },
        onZipReady: (id, zipPath) => _backupZipToDrive(ref, id, zipPath),
      );
      notifier.clear(book.bookId);
      unawaited(NotificationService.showDownloadProgress(
        bookId: book.bookId,
        title: book.title,
        fraction: 1.0,
        receivedBytes: 0,
        totalBytes: 0,
        phase: 'done',
        force: true,
      ));
      invalidateLibrary(ref);
      await FirestoreSyncService.instance.upsertBook(
        bookId: book.bookId,
        title: book.title,
        source: 'server',
      );
      await AnalyticsService.instance.logBookDownloaded();
    } catch (e) {
      notifier.clear(book.bookId);
      unawaited(NotificationService.cancelDownloadNotification(book.bookId));
      // A cancel-and-clear already told the user; don't also say "paused".
      if (DownloadManager.consumeDiscarded(book.bookId)) return;
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

  /// Long-press action sheet for a book card: open/download plus delete
  /// from device and/or server (each behind a confirm dialog — server
  /// deletion is irreversible).
  Future<void> _showBookActions(
      BuildContext context, WidgetRef ref, BookSummary book, bool isLocal) async {
    // Load the cast first: a provider read inside the sheet would still be empty.
    final hasCast = isLocal && (await ref.read(castProvider(book.bookId).future)) != null;
    if (!context.mounted) return;
    final catalogBooks = ref.read(catalogProvider).value ?? const <BookSummary>[];
    final isOnServer = catalogBooks.any((b) => b.bookId == book.bookId);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.menu_book_rounded),
              title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(book.bookId, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(isLocal ? Icons.play_arrow_rounded : Icons.download_rounded),
              title: Text(isLocal ? 'Open' : 'Download'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _openOrDownload(context, ref, book, isLocal);
              },
            ),
            if (hasCast)
              ListTile(
                leading: const Icon(Icons.groups_rounded),
                title: const Text('Cast & voices'),
                subtitle: const Text('Check which characters were found and how they sound.'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => CastScreen(bookId: book.bookId)));
                },
              ),
            if (isLocal)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Delete from this device'),
                subtitle: const Text('Frees space; the server copy (if any) is untouched.'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _deleteLocalBook(context, ref, book);
                },
              ),
            if (isOnServer)
              ListTile(
                leading: const Icon(Icons.cloud_off_rounded),
                title: const Text('Delete from server'),
                subtitle: const Text('Irreversible — frees server space.'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _deleteServerBook(context, ref, book);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteLocalBook(BuildContext context, WidgetRef ref, BookSummary book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete from this device?'),
        content: Text('"${book.title}" will be removed from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(downloadManagerProvider).deleteBook(book.bookId);
      invalidateLibrary(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Deleted "${book.title}" from this device.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _deleteServerBook(BuildContext context, WidgetRef ref, BookSummary book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete from server?'),
        content: Text('"${book.title}" will be permanently removed from the server. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(apiClientProvider).deleteBook(book.bookId);
      ref.invalidate(catalogProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Deleted "${book.title}" from the server.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Server delete failed: $e')));
      }
    }
  }

  void _pauseDownload(BuildContext context, WidgetRef ref, BookSummary book) {
    DownloadManager.pauseDownload(book.bookId);
    ref.read(downloadProgressProvider.notifier).clear(book.bookId);
    unawaited(NotificationService.cancelDownloadNotification(book.bookId));
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
    unawaited(NotificationService.cancelDownloadNotification(book.bookId));
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
  ///
  /// Attestation is optional until configured and verified server-side.
  Future<void> _backupZipToDrive(WidgetRef ref, String bookId, String zipPath) async {
    try {
      final settings = ref.read(conversionModeProvider);
      if (settings.mode != ConversionModePref.cloud || settings.storageBackend != 'drive') {
        return;
      }
      if (!await DriveSyncService.instance.isEnabled()) return;
      final integrity = ref.read(integrityServiceProvider);
      final mint = await integrity.mintForRemote(
        requestHash: IntegrityService.requestHashForString(
          'drive-flush:$bookId:${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
      // Local stays usable no matter what (fail-open local).
      assert(integrity.checkLocal(mint));
      if (!integrity.allowsRemote(mint)) {
        debugPrint('Drive backup skipped: ${mint.errorCode}');
        return;
      }
      final driveId = await DriveSyncService.instance.uploadBook(bookId: bookId, zipPath: zipPath);
      await FirestoreSyncService.instance.upsertBook(
        bookId: bookId,
        title: bookId,
        source: 'drive',
        driveFileId: driveId,
      );
    } catch (_) {}
  }

  Future<void> _importFile(BuildContext context, WidgetRef ref) async {
    final importMgr = ref.read(importManagerProvider);
    final progress = ref.read(importProgressProvider.notifier);
    try {
      final file = await importMgr.pickArchiveFile();
      if (file == null) return; // user cancelled
      progress.set(0.0);
      final bookId = await importMgr.importFromFile(file, onProgress: progress.set);
      invalidateLibrary(ref);
      if (ref.read(conversionModeProvider).mode == ConversionModePref.cloud) {
        unawaited(FirestoreSyncService.instance.upsertBook(
          bookId: bookId,
          title: bookId,
          source: 'import',
        ));
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported "$bookId"')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    } finally {
      progress.set(null);
    }
  }
}

class _EmptyLibrary extends StatelessWidget {
  final bool isCloud;
  final bool serverReachable;
  final bool importing;
  final VoidCallback onImport;
  final VoidCallback onRetryServer;

  const _EmptyLibrary({
    required this.isCloud,
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
            const _EmptyArt(),
            const SizedBox(height: 20),
            Text(
              !isCloud
                  ? 'Your offline library is ready. Import a book file to start reading and listening.'
                  : serverReachable
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
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TourScreen()),
              ),
              icon: const Icon(Icons.explore_outlined),
              label: const Text('Take the app tour'),
            ),
            if (isCloud && !serverReachable) ...[
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


/// Fade + rise entrance, staggered by position, so the shelf settles in
/// instead of popping. Lazy grids animate each cover as it scrolls in.
class _Reveal extends StatelessWidget {
  final int index;
  final Widget child;
  const _Reveal({required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    final delay = (index % 9) * 45;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 380 + delay),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 18), child: child),
      ),
      child: child,
    );
  }
}

/// Greeting strip above the shelf: how much there is to listen to.
class _ShelfHeader extends StatelessWidget {
  final List<BookSummary> books;
  final int downloaded;
  const _ShelfHeader({required this.books, required this.downloaded});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totalMin =
        books.fold<int>(0, (a, b) => a + b.totalDurationMs) ~/ 60000;
    final hours = totalMin ~/ 60;
    final n = books.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your library',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 2),
                Text(
                  '$n ${n == 1 ? 'book' : 'books'}'
                  '${hours > 0 ? ' · ${hours}h to listen' : ''}'
                  '${downloaded < n ? ' · $downloaded on this device' : ''}',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Icon(Icons.headphones_rounded, color: scheme.primary, size: 28),
        ],
      ),
    );
  }
}

/// Three stacked sample covers with a headphone badge.
class _EmptyArt extends StatelessWidget {
  const _EmptyArt();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget book(String id, String t, double angle, Offset off) => Transform.translate(
          offset: off,
          child: Transform.rotate(
            angle: angle,
            child: SizedBox(
              width: 88,
              height: 132,
              child: BookCover(bookId: id, title: t, radius: 8),
            ),
          ),
        );
    return SizedBox(
      width: 220,
      height: 170,
      child: Stack(
        alignment: Alignment.center,
        children: [
          book('empty-a', 'Your first book', -.18, const Offset(-52, 6)),
          book('empty-c', 'Listen anywhere', .16, const Offset(52, 8)),
          book('empty-b', 'Firebrat', 0, const Offset(0, -6)),
          Positioned(
            bottom: 0,
            right: 28,
            child: CircleAvatar(
              radius: 20,
              backgroundColor: scheme.primary,
              child: Icon(Icons.headphones_rounded, color: scheme.onPrimary, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}
