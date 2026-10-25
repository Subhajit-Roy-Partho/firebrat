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
  User? get currentUser {
    try {
      return _auth.currentUser;
    } catch (_) {
      return null;
    }
  }

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

  /// Normalized identity comparison for the Drive gate.
  ///
  /// Device keyboards/autofill can leave stray whitespace and providers
  /// differ in case (`Me.Name@Gmail.com` vs `me.name@gmail.com`), so both
  /// sides are trimmed + lowercased before comparison. Returns null for
  /// null/blank input so callers treat "no email" as signed-out.
  static String? normalizeEmail(String? email) {
    if (email == null) return null;
    final trimmed = email.trim().toLowerCase();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// True when both emails normalize to the same non-empty value.
  static bool emailsMatch(String? a, String? b) {
    final na = normalizeEmail(a);
    final nb = normalizeEmail(b);
    return na != null && na == nb;
  }

  /// The Google account, preferring a silent restore (returning user)
  /// before falling back to interactive sign-in. When [driveScope] is
  /// true, consent for Drive file access is requested as well —
  /// incremental: normal sign-in never asks for Drive.
  ///
  /// When [expectedEmail] (the Firebase identity, normalized by the
  /// caller) is provided and the cached/silent account belongs to a
  /// *different* Google account, the stale Google session is signed out
  /// first: google_sign_in v7 reuses the cached account across
  /// [authenticate] calls, so without a [GoogleSignIn.signOut] the
  /// account chooser never appears and the mismatch can never be fixed
  /// (20+ accounts on one device makes the wrong restore likely).
  Future<GoogleSignInAccount?> signInSilentlyOrInteractiveDrive(
      {bool driveScope = true, String? expectedEmail}) async {
    final want = normalizeEmail(expectedEmail);
    final cached = _lastAccount;
    if (cached != null && (want == null || emailsMatch(cached.email, want))) {
      return cached;
    }
    try {
      final silent = await _google.attemptLightweightAuthentication();
      if (silent != null) {
        _lastAccount = silent;
        if (emailsMatch(silent.email, want ?? silent.email)) {
          if (want == null || !driveScope) return silent;
          // Same account, Drive escalation happens via
          // authorizationClient.authorizeScopes in DriveSyncService._api —
          // fall through to the interactive consent only when the
          // account is wrong (handled below), otherwise return here.
          return silent;
        }
        // Silent restore belongs to the wrong Google account: drop it so
        // the interactive step below shows the account chooser instead
        // of reusing it.
        await signOutGoogleOnly();
      }
    } catch (_) {}
    // A stale in-memory account that matches nothing: drop it for the
    // same reason before asking interactively.
    if (cached != null && want != null && !emailsMatch(cached.email, want)) {
      await signOutGoogleOnly();
    }
    try {
      final account = await _google.authenticate(
        scopeHint: driveScope ? const ['https://www.googleapis.com/auth/drive.file'] : const [],
      );
      _lastAccount = account;
      return account;
    } catch (_) {
      return _lastAccount != null &&
              (want == null || emailsMatch(_lastAccount!.email, want))
          ? _lastAccount
          : null;
    }
  }

  /// Resolve the Google account used for Drive, reconciling it with the
  /// Firebase identity. Thin wrapper kept explicit for the Drive gate so
  /// the recovery intent reads clearly at the call site.
  Future<GoogleSignInAccount?> resolveGoogleAccountForDrive({
    required String? expectedEmail,
    bool driveScope = true,
  }) =>
      signInSilentlyOrInteractiveDrive(
        driveScope: driveScope,
        expectedEmail: expectedEmail,
      );

  /// Drop the cached Google session without touching Firebase sign-in,
  /// so the next interactive authenticate shows the account chooser.
  Future<void> signOutGoogleOnly() async {
    _lastAccount = null;
    try {
      await _google.signOut();
    } catch (_) {}
  }

  GoogleSignInAccount? get currentGoogleUser => _lastAccount;

  Future<UserCredential> signInWithEmail(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email.trim(), password: password);

  Future<UserCredential> registerWithEmail(String email, String password) =>
      _auth.createUserWithEmailAndPassword(email: email.trim(), password: password);

  Future<void> signOut() async {
    await signOutGoogleOnly();
    await _auth.signOut();
  }
}
