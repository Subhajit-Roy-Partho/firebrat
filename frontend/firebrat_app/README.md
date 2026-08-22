# firebrat_app — Flutter reader

Android-first Flutter `3.41.3` app that plays Firebrat book packages offline.

## What it does

- Downloads `GET /books/{id}/download` zip from `backend/server` once, extracts to app storage, then fully offline.
- Reader screen (`lib/ui/reader/reader_screen.dart`) shows section gallery (`FigureGallery`), rendered formula (`flutter_math_fork`) highlighted per active segment, and transport controls.
- Highlight sync via `lib/services/playback_controller.dart` binary search over `segments.json` `start_ms`/`end_ms` driven by `just_audio` `positionStream`; autoplay via `sectionCompleteStream` with configurable delay `lib/state/reader_providers.dart:1` (`ReaderController` `NotifierProvider.family` pattern for Riverpod `^3.3.2` — see `AGENTS.md` note).
- State: `library_providers.dart` (catalog/downloads), `reader_providers.dart` (session), `settings_providers.dart` (speed/font scale via `shared_preferences`).

## Quick verify

```bash
cd frontend/firebrat_app
flutter analyze        # clean
flutter test           # 6 pure-Dart segment_sync tests
flutter build apk --debug   # release needs 6GB cgroup free — don't run alongside conversion pipeline
```

`FIREBRAT_API_BASE_URL` dart-define selects backend host: `flutter run --dart-define=FIREBRAT_API_BASE_URL=http://<host>:8000`. Current 242-section archive `backend/output/arm-fundamentals-soc.tar.gz` (430.5 MB, 441.6 min) imports and plays via `ImportManager`.
