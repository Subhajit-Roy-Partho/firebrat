import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'auth_service.dart';

/// Thrown for problems the user can act on (not signed in, empty review...).
class CommunityException implements Exception {
  CommunityException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One public review (a `books/{id}/comments/{cid}` document).
class CommunityReview {
  CommunityReview({
    required this.id,
    required this.uid,
    required this.name,
    required this.text,
    required this.createdAt,
  });

  factory CommunityReview.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    return CommunityReview(
      id: d.id,
      uid: (m['uid'] as String?) ?? '',
      name: (m['name'] as String?)?.trim().isNotEmpty == true ? m['name'] as String : 'Listener',
      text: (m['text'] as String?) ?? '',
      createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  final String id;
  final String uid;
  final String name;
  final String text;
  final DateTime? createdAt;
}

/// Ratings, reviews and bookmarks ("saved") for the Community library.
/// Every write mirrors `community/src/data.js` so it satisfies the same rules in
/// `firebase/firestore.rules` (rating aggregate and comment counter move in the
/// same batch as the rating / comment document).
class CommunityService {
  CommunityService._();
  static final CommunityService instance = CommunityService._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  User? get user {
    try {
      return FirebaseAuth.instance.currentUser;
    } catch (_) {
      return null;
    }
  }

  Stream<User?> authChanges() => AuthService.instance.authStateChanges();

  User _need() {
    final u = user;
    if (u == null) throw CommunityException('Sign in to do that.');
    return u;
  }

  DocumentReference<Map<String, dynamic>> _book(String id) => _db.collection('books').doc(id);

  // ——— ratings ———

  /// The signed-in user's own rating for [bookId] (null when none / signed out).
  Stream<int?> myRating(String bookId) {
    final u = user;
    if (u == null) return Stream.value(null);
    return _book(bookId)
        .collection('ratings')
        .doc(u.uid)
        .snapshots()
        .map((s) => (s.data()?['value'] as num?)?.toInt());
  }

  /// Sets (or changes) the user's 1-5 star rating. The book's running totals are
  /// updated in the same batch, as the security rules require.
  Future<void> rate(String bookId, int value) async {
    final u = _need();
    if (value < 1 || value > 5) throw CommunityException('Rating must be 1–5 stars.');
    final bookRef = _book(bookId);
    final ratingRef = bookRef.collection('ratings').doc(u.uid);
    final prev = await ratingRef.get();
    if (!(await bookRef.get()).exists) throw CommunityException('Book not found.');
    final prevValue = (prev.data()?['value'] as num?)?.toInt() ?? 0;
    final batch = _db.batch();
    batch.set(ratingRef, {'value': value, 'updatedAt': FieldValue.serverTimestamp()});
    batch.update(bookRef, {
      'ratingSum': FieldValue.increment(value - prevValue),
      'ratingCount': FieldValue.increment(prev.exists ? 0 : 1),
    });
    await batch.commit();
  }

  // ——— reviews ———

  Stream<List<CommunityReview>> reviews(String bookId, {int limit = 30}) {
    // Rules expose only visible comments, so the query has to say so.
    return _book(bookId)
        .collection('comments')
        .where('status', isEqualTo: 'visible')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(CommunityReview.fromDoc).toList());
  }

  Future<void> addReview(String bookId, String text) async {
    final u = _need();
    final t = text.trim();
    if (t.isEmpty) throw CommunityException('Write something first.');
    if (t.length > 2000) throw CommunityException('Reviews are limited to 2000 characters.');
    final raw = (u.displayName ?? '').trim();
    final name = raw.isEmpty ? 'Listener' : (raw.length > 80 ? raw.substring(0, 80) : raw);
    final batch = _db.batch();
    batch.set(_book(bookId).collection('comments').doc(), {
      'uid': u.uid,
      'name': name,
      'text': t,
      'status': 'visible',
      'createdAt': FieldValue.serverTimestamp(),
      'reportCount': 0,
    });
    batch.update(_book(bookId), {'commentCount': FieldValue.increment(1)});
    await batch.commit();
  }

  Future<void> deleteReview(String bookId, String reviewId) async {
    _need();
    final batch = _db.batch();
    batch.delete(_book(bookId).collection('comments').doc(reviewId));
    batch.update(_book(bookId), {'commentCount': FieldValue.increment(-1)});
    await batch.commit();
  }

  /// Flags a review for the admins (reason: offensive | spam | harassment | misleading | other).
  Future<void> reportReview(String bookId, String reviewId, String reason) async {
    final u = _need();
    await _db.collection('reports').add({
      'kind': 'comment',
      'bookId': bookId,
      'commentId': reviewId,
      'reason': reason,
      'details': '',
      'reporterUid': u.uid,
      'createdAt': FieldValue.serverTimestamp(),
      'resolved': false,
    });
  }

  // ——— bookmarks ("saved") ———

  /// Ids of the books the signed-in user has saved (empty when signed out).
  Stream<Set<String>> favorites() {
    final u = user;
    if (u == null) return Stream.value(<String>{});
    return _db
        .collection('users')
        .doc(u.uid)
        .collection('favorites')
        .snapshots()
        .map((s) => s.docs.map((d) => d.id).toSet());
  }

  Future<void> setFavorite(String bookId, bool saved) async {
    final u = _need();
    final ref = _db.collection('users').doc(u.uid).collection('favorites').doc(bookId);
    if (saved) {
      await ref.set({'addedAt': FieldValue.serverTimestamp()});
    } else {
      await ref.delete();
    }
  }
}
