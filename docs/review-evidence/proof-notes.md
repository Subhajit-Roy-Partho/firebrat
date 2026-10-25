# Play review evidence — foreground-service demo videos

Captured 2026-10-24 (UTC-7) on Pixel 55201JEBF00569. The device screen was
unlocked (keyguard `showing=false`); nothing was uninstalled, no app data was
cleared, no books were deleted, and no production upload was started.

## Build under test

- App: `com.firebrat.firebrat_app` (as installed on the device)
- versionName: **1.6.4**, versionCode: **27** (`adb dumpsys package`)
- `pubspec.yaml:19`: `version: 1.6.4+27`
- targetSdk: **36** (`adb dumpsys package`; `build.gradle.kts` uses
  `flutter.targetSdkVersion`)
- Source: branch `codex/play-store`, commit `9bc39ad`

## Clips (in `docs/review-evidence/`)

1. `play_review_data_sync.mp4` — 14.9 MB, 62.5 s, device `screenrecord`
   (DATA_SYNC foreground service). Shows: Library → navigation drawer →
   **Sync & backup** → explicit user tap on **“Back up to my Drive”** for the
   small sample book **“peter rabbit review” (3 sections, NOT the 1.1 GB
   digital-design book)** → “Preparing backup in your Drive…” progress →
   “Sync complete. Book files remain in your own Drive.” with the book row
   flipping to “Drive backup available”.
2. `play_review_media_playback.mp4` — 25.5 MB, 55.8 s, device `screenrecord`
   (MEDIA_PLAYBACK foreground service). Shows: Library → open
   **“peter rabbit review”** reader → explicit user tap on **Play** →
   in-app playback advancing (autoplay carried Sections 1→3, position/seekbar
   moving) → notification shade pulled down showing the media notification
   **“Section 1 by peter rabbit review is playing from Firebrat”** with Pause
   control → shade dismissed back to the in-app player.
   Both clips verified playable: valid `ftyp` + `moov/mvhd` with the durations
   above (parsed from the files, no ffprobe on this host).

## Screenshots (in `docs/review-evidence/`)

- `sync_backup_progress.png` — “Preparing backup in your Drive…” mid-backup.
- `sync_backup_done.png` — “Sync complete…” + “Drive backup available”.
- `playback_inapp.png` — reader with playback controls active.
- `playback_notification.png` — shade open with the Firebrat media notification.

## Privacy-policy URLs (Play Data safety / policy)

- Privacy policy: https://subhajit-roy-partho.github.io/firebrat/privacy/
  (verified HTTP 200, effective 24 October 2026)
- Data use and safety: https://subhajit-roy-partho.github.io/firebrat/data-safety/
- Account/data deletion: https://subhajit-roy-partho.github.io/firebrat/delete-account/
- Support and bug reporting: https://subhajit-roy-partho.github.io/firebrat/support/

## Internal testing opt-in

- https://play.google.com/apps/internaltest/4701750160663480733
