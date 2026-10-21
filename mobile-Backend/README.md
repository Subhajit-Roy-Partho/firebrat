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
                                              (docs/DATA_SCHEMA.md shape),
                                              including `source.pdf` (a copy of
                                              the input PDF) with manifest
                                              `source_pdf_path` + per-section
                                              `source_pages`, so the reader's
                                              "View source page" works for
                                              on-device conversions too
```

### Background execution + notifications

`background/` wraps the pipeline above in `flutter_foreground_task` so a
conversion survives the app being backgrounded — or, on Android, even
swiped out of recents — instead of getting killed a few seconds after the
user leaves the app, which a multi-minute-to-hours book conversion would
otherwise hit constantly.

- `background/conversion_request.dart` — the pipeline's inputs, handed
  across the isolate boundary as a JSON file (see its doc comment for why:
  `TaskHandler` runs in a genuinely separate isolate that does not share
  memory with the main one).
- `background/conversion_task_handler.dart` — the `TaskHandler` subclass
  that actually runs `MobileConversionPipeline.convert()` inside that
  isolate, forwarding progress to the main isolate and updating the
  persistent notification live.
- `background/background_conversion_runner.dart` — the app-facing API:
  `initialize()` once at startup, `requestPermissions()` +  `start(request)`
  per conversion, `addProgressListener`/`removeProgressListener` to observe
  it from the UI.

**Platform reality, not a design choice**: Android gets a real foreground
service — this is the one that actually delivers "keeps running in the
background." iOS's version of this plugin is much weaker by OS design (not
this package's limitation, `flutter_foreground_task`'s iOS docs are explicit
about it): background execution happens in short bursts (~30s roughly every
~15min) and stops immediately if the user force-closes the app from the
app switcher. An iOS on-device conversion should be expected to need the
app kept open (or at least not force-closed) to finish in reasonable time.

## Offline conversion and current limits

Android conversion defaults to local processing. Cloud compilation is used only
when the user explicitly enables the optional cloud helper. Download the selected
model and an offline voice once before disconnecting. Novel mode preserves the
text verbatim and does not need an LLM download.

The Android plugin builds pinned llama.cpp libraries, including Vulkan when
`glslc` is available on the build host. It supports 64-bit Android 9 or later.
GPU availability does not guarantee that a model fits in memory: the Pixel 9a
killed the initial 4B GPU run under memory pressure. CPU mode and smaller models
remain useful alternatives. Device testing is in progress; build success alone
is not evidence of a completed conversion.

Original pages are rendered locally and synchronized by source page, preserving
pictures and their layout. This is page-level visual support, not semantic figure
cropping or the cloud pipeline's precise figure detection. Android ML Kit OCR
is wired to the native page renderer for sparse text layers (Latin script).

Novel mode scans the full extracted book for explicitly named dialogue tags,
assigns a stable voice/style per detected character, and saves the roster.
Ambiguous speech remains with the narrator; it does not infer every untagged
speaker or promise literary character understanding. Only installed offline
platform voices are selected; Kokoro can use separate bundled voice presets.
Narration fails visibly if audio synthesis fails, rather than inserting silence.

Completed compilation chunks are checkpointed. A retry with the same source,
model, and settings reuses them. iOS native inference, page rendering, and
background execution have not been verified. Local model quality and voice
cloning do not yet match the server pipeline.

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

## Kokoro device result (Pixel 9a)

Kokoro quantized ONNX CPU narration is now runtime-verified, including a cold
restart with airplane mode enabled and Wi-Fi disabled. The two-page character
fixture generated 28.716 s of non-silent 24 kHz audio in 29 s total pipeline time;
the illustrated fixture generated 55.055 s in 75 s with three original page
images and cached LLM compilation. First setup took 206 s including downloads.
Six presets are exposed; Bella/Default/Nicole/Adam were exercised, not all six.
See root README for conditions, footprint, waveform metrics and limits.

## Novel voice casting

Kokoro exposes four female and two male presets. Settings choose the narrator,
preferred male/female character presets, and per-name voice overrides. The book
is scanned before narration for explicit roles and narrow single-character
he/she narration; conflicting or missing evidence uses the narrator. Names alone
never cast a voice. Overrides win. Evidence is saved in character_roster.json.
Automatic casting was device-verified offline with Sarah/Michael (32 s processing,
32.491 s narration). All six presets have now been exercised across tests.
This is an English heuristic; ambiguous/pronoun-only speakers are not resolved.
