# Firebase — Push Notifications for Firebrat

Firebrat currently uses two notification paths:

1. **Telegram** (`backend/firebrat/pipeline/notify.py`) — pipeline progress pings for the developer/operator (`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`). This is already configured via `~/.zshrc` and `backend/.env` (see `docs/ENV.md`). It is *operator-facing*, not end-user.
2. **Local Android notifications** — `audio_service` (playback controls) + `flutter_foreground_task` (on-device conversion `Converting…` persistent notification). These require `POST_NOTIFICATIONS` + `FOREGROUND_SERVICE` permissions already in `AndroidManifest.xml:8`. No Firebase needed for these.

If you want **remote push notifications** (e.g. “Your book is ready” when a server conversion finishes while the app is in background), add **Firebase Cloud Messaging (FCM)** as below. This is optional — the app and pipeline work without it.

## What you need to do in the Firebase Console

### 1. Create / select a Firebase project

1. Go to **https://console.firebase.google.com** → *Add project* (or select existing).
2. Name: `firebrat` (any). Disable Google Analytics if you don't need it.
3. Wait for provisioning.

### 2. Register the Android app

1. In Project Overview → *Project settings* → *Your apps* → **Add app** → Android.
2. **Android package name:** `com.firebrat.firebrat_app` (must match `android/app/build.gradle.kts: applicationId`).
3. **App nickname:** `Firebrat` .
4. **SHA-1:** leave blank for debug; for release, add your keystore SHA-1 (`keytool -list -v -keystore ~/.keystore`).
5. **Download `google-services.json`** → save to `frontend/firebrat_app/android/app/google-services.json` (gitignored — never commit the real file; commit `google-services.json.example` instead).

### 3. Enable Cloud Messaging

1. Left nav → *Build* → *Cloud Messaging* (or *Engagement* → *Messaging*).
2. No extra enable step is needed on the new console — FCM is on by default.
3. Note the **Server key / Sender ID** is now managed via *Project settings* → *Cloud Messaging* → *Firebase Cloud Messaging API (V1)*. If you use the backend to send via FCM HTTP v1, you will need a **service account** JSON (see backend section below).

### 4. APNs (iOS) — only if you target iOS

1. *Project settings* → *Cloud Messaging* → *Apple app configuration* → Upload APNs key (from Apple Developer → *Certificates, Identifiers & Profiles* → *Keys*).

## What to do in the repo

### Flutter app

Add to `frontend/firebrat_app/pubspec.yaml`:

```yaml
dependencies:
  firebase_core: ^3.8.0
  firebase_messaging: ^15.1.3
  flutter_local_notifications: ^18.0.1  # for foreground display
```

Then:

```bash
cd frontend/firebrat_app
flutter pub get
# Install Firebase CLI if not already
npm i -g firebase-tools
firebase login
flutterfire configure --project=firebrat --platforms=android,ios
# This generates firebase_options.dart and updates build files
```

Update `lib/main.dart` before `runApp`:

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Request permission (Android 13+ and iOS)
  await FirebaseMessaging.instance.requestPermission();
  // Handle background
  FirebaseMessaging.onBackgroundMessage(_bgHandler);
  // On-device conversion runner still uses flutter_foreground_task for its own persistent notification
  runApp(...);
}

@pragma('vm:entry-point')
Future<void> _bgHandler(RemoteMessage m) async {}
```

Android `android/app/build.gradle.kts` — add after `com.android.application`:

```kts
plugins {
  id("com.google.gms.google-services")
}
```

and `android/build.gradle.kts`:

```kts
plugins {
  id("com.google.gms.google-services") version "4.4.2" apply false
}
```

No change to `AndroidManifest.xml` is needed — FCM adds its service automatically.

### Backend (optional — send “book ready” push)

If `FIREBASE_SERVICE_ACCOUNT_JSON` env points to a service-account file, `server/routes/jobs.py` can send on `status=done` via FCM HTTP v1:

```python
# pip install firebase-admin
import firebase_admin
from firebase_admin import messaging, credentials
cred = credentials.Certificate(os.environ["FIREBASE_SERVICE_ACCOUNT_JSON"])
firebase_admin.initialize_app(cred)
messaging.send(messaging.Message(
    topic=f"book-{book_id}",
    notification=messaging.Notification(title="Firebrat", body=f"{title} is ready"),
))
```

The app would `subscribeToTopic("book-${bookId}")` after upload.

## Verifying

1. Build: `flutter build apk --debug` — should succeed with `google-services.json` present; without it Gradle fails with `File google-services.json is missing`.
2. Run on device → logcat `adb logcat | grep Firebase` should show `FirebaseApp initialization successful`.
3. Console → *Cloud Messaging* → *Send test message* → paste FCM token (log it via `FirebaseMessaging.instance.getToken().then(print)`) → device should receive notification even when app is backgrounded.

## Current repo state

- No `google-services.json` is committed (and none is required to build the debug APK without FCM — local notifications work without it).
- No `firebase_*` dependencies are in `pubspec.yaml` yet — add them only when you need remote push. The `docs/ENV.md` lists the new `FIREBASE_*` env vars if you do.
