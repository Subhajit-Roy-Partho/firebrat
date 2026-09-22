import 'package:cloud_firestore/cloud_firestore.dart';
import 'auth_service.dart';

/// Cross-device library metadata in Firestore *Database* (not Storage):
/// which books a user has, where each came from, when it was last opened.
/// Book *blobs* live in Drive (`DriveSyncService`) or on the server — this
/// collection is kilobytes of JSON, far inside the free tier.
///
/// Document shape: users/{uid}/library/{bookId} ->
///   {title, source: 'server'|'drive'|'import', sha256?, updatedAt, lastOpenedAt}
/// Security rules (console → Firestore → Rules — one paste, in docs):
///   match /users/{userId}/{document=**} {
///     allow read, write: if request.auth != null && request.auth.uid == userId;
///   }
///
/// Local state stays the source of truth on-device (works offline); this
/// is only the meeting point a new device reads on first login.
class FirestoreSyncService {
  FirestoreSyncService._();
  static final FirestoreSyncService instance = FirestoreSyncService._();

  String? get _uid => AuthService.instance.currentUser?.uid;

  CollectionReference<Map<String, dynamic>>? _library() {
    final uid = _uid;
    if (uid == null) return null;
    try {
      return FirebaseFirestore.instance.collection('users').doc(uid).collection('library');
    } catch (_) {
      return null;
    }
  }

  Future<void> upsertBook({
    required String bookId,
    required String title,
    required String source,
    String? sha256,
  }) async {
    final col = _library();
    if (col == null) return;
    try {
      await col.doc(bookId).set({
        'title': title,
        'source': source,
        'sha256': sha256,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> touchOpened(String bookId) async {
    final col = _library();
    if (col == null) return;
    try {
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
  Future<Map<String, Map<String, dynamic>>> fetchLibrary() async {
    final col = _library();
    if (col == null) return {};
    try {
      final snap = await col.get();
      return {for (final d in snap.docs) d.id: d.data()};
    } catch (_) {
      return {};
    }
  }
}
