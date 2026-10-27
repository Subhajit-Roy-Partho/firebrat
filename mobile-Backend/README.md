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

## Model catalog, device tiers and accelerators

Added 2026-10-26 (details and caveats: `docs/handover/flutter-models.md`).

- **LLM catalog** (`lib/src/compilation/model_catalog.dart`): 13 GGUF models, each with
  `tier` (Light / Balanced / Powerful / Desktop-class), `minDeviceRamGb`, licence, SHA-256 and
  acceleration (`llama.cpp`: CPU, optional Vulkan layers). Defaults are unchanged
  (`qwen3-1.7b`, 0 GPU layers). Only models the pinned llama.cpp can load are listed.
- **TTS catalog** (`lib/src/models/tts_model_catalog.dart`): Kokoro-82M int8 (default, verified on a
  phone), fp16 and fp32, plus 5 extra voices (Sky, Emma, Isabella, George, Lewis), all from a pinned
  Hugging Face revision with SHA-256. `KokoroAssets` downloads the extras (resume + checksum).
- **Device probing / advice** (`models/device_capabilities.dart`): `DeviceCapabilities` (RAM, ABI,
  API level, ORT providers) -> `tier`, `assessFit()` (warning text such as "needs ~6 GB, this phone has 4 GB"),
  `recommendLlm()`. The host app fills it with device_info_plus.
- **Accelerator selector** (`tts/accelerator.dart`): `AcceleratorPreference` (Auto / GPU-NPU / CPU) ->
  `planAccelerators()` -> `AcceleratedSession` (opens the first back end that works, retries once on CPU if
  a run fails). `FirebratKokoroTts.accelerationStatus` and `<kokoro dir>/last_run.json` report what ran.
  Auto = CPU for the default model (safe); it only tries NNAPI for the fp16 model on Android 10+/6 GB+.
  The LLM worker falls back to CPU if a GPU load fails.
- **Download network policy** (`lib/src/network/`): `NetworkPolicy.decide()` is a pure function
  (preference, network kind, metered flag, size -> allow / wait / ask). `NetworkGate` waits, pauses a
  running transfer through a `CancelToken` when the network stops being allowed, and resumes by itself.
  The app wires it in `frontend/firebrat_app/lib/services/app_network_gate.dart`.

Tests: `test/model_catalog_test.dart`, `test/accelerator_test.dart`, `test/network_policy_test.dart`
(pure Dart, fake runtime / fake connectivity stream).

## Expressive multi-voice narration (on device, experimental)

Added 2026-10-27; measurements and caveats: `docs/handover/android-expressive-gpu.md`. It is the on-device
counterpart of `backend/firebrat_cast`: the same casting design (character roster, speaker attribution for
every quote, emotion + delivery per line, mood per page), sized for a phone. Offered as **Expressive
(experimental)** next to Illustrated and Novel, only on Balanced phones and up (about 6 GB RAM, `CastLimits.allowedFor`).
Novel and Illustrated mode are unchanged.

```
pages ──> cast/cast_segmenter.dart   quote / narration spans with the server's (page, idx) keys, lossless
        ├> cast/cast_engine.dart     pass 1 roster (budgeted windows, aliases merged) + pass 2 attribution/emotion
        │                            chunks (<=12-16 quotes, only the characters present in the prompt)
        │                            JSON-validated, repair retry for the missing quotes, loose parser for broken
        │                            quoting, regex dialogue-tag fallback (novel analyzer), narrator last
        │                            per-answer disk cache `cast/cache/*.json` -> an interrupted run resumes
        ├> cast/cast_voices.dart     voice per character: gender / age / accent / temperament -> a voice by MEASURED
        │                            pitch, never the narrator's voice, fixed for the whole book (`cast/voices.json`)
        │                            + emotion -> delivery table (speed, pauses, gain, light pitch) incl. stage directions
        ├> cast/cast_plan.dart       per page: ordered lines (text, voice, delivery); manifest `cast` key;
        │                            `character_roster.json` for the existing Cast screen
        └> tts/cast_narration_engine.dart  voices every line through a `SpeechBackend`:
              tts/kokoro_v1_backend.dart   Kokoro v1.0, 28 English voices, ORT through OrtBridge (typed tensors)
              tts/piper_backend.dart       Piper en_US libritts_r (904 speakers, 27 curated), ~8x faster
```

* `pipeline/expressive_conversion.dart` glues it into `MobileConversionPipeline` (`BookContentMode.expressive`):
  cast (LLM loaded, then **disposed before** the speech model loads) -> voices -> narration. The package gets the
  standard layout plus `manifest.cast = {engine, narrator, characters:[{id,name,gender,age,voice}]}`.
* Limits by device class: `CastLimits.forTier` (LLM-call budget, roster windows, chunk size). Beyond the budget the
  quotes with the most untagged speakers get the LLM, the rest keep the dialogue-tag/narrator fallback, and
  `cast.json` says so (`notes`, `stats`). `estimateExpressive` gives the honest time estimate shown in the app.
* Downloads (`tts/expressive_assets.dart`): Piper model (79 MB) or Kokoro v1.0 model (92/163/326 MB) + 28 voices
  (14 MB), pinned revisions with SHA-256, resume, network gate through a `CancelToken`.
* Speech on GPU/NPU: not possible for these models on a Pixel 9a, measured: see the handover doc. `OrtBridge`
  (`android/.../OrtBridge.kt`) exposes NNAPI flags, per-session profiling and typed tensors; `planFor` in
  `kokoro_v1_backend.dart` encodes the result (CPU / XNNPACK; NNAPI only when the user asks).
* LLM: `PromptFormatKind.auto` formats prompts with the template stored in the GGUF (llama.cpp
  `llama_chat_apply_template`), so a new model family needs no hand-written template. The worker also reports prompt tokens.

### Benchmarks and evaluation (re-run recipes)

```bash
# Speech: Kokoro / Piper, every ONNX Runtime provider (plugin or OrtBridge), profile per provider.
#   edit bench_config.json (see lib/src/tts/tts_benchmark.dart), then from a debug copy of the app:
cd frontend/firebrat_app
flutter test integration_test/tts_benchmark_test.dart -d <serial> | grep BENCH    # start FIRST (it reinstalls the app)
adb push bench_config.json models voices ... /sdcard/Android/data/com.firebrat.firebrat_app.debug/files/kokoro_bench/   # config LAST

# LLM casting quality on the phone (fixture test/fixtures/cast_eval_sample.json), one model after another:
flutter test integration_test/llm_cast_eval_test.dart -d <serial> | grep BENCH

# The same prompts/scoring on a laptop through llama-server (quality only, speeds are the laptop's):
llama-server -m model.gguf -c 8192 -ngl 99 --port 8099 --jinja &
cd mobile-Backend && dart run tool/cast_eval_cli.dart --url http://127.0.0.1:8099 --label name --attr 14 --roster 6
dart run tool/cast_eval_cli.dart --baseline --attr 28 --roster 0        # regex-only baseline

# End to end (EPUB -> cast -> narration -> package) on the phone:
flutter test integration_test/expressive_e2e_test.dart -d <serial> | grep BENCH
```

Tests (no device): `test/cast_engine_test.dart` (segmenter, JSON repair, roster merge, fake-LLM casting, resume from
cache, retry, fallbacks, budget, voices, emotion table), `test/cast_eval_test.dart` (fixture + oracle harness check),
`test/cast_narration_test.dart` (plan, narration with a fake engine, pipeline stage, estimate, asset catalog, accelerator plan, Piper encoding).
