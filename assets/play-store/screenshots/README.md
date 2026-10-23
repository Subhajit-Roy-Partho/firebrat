# Play listing previews

These 1080 × 1920 PNGs are captured from the actual Flutter `LibraryScreen` and `ConversionSettingsScreen` widgets using Flutter's widget renderer at a 360 × 640 logical viewport and a 3× pixel ratio. Roboto and Material Icons are explicitly loaded.

They are **widget-rendered previews, not Android device screenshots or device-test evidence**. No image-generation tool or invented UI is used. The library uses illustrative sample metadata for public-domain books: Alice's Adventures in Wonderland, Pride and Prejudice, The Adventures of Sherlock Holmes, and Frankenstein. Durations and sizes are demonstration data, not conversion benchmark measurements. No book text or third-party covers are included.

- `01-library-small-cards.png`: actual small-card library and built-in default cover art.
- `02-offline-conversion-settings.png`: actual on-device mode and novel book settings.
- `03-novel-voices.png`: actual Kokoro narrator and character voice controls.

Reproduce from `frontend/firebrat_app` on this Mac:

```sh
flutter test test/store_preview_capture_test.dart --dart-define=CAPTURE_STORE_PREVIEWS=true
```

The helper is opt-in and performs no capture without the define. Its font paths currently use the local Homebrew Flutter SDK. Replace these with the local SDK paths when running elsewhere. Captures passed the widget renderer without Flutter layout exceptions and were visually inspected with the proper icon font.
