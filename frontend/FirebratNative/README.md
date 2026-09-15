# FirebratNative — Apple-native SwiftUI MVP

Fresh Xcode iOS app (SwiftUI lifecycle, `FirebratNative.xcodeproj`). It does
**not** reuse `frontend/firebrat_app/ios/Runner` — separate bundle
(`com.firebrat.native`), separate storage, same server API and same
UserDefaults keys (so prefs stay in sync if both apps are installed).

Open `FirebratNative.xcodeproj` in Xcode 16+, pick an iPhone simulator
(running a Firebrat server at `http://localhost:8000`), and Run. No SPM
dependencies — everything is SwiftUI / AVFoundation / Compression framework.

## Layout

```
FirebratNative/
├── FirebratNativeApp.swift        entry + M3-seed indigo tint
├── Models/
│   ├── Manifest.swift             manifest Codable, tolerant defaults
│   ├── Segment.swift              segments + activeAt binary search
│   ├── BookSummary.swift          GET /books entry (+ local-from-manifest)
│   └── ConversionJob.swift        job model (queue UI deferred)
├── Networking/
│   └── APIClient.swift            URLSession async/await: health, books,
│                                  manifest, delete, zip download+progress
├── Stores/
│   ├── AppSettings.swift          UserDefaults, same keys as Flutter
│   ├── BookStore.swift            Application Support/books/<id>/,
│   │                              local-first list, download→extract→verify,
│   │                              document-picker import, delete
│   └── ArchiveReader.swift        .zip inflate + .tar.gz (gzip + minimal TAR),
│                                  no third-party deps, traversal-safe
│   └── Inflate.swift              pure-Swift DEFLATE (RFC 1951) backing both
├── Playback/
│   ├── PlayerEngine.swift         AVPlayer singleton, 100ms observer →
│   │                              deduped active segment, end-of-item autoplay
│   │                              hook, speed/scrub/segment seek
│   └── NowPlaying.swift           MPNowPlayingInfoCenter + remote commands;
│                                  art swaps only on visual-id change
└── Views/
    ├── LibraryView.swift          local primary, remote best-effort, progress,
    │                              delete, document-picker import
    ├── ReaderView.swift           section nav, sticky visual header
    │                              (formula PNG primary), segment highlight +
    │                              tap-seek, playback bar
    └── SettingsView.swift         server URL + health, speed, autoplay+delay,
                                   text size
```

## What runs in this MVP

- Library from on-device manifests (offline-first), remote catalog
  best-effort, zip download with progress, delete, .zip/.tar.gz import.
- Reader: section navigation, live segment highlight synced to `audio.m4a`
  position, tap-to-seek, sticky visual header (formula PNG + spoken text,
  else figure/table image + caption), speed 0.75–2.0, scrub, segment skip.
- End-of-section autoplay with the configured delay (skipped if you
  navigated away mid-delay).
- Lock screen / Control Center / headset: title, art (swapped only when the
  spoken visual changes), play/pause, segment prev/next, scrub.
- Settings persisted under the Flutter app's keys
  (`reader.*`, `conversion.cloudServerUrl`).

## Deferred (per plan)

- Conversions queue UI (`ConversionJob` model is ready for it).
- On-device conversion engine.
- FocusMode split — the sticky visual header in the reader IS the focus
  visual for now.
- Zoomable figure gallery, vector math rendering, alternate icons.

## Validation

Two checks, both runnable without a device:

1. **Logic tests** (`swiftc`, Foundation-only sources):
   `Models/*.swift` + `Stores/ArchiveReader.swift` decode a schema-shaped
   manifest/segments pair, cross-check `activeAt` binary search against a
   linear scan, and round-trip real `.zip` (Python zipfile, deflated) and
   `.tar.gz` (Python tarfile, PAX) packages through the extractor.
2. **Full build**: `xcodebuild -project … -scheme FirebratNative
   -sdk iphonesimulator -configuration Debug build` (see scaffold commit).
   `audio.m4a` segment-highlight mapping is covered by (1) plus the periodic
   observer path in `PlayerEngine`, which compiles in (2).
