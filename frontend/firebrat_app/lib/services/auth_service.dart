import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Firebase Authentication for a wider audience: Google sign-in (plus
/// anonymous upgrade path later). The backend verifies the ID token on
/// every sensitive call (see `backend/server/auth.py`), so this class only
/// ever handles sign-in state + minting tokens — no custom auth logic.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  // Lazy: FirebaseAuth.instance throws when no Firebase app exists
  // (misconfigured build, or the flutter_test harness) — first access
  // happens inside authStateChanges()'s try/catch, never at class load.
  late final FirebaseAuth _auth = FirebaseAuth.instance;
  late final GoogleSignIn _google = GoogleSignIn.instance;

  Stream<User?> authStateChanges() {
    // Resilient: if Firebase isn't initialized (missing google-services
    // config, or the flutter_test harness with no platform channels), the
    // app must still open — signed out — instead of red-screening. The
    // failure surfaces ASYNCHRONOUSLY (on stream listen), so a sync
    // try/catch is not enough: map any stream error to a signed-out event.
    try {
      return _auth.authStateChanges().transform(
        StreamTransformer<User?, User?>.fromHandlers(
          handleError: (Object e, StackTrace st, EventSink<User?> sink) =>
              sink.add(null),
        ),
      );
    } catch (_) {
      return Stream.value(null);
    }
  }
  User? get currentUser => _auth.currentUser;

  /// Fresh ID token for `Authorization: Bearer` on API calls, or null
  /// when signed out (ApiClient then sends no header — server treats the
  /// call as anonymous, see `server/auth.py`).
  Future<String?> idToken({bool forceRefresh = false}) async {
    final user = _auth.currentUser;
    if (user == null) return null;
    try {
      return await user.getIdToken(forceRefresh);
    } catch (_) {
      return null;
    }
  }

  Future<UserCredential> signInWithGoogle() async {
    // google_sign_in v7: authenticate() then credential-based sign-in.
    final account = await _google.authenticate();
    _lastAccount = account;
    final auth = account.authentication;
    final credential = GoogleAuthProvider.credential(
      idToken: auth.idToken,
    );
    return _auth.signInWithCredential(credential);
  }

  GoogleSignInAccount? _lastAccount;

  /// The Google account, preferring a silent restore (returning user)
  /// before falling back to interactive sign-in. When [driveScope] is
  /// true, consent for Drive file access is requested as well —
  /// incremental: normal sign-in never asks for Drive.
  Future<GoogleSignInAccount?> signInSilentlyOrInteractiveDrive({bool driveScope = true}) async {
    if (_lastAccount != null) return _lastAccount;
    try {
      final silent = await _google.attemptLightweightAuthentication();
      if (silent != null) {
        _lastAccount = silent;
        if (!driveScope) return silent;
      }
    } catch (_) {}
    try {
      final account = await _google.authenticate(
        scopeHint: driveScope ? const ['https://www.googleapis.com/auth/drive.file'] : const [],
      );
      _lastAccount = account;
      return account;
    } catch (_) {
      return _lastAccount;
    }
  }

  GoogleSignInAccount? get currentGoogleUser => _lastAccount;

  Future<UserCredential> signInWithEmail(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email.trim(), password: password);

  Future<UserCredential> registerWithEmail(String email, String password) =>
      _auth.createUserWithEmailAndPassword(email: email.trim(), password: password);

  Future<void> signOut() async {
    try {
      await _google.signOut();
    } catch (_) {}
    await _auth.signOut();
  }
}
