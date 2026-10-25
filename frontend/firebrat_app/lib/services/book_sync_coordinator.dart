import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import '../models/book.dart';
import 'download_manager.dart';
import 'download_task_handler.dart';
import 'drive_sync_service.dart';
import 'firestore_sync_service.dart';
import 'import_manager.dart' show sanitizeBookId;
import 'integrity_service.dart';

/// Firestore receives only small records; all package bytes go to user Drive.
class BookSyncCoordinator {
  final DownloadManager downloads;
  final FirestoreSyncService metadata;
  final IntegrityService integrity;
  BookSyncCoordinator(this.downloads, this.metadata,
      [IntegrityService? integrity])
      : integrity = integrity ?? IntegrityService();

  /// Optional attestation policy; Firebase rules and Drive OAuth authorize
  /// current sync. No automatic retry queue is created by this operation.
  Future<void> _gateRemoteFlush(String scope) async {
    if (!integrity.requiredForRemote) return;
    final mint = await integrity.mintForRemote(
      requestHash: IntegrityService.requestHashForString(
        'drive-flush:$scope:${DateTime.now().millisecondsSinceEpoch}'));
    if (!integrity.allowsRemote(mint)) {
      throw StateError(IntegrityService.userMessageFor(mint));
    }
  }

  Future<Map<String, Map<String, dynamic>>> syncMetadata(
    List<BookSummary> local,
  ) async {
    if (metadata.currentUid == null) {
      throw StateError('Sign in to sync across devices.');
    }
    if (!await metadata.syncEnabled()) {
      throw StateError('Enable metadata sync first.');
    }
    await _gateRemoteFlush('syncMetadata');
    final records = await metadata.fetchLibrary(strict: true);
    for (final book in local) {
      final existing = records[book.bookId];
      if (existing?['title'] == book.title &&
          existing?['sectionCount'] == book.sectionCount &&
          existing?['totalDurationMs'] == book.totalDurationMs) {
        continue;
      }
      await metadata.upsertBook(
        bookId: book.bookId,
        title: book.title,
        source: existing?['source'] as String? ?? 'import',
        sectionCount: book.sectionCount,
        totalDurationMs: book.totalDurationMs,
        strict: true,
      );
    }
    await metadata.flushPendingProgress();
    return metadata.fetchLibrary(strict: true);
  }

  Future<void> backup(BookSummary book) async {
    await DriveSyncService.instance.ensureAccess();
    await _gateRemoteFlush('backup:${book.bookId}');
    final dir = await downloads.bookDir(book.bookId);
    if (!await downloads.isDownloaded(book.bookId)) {
      throw StateError('Download the complete book first.');
    }
    final zip = File(
      '${(await downloads.booksDir()).path}/.backup-${book.bookId}.zip',
    );
    final keepAlive = await DownloadKeepAlive.acquire(
      'Drive backup: ${book.title}',
    );
    try {
      DownloadKeepAlive.updateProgress('Preparing Drive backup', book.title);
      await writeBookBackup(dir, zip);
      final hash = (await sha256.bind(zip.openRead()).first).toString();
      final size = await zip.length();
      // Drive upload chunks arrive as fast as Dio download chunks; gate
      // them the same way (changed percent or 500ms heartbeat) so the
      // binder isn't hammered with updateService calls.
      int? lastBackupPct;
      var lastBackupAt =
          DateTime.fromMillisecondsSinceEpoch(0);
      final id = await DriveSyncService.instance.uploadBook(
        bookId: book.bookId,
        zipPath: zip.path,
        onProgress: (sent, total) {
          if (total <= 0) return;
          final pct = (sent / total * 100).round();
          final now = DateTime.now();
          if (pct == lastBackupPct &&
              now.difference(lastBackupAt).inMilliseconds < 500) {
            return;
          }
          lastBackupPct = pct;
          lastBackupAt = now;
          DownloadKeepAlive.updateProgress(
            'Backing up to your Drive',
            '$pct% · ${book.title}',
          );
        },
      );
      await metadata.upsertBook(
        bookId: book.bookId,
        title: book.title,
        source: 'drive',
        driveFileId: id,
        sha256: hash,
        sizeBytes: size,
        sectionCount: book.sectionCount,
        totalDurationMs: book.totalDurationMs,
        strict: true,
      );
    } finally {
      await keepAlive.release();
      if (await zip.exists()) await zip.delete();
    }
  }

  Future<void> restore(String bookId, Map<String, dynamic> record) async {
    if (sanitizeBookId(bookId) != bookId) {
      throw const FormatException('Invalid book identifier.');
    }
    if (await downloads.isDownloaded(bookId)) return;
    final id = record['driveFileId'];
    if (id is! String || id.isEmpty) {
      throw StateError(
        'This book has no Drive backup yet. Back it up on its original device.',
      );
    }
    await DriveSyncService.instance.ensureAccess();
    final zip = File(
      '${(await downloads.booksDir()).path}/.restore-$bookId.zip',
    );
    final keepAlive = await DownloadKeepAlive.acquire('Restoring from Drive');
    try {
      await DriveSyncService.instance.downloadBook(
        driveFileId: id,
        destPath: zip.path,
      );
      final expected = record['sha256'];
      if (expected is String &&
          expected.isNotEmpty &&
          (await sha256.bind(zip.openRead()).first).toString() != expected) {
        throw const FormatException(
          'Drive backup checksum mismatch. Back up the book again on its original device.',
        );
      }
      await downloads.extractZipToBook(
        zip.path,
        await downloads.bookDir(bookId),
      );
    } finally {
      await keepAlive.release();
      if (await zip.exists()) await zip.delete();
    }
  }
}

/// Streams package entries to a temporary ZIP outside the book directory.
Future<void> writeBookBackup(Directory book, File output) async {
  if (!await File('${book.path}/manifest.json').exists()) {
    throw const FormatException('A complete book manifest is required.');
  }
  await ZipFileEncoder().zipDirectory(
    book,
    filename: output.path,
    followLinks: false,
  );
}

/// Verify identity before replacing an incomplete local package.
Future<void> validateBookBackup(File zip, String bookId) async {
  final input = InputFileStream(zip.path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final manifest = archive.findFile('manifest.json');
    if (manifest == null || manifest.size > 10000000) {
      throw const FormatException('Drive backup has no valid book manifest.');
    }
    final decoded = jsonDecode(utf8.decode(manifest.content));
    if (decoded is! Map || decoded['book_id'] != bookId) {
      throw const FormatException('Drive backup belongs to a different book.');
    }
  } finally {
    await input.close();
  }
}
