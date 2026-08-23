# mobile_backend_pipeline

On-device PDF → audiobook conversion for Firebrat — the implementation of
the recommendation in [`PROPOSAL.md`](PROPOSAL.md) (read that first for the
research/reasoning behind these choices). This package runs entirely on
the phone: text extraction, LLM-based narration compilation (routed
between an on-device model and a user-configured cloud endpoint depending
on chunk difficulty), and TTS narration — writing output in the exact
on-disk layout `frontend/firebrat_app` already reads (`docs/DATA_SCHEMA.md`),
so a book converted here is indistinguishable to the reader app from one
downloaded off a server.

It has **zero dependency on `frontend/firebrat_app`** — the reverse
dependency goes the other way (the app depends on this package), so this
stays testable and usable in complete isolation.

## Why a separate package, not code inside the app

1. It can be `flutter test`ed on its own (see `test/`) without pulling in
   the whole app's widget tree.
2. It's a clean seam for the "is this even possible" research question the
   proposal answers — the app doesn't need to know or care whether a book
   came from a server, an imported file, or this pipeline.
3. Someone could reuse this in a different app entirely.

## Architecture

```
PDF
 │
 ▼
extraction/pdf_text_extractor.dart   — Syncfusion PdfTextExtractor, page text only
 │  (extraction/ocr_fallback.dart wired up for scanned pages, not yet wired
 │   to a page-rasterizer — see "Known limitations")
 ▼
compilation/chunker.dart             — groups pages into ~10-page chunks
 │
 ▼
compilation/routing.dart             — per chunk: does it look math-heavy?
 │                                      (same heuristic as compile_llm.py's
 │                                      _needs_strong_model)
 ├─ no  → compilation/on_device_compiler.dart  (Cactus, on-device model)
 └─ yes → compilation/cloud_compiler.dart      (user's own OpenAI-compatible endpoint)
 │
 ▼         both paths return the same shape, validated/sanitized by
 │         compilation/response_parser.dart (formula id minting, ref
 │         sanitization, blank-title fallback — mirrors compile_llm.py)
 ▼
tts/on_device_tts.dart               — flutter_tts per segment, assembled
 │                                      into one section audio file with
 │                                      sample-accurate timing via
 │                                      tts/wav_utils.dart (Android, WAV) /
 │                                      tts/caf_utils.dart (iOS, CAF)
 ▼
pipeline/mobile_conversion_pipeline.dart  — orchestrates the above, writes
                                             manifest.json + sections/*/
                                             (docs/DATA_SCHEMA.md shape)
```

## Known limitations (read before relying on this)

- **No figure/table extraction.** `figures`/`tables` in the produced
  manifest are always empty. There's no mature, lightweight, Flutter-usable
  layout-detection model today (see `PROPOSAL.md` §1a) — a future version
  could add DocLayout-YOLO via ONNX Runtime, but that's real, separate
  work, not wired up here. Math typeset as prose (this project's actual
  common case) is unaffected — the compilation LLM still authors LaTeX
  from text, same as the server pipeline.
- **No OCR-rasterization wiring.** `extraction/ocr_fallback.dart`'s ML Kit
  call is real and correct, but it needs a page-to-bitmap renderer (e.g.
  `pdfx`, or platform PDF APIs) that isn't plugged in yet — scanned
  (image-only) PDFs will produce near-empty pages rather than being OCR'd.
  Born-digital PDFs with a real text layer (the common case) are unaffected.
- **Fixed stock TTS voice, not a cloned narrator voice.** This uses the
  platform's built-in TTS engine (`flutter_tts`), not chatterbox-tts's
  voice-cloning-from-a-reference-clip. See `PROPOSAL.md` §1c for why:
  on-device voice cloning isn't mature enough today to trust for this.
- **iOS is unverified.** This whole package was written, and its Dart-only
  logic tested (`flutter test` — 22/22 passing at the time of writing), in
  a Linux sandbox with **no macOS/Xcode available at all** — not even a
  static build could be attempted for the iOS side. The Android path
  (`flutter analyze`, `flutter build apk` on the host app) is genuinely
  verified to compile; the iOS-specific parts — CAF audio parsing
  (`tts/caf_utils.dart`), and whatever CocoaPods/Xcode project changes the
  `cactus`/`google_mlkit_text_recognition`/`syncfusion_flutter_pdf` native
  iOS implementations need — have never been built. Treat iOS support as
  "should work, same Dart code, not proven" until someone with a Mac
  actually runs `pod install` + an Xcode build.
- **On-device LLM inference itself is unverified at runtime**, on both
  platforms — this sandbox has no `adb` (see `frontend/firebrat_app`'s
  `AGENTS.md`) and no physical device, so `CactusLM`'s actual model
  download/inference has never executed, only type-checked against the
  real `cactus` package API.

None of this is hidden inside the code — every one of these is called out
at the specific file/class where it matters, so a reader hits the caveat
right where the relevant decision was made, not just here.

## Integrating into the Flutter app

Already done in `frontend/firebrat_app` as a proof that this integrates
cleanly, not just in theory — see:

- `pubspec.yaml`: `mobile_backend_pipeline: {path: ../../mobile-Backend}`
- `lib/state/on_device_conversion_providers.dart`: persisted settings —
  cloud mode asks for a server URL; on-device mode asks for an LLM URL,
  API key, and model name (exactly the fields `OnDeviceModeSettings` needs).
- `lib/screens/conversion_settings_screen.dart`: the UI for the above.
- `lib/state/on_device_pipeline_run_provider.dart`: runs
  `MobileConversionPipeline` and writes into the same books directory
  `DownloadManager` already uses, so a finished on-device conversion shows
  up in the library exactly like a downloaded or imported book.
- `lib/screens/conversions_screen.dart`: the upload button now branches on
  the configured mode instead of always hitting the server.

`flutter analyze` and `flutter build apk --debug` both pass on the host
app with this wired in — see the top-level session notes for the actual
build log; not re-derived here to avoid this doc going stale as the app
changes around it.

## Running this package's own tests

```bash
cd mobile-Backend
flutter test        # pure-Dart logic: ids, routing heuristic, JSON
                     # response parsing/sanitization, WAV assembly —
                     # no device/plugin dependency, these actually run here
flutter analyze      # type-checks the plugin-dependent code too (Cactus,
                      # ML Kit, Syncfusion, flutter_tts) without needing a device
```
