# App Icon — Firebrat Worm Listening to a Book

## Current icon

`frontend/firebrat_app/assets/icon/app_icon.svg` (1024×1024, rounded `rx 224`) is the source of truth. PNGs are generated via `rsvg-convert`:

```bash
rsvg-convert -w 1024 -h 1024 assets/icon/app_icon.svg -o assets/icon/app_icon.png
rsvg-convert -w 1024 -h 1024 assets/icon/app_icon_foreground.svg -o assets/icon/app_icon_foreground.png
# Then
dart run flutter_launcher_icons
```

Adaptive icon: `flutter_launcher_icons.yaml` → `android: ic_launcher` with `adaptive_icon_background` + `adaptive_icon_foreground`. The foreground is the same worm/book/headphones inset by 16% (`mipmap-anydpi-v26/ic_launcher.xml`). Regenerating updates all `mipmap-*` / `drawable-*` variants.

Design: deep indigo gradient background, open warm-paper book (center), headphones draped over the book, sound waves from the right cup, and a **firebrat worm perched on the headband, eyes closed in a very happy `^ ^` smile, rosy cheeks, tiny arms holding the book edge** — “a worm listening, opening a book”. Sparkles convey joy. See `assets/icon/app_icon.svg:68` for the worm group.

## Mood variants (usage-driven)

Four moods live in `assets/icon/moods/` (SVG + 512×512 PNG):

| Mood | File | Trigger (`AppIconService:10`) | Visual |
|---|---|---|---|
| `happy` | `app_icon.svg` | Default (<15 min listening, <24h since open) | Closed happy eyes `^ ^`, big smile, rosy cheeks |
| `focused` | `moods/app_icon_focused.svg` | ≥15 min total listening | Wide open eyes, eyebrows, determined mouth |
| `sleepy` | `moods/app_icon_sleepy.svg` | ≥24h since last open | Half-closed eyes, `Zzz`, yawn |
| `celebratory` | `moods/app_icon_celebratory.svg` | Book just finished | Party hat, confetti, star eyes |
| `streak` | `moods/app_icon_streak.svg` | ≥3-day streak | Sunglasses, flame badge `🔥` |

In-app mood is shown immediately via `AppIconService.instance.currentMood()` (`lib/services/app_icon_service.dart:1`) — e.g. library header:

```dart
final mood = await AppIconService.instance.currentMood();
Image.asset(mood.assetPath, width: 96, height: 96)
```

Record usage:

```dart
await AppIconService.instance.recordAppOpen();          // on app start
await AppIconService.instance.recordListening(duration); // after each section
await AppIconService.instance.recordBookFinished();      // on book complete
```

### Home-screen icon swap (optional)

Android adaptive icons cannot change at runtime without an `activity-alias` per variant. To make the *launcher* icon itself change with mood:

1. Add to `AndroidManifest.xml` (one alias per mood, `enabled="false"` by default).
2. At runtime, enable the alias matching `currentMood()` via `PackageManager.setComponentEnabledSetting` (requires `android.permission.CHANGE_COMPONENT_ENABLED_STATE` via platform channel or `flutter_dynamic_icon`).

This repo currently implements **in-app** mood only (no alias yet) — the launcher stays `happy`. Adding aliases is tracked as a follow-up.

## Editing

- Edit `app_icon.svg` directly (or the mood SVGs). Keep `viewBox 0 0 1024 1024`, background `rx 224`, and the worm at `translate(512 340) rotate(-5)` for consistency.
- After editing SVGs, re-export PNGs with `rsvg-convert` and run `dart run flutter_launcher_icons` to refresh `mipmap-*`.
- Validate: `flutter analyze` and `flutter test` — icon changes have no Dart impact but the build must still pass.
