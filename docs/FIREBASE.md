# Firebase — Auth + Push for Firebrat

Status (2026-09-18): wired end to end. Project `firebrat-8c597`, Android app
`com.firebrat.firebrat_app` (ID `1:657440934081:android:ffa7b93d66d61efd1bac40`),
release SHA-1 registered, `google-services.json` in place (gitignored) and
in CI secrets. Remaining: enable Google sign-in (one console click, below)
and optionally a service-account key for server-side push.

## What the app does

- `lib/firebase_options.dart` — hand-written options mirroring
  `android/app/google-services.json` (flutterfire_cli was never run).
- `lib/services/auth_service.dart` — Google sign-in (`google_sign_in` v7
  `instance.authenticate()` API), sign-out, ID-token minting. Degrades to
  signed-out instead of red-screening when Firebase is unavailable.
- `lib/screens/sign_in_screen.dart` + `AuthGate` in `lib/app.dart` —
  signed-out users sign in; the stream flips to the library on login.
- `lib/services/api_client.dart` — Dio interceptor attaches
  `Authorization: Bearer <ID token>` when signed in (unsigned otherwise).
- `lib/services/notification_service.dart` — FCM permission, `new-books`
  topic, foreground re-display via `flutter_local_notifications` v22
  (named-parameter API), `@pragma('vm:entry-point')` background handler.
- `lib/state/conversions_providers.dart` — subscribes `job-<id>` on
  upload/retry/resume, unsubscribes at terminal state, raises a local
  notification from the already-polled job state (works keyless).

## What the server does (`backend/server/auth.py`)

- READS stay open: `/books`, manifest, assets, `/download`, `/checksum`,
  `/health` — anonymous shelf browsing for a wider audience.
- MUTATIONS need a Firebase user: upload, jobs list/detail/retry/resume/
  log, book delete. `require_user` dependency → 401 otherwise. (Any
  signed-in user for now — job rows carry no owner; per-user libraries
  are a future step, stated in code.)
- `verify_id_token` needs NO credentials file (Google public certs);
  `firebase-admin` is in the serve env. FCM *sending* additionally needs
  `GOOGLE_APPLICATION_CREDENTIALS` — without it `notify_topic` logs and
  no-ops, and `job_runner` still notifies via topic when keyed.
- Tests: `tests/conftest.py` overrides `require_user` with a fixed
  test user; `tests/test_auth.py` proves 401s + open reads + verifier
  rejection of garbage.

## CI

`GOOGLE_SERVICES_JSON` repo secret (base64) is decoded to
`android/app/google-services.json` in both `flutter-release.yml` and
`ci.yml` — the google-services Gradle plugin (4.4.4, applied in
`settings.gradle.kts` + app `build.gradle.kts`) fails the build without
the file. Same pattern as the release keystore.

## Still manual (console)

1. **Enable Google sign-in:** console → Build → Authentication → Get
   started → Sign-in method → enable **Google**. (Everything else —
   project, Android app, SHA-1, OAuth client — was done via CLI; Auth
   itself has no CONFIGURATION until this click. Until then,
   `signInWithCredential` fails `operation-not-allowed` and the app
   shows the error inline, still fully usable signed-out for reads.)
2. **Server push key (optional):** Project settings → Service accounts →
   Generate new private key → set `GOOGLE_APPLICATION_CREDENTIALS` to it
   on the server host (and/or a matching secret for Docker). Without it,
   job-done pushes only arrive via the app's own poll-raised local
   notification — no crash, no missing feature, just no background push.
