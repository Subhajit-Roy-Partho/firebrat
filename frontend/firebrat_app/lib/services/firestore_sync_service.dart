import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/reading_checkpoint.dart';
import 'reading_progress_store.dart';

/// Private per-user library metadata and reading checkpoints. Book files stay
/// on the device or in user-owned Drive. Deployed rules: firebase/firestore.rules.
/// Spark quotas are shared across users; failures never prevent local reading.
class FirestoreSyncService {
  FirestoreSyncService._();
  static final FirestoreSyncService instance = FirestoreSyncService._();

  String? get _uid => AuthService.instance.currentUser?.uid;

  CollectionReference<Map<String, dynamic>>? _library() {
    final uid = _uid;
    if (uid == null) return null;
    try {
      return FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('library');
    } catch (_) {
      return null;
    }
  }

  Future<void> upsertBook({
    required String bookId,
    required String title,
    required String source,
    String? sha256,
    String? driveFileId,
    int? sizeBytes,
    int? sectionCount,
    int? totalDurationMs,
    bool strict = false,
  }) async {
    final col = _library();
    if (col == null) {
      if (strict) throw StateError('Sign in to sync metadata.');
      return;
    }
    try {
      if (!await _writeAllowed()) {
        if (strict) throw StateError('Enable metadata sync first.');
        return;
      }
      await col
          .doc(bookId)
          .set({
            'title': title,
            'source': source,
            'sha256': ?sha256,
            'driveFileId': ?driveFileId,
            'sizeBytes': ?sizeBytes,
            'sectionCount': ?sectionCount,
            'totalDurationMs': ?totalDurationMs,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true))
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      if (strict) rethrow;
    }
  }

  Future<void> touchOpened(String bookId) async {
    final col = _library();
    if (col == null) return;
    try {
      if (!await _writeAllowed()) return;
      await col.doc(bookId).set({
        'lastOpenedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> removeBook(String bookId) async {
    final col = _library();
    if (col == null) return;
    try {
      await col.doc(bookId).delete();
    } catch (_) {}
  }

  /// bookId -> record for everything this user ever registered.
  Future<Map<String, Map<String, dynamic>>> fetchLibrary({
    bool strict = false,
  }) async {
    final col = _library();
    if (col == null) return {};
    try {
      final snap = await col
          .limit(200)
          .get()
          .timeout(const Duration(seconds: 5));
      return {for (final d in snap.docs) d.id: d.data()};
    } catch (_) {
      if (strict) rethrow;
      return {};
    }
  }

  String? get currentUid => _uid;

  Future<bool> syncEnabled([String? uid]) async {
    final user = uid ?? _uid;
    if (user == null || _uid != user) return false;
    return (await SharedPreferences.getInstance()).getBool(
          'sync.enabled.$user',
        ) ??
        true;
  }

  Future<void> setSyncEnabled(bool value) async {
    final user = _uid;
    if (user != null) {
      await (await SharedPreferences.getInstance()).setBool(
        'sync.enabled.$user',
        value,
      );
    }
  }

  // Client budget complements Spark's hard project quotas; it is not a billing
  // guarantee on a Blaze project. This project must remain on Spark.
  Future<bool> _writeAllowed() async {
    final uid = _uid;
    if (uid == null || !await syncEnabled(uid)) return false;
    final prefs = await SharedPreferences.getInstance();
    final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final key = 'sync.writeBudget.$uid.$day';
    final count = prefs.getInt(key) ?? 0;
    if (count >= 500) {
      throw StateError(
        'Daily device sync limit reached. Local reading still works.',
      );
    }
    await prefs.setInt(key, count + 1);
    return true;
  }

  /// Upload durable checkpoints after reconnecting without opening every book.
  Future<void> flushPendingProgress() async {
    final uid = _uid;
    if (uid == null || !await syncEnabled(uid)) return;
    final prefs = await SharedPreferences.getInstance();
    final prefix = 'reader.checkpoint.$uid.';
    for (final key in prefs.getKeys().where(
      (key) => key.startsWith(prefix) && prefs.get(key) is String,
    )) {
      if (_uid != uid) return;
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        final checkpoint = ReadingCheckpoint.fromJson(
          jsonDecode(raw) as Map<String, dynamic>?,
        );
        if (checkpoint != null &&
            prefs.getInt('$key.uploaded') != checkpoint.updatedAtMs) {
          await writeProgress(
            key.substring(prefix.length),
            uid,
            checkpoint,
          ).timeout(const Duration(seconds: 5));
        }
      } on FormatException {
        continue;
      }
    }
  }

  ReadingProgressStore progressStore(String bookId) {
    final uid = _uid;
    return ReadingProgressStore(
      scope: uid ?? 'guest',
      bookId: bookId,
      enabled: () => syncEnabled(uid),
      readRemote: uid == null ? null : () => readProgress(bookId, uid),
      writeRemote: uid == null ? null : (p) => writeProgress(bookId, uid, p),
    );
  }

  Future<ReadingCheckpoint?> readProgress(String bookId, String uid) async {
    if (_uid != uid || !await syncEnabled(uid)) return null;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('progress')
        .doc(bookId)
        .get();
    return ReadingCheckpoint.fromJson(doc.data());
  }

  Future<bool> writeProgress(
    String bookId,
    String uid,
    ReadingCheckpoint value,
  ) async {
    if (_uid != uid || !await _writeAllowed()) return false;
    final db = FirebaseFirestore.instance;
    final doc = db
        .collection('users')
        .doc(uid)
        .collection('progress')
        .doc(bookId);
    final written = await db.runTransaction<bool>((transaction) async {
      final existing = ReadingCheckpoint.fromJson(
        (await transaction.get(doc)).data(),
      );
      // Do not replace a later checkpoint with a delayed older offline save.
      // Client timestamps assume reasonably synchronized device clocks.
      if (existing != null && existing.updatedAtMs > value.updatedAtMs) {
        return false;
      }
      transaction.set(doc, {
        ...value.toJson(),
        'serverUpdatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      'reader.checkpoint.$uid.$bookId.uploaded',
      value.updatedAtMs,
    );
    return written;
  }
}
