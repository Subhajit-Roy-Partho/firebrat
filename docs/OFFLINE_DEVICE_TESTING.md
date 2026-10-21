# Offline Android conversion investigation (2026-10-20)

Device: Pixel 9a, Android 17, approximately 7.4 GiB RAM. Tests use a
preserved installed app data directory, downloaded GGUF weights, and the
2-page [NASA Apollo sample document](https://ntrs.nasa.gov/api/citations/20160002392/downloads/20160002392.pdf).

Implemented local path:

- Cloud assistance is opt-in; local conversion does not require cloud credentials.
- Android PDF rendering preserves original page images and supplies OCR input.
- Native llama.cpp libraries are built by the Android plugin; its ABI is pinned
  to the revision used by llama_cpp_dart 0.2.2.
- Blocking model work uses a dedicated Dart worker, independent of the Android
  platform thread. The foreground service reports token/chunk progress.
- Compilation checkpoints survive retries with matching source and settings.
- Novel mode reads verbatim, scans all extracted pages for explicit named speech
  tags, and assigns stable local voice styles. Uncertain speakers use narration.
- Voice synthesis failures abort visibly instead of generating silent placeholders.

Evidence so far: original PDF page rendering preserves the source photographs.
The initial Qwen3 4B GPU run was killed for low memory. A Qwen3 1.7B GPU run
loaded but stalled during prompt evaluation. CPU inference produces tokens;
completed package/narration validation is still in progress. CPU is the default.
The app remains responsive after moving native work into a worker isolate.

Portable APKs keep baseline CPU compatibility. For a device whose instruction
support has been verified, the optional Gradle property `firebratArmArch` can set
`GGML_CPU_ARM_ARCH` (e.g. `armv8.2-a+dotprod+fp16` on this Pixel). Do not ship a
specialized APK to devices without those instructions.

## Gemma comparison

Publisher-reported MMLU-Pro: Gemma 3 4B 43.6; Gemma 4 E2B 60.0; Gemma 4 E4B
69.4; Qwen3 4B Instruct 2507 69.6. These are separate evaluations, not a controlled
same-runtime comparison. They do not establish narration JSON reliability.

- [Gemma 3 model card](https://ai.google.dev/gemma/docs/core/model_card_3)
- [Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4)
- [Qwen3 model card](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)

Google estimates mobile text-only loading memory of 0.84 GB for Gemma 4 E2B and
2.2 GB for E4B, excluding runtime/context memory. Those optimized versions use
LiteRT-LM, not this app's current GGUF engine. Gemma 4 E2B mobile is a promising
next comparison; it is not implemented or device-verified here.
[Memory estimates](https://ai.google.dev/gemma/docs/core)

Page visuals currently synchronize whole original pages rather than semantically
cropping individual figures. Local voice presets are not cloud narrator cloning.
These differences mean offline/cloud capability parity is not yet achieved.


## Pause and exact resume state

The user reconnected the phone and explicitly resumed testing. The controlled
Qwen3 1.7B/0.6B CPU queue is running again, with airplane mode enabled, Wi-Fi off,
and temporary USB stay-awake enabled. Restore connectivity and stay-awake=0 at
final handoff. The benchmark build remains installed; restore the normal
`lib/main.dart` build after testing finishes.

Gemma 3 1B CPU completed: first token 73.514 s, generation 314.318 s,
563 output tokens. Manual six-fact source-fidelity check fails 0/6: required
numerical facts/conclusions are omitted, formulas and page ranges are invented.
Parseable JSON does not count as correctness. See README for memory metrics.
The first resumed Qwen1.7 run was interrupted by USB disconnection, not a proven
model crash; the user authorized its restart.

Completed device checks:

- Two-page novel fixture: 3 s, 2 sections, 16.007 s non-silent audio;
  Alice/Bob evidence found on both pages. Human voice-quality scoring remains open.
- Real textbook PDF p35 / printed p24: 153 ms extraction + 345 ms full-page render.
- Image-only version of the same page: 181 ms text-layer check + 1,345 ms offline
  OCR + 146 ms render. All six checked numeric strings survive in both versions.
- Native rendered page was visually inspected: inverter diagram, equations, and
  original layout are preserved. This does not prove semantic figure-level sync.

PDF extraction originally joined words. Rebuilding text from `extractTextLines`
word boxes fixes the actual page and a generated positioned-word regression.
The heading is represented as `1 . 6 . 4`, so the benchmark's end marker uses that
spacing. Gemma 1-3 instructions now share the initial user turn per Google docs.

Controlled Qwen3 0.6B CPU run after background cleanup: first token observed around
67 s (5 s sampling); at least 320 reported tokens; stopped for the call after
305.565 s; peak PSS 1,741,370 KiB, RSS 1,862,052 KiB. No completed JSON and no
correctness score. Gemma 3 1B subsequently completed and failed fidelity; Qwen3 1.7B is running.

Cached model files in app `files/firebrat_models/llm`: Qwen3 0.6B, 1.7B,
4B Instruct 2507, Gemma 3 1B. Temporary duplicate GGUF files were removed from
`/data/local/tmp`; app caches and the user's book/archive are preserved.

When authorized to resume, use the already installed `tool/model_benchmark.dart`
entry point and the host `tool/benchmark_android_models.py`. Continue the identical
textbook comparison with Gemma 3 1B and Qwen3 1.7B; rerun 0.6B to completion.
Then compare the same 0.6B challenge on GPU with a bounded timeout, and consider
4B CPU if memory permits. Keep failures, user interruptions, and real completions
separate. Current evidence lives under ignored local `tmp/local-conversion-test/`.

After selecting a suitable model, build `tool/local_conversion_probe.dart` and
use its optional app-support `local_conversion_probe_config.json` with `pdf_path`,
`title`, `model`, and `gpu_layers` to run full technical and illustrated packages.
Source fixtures remain on-device:

- `/data/local/tmp/firebrat-technical-example.pdf`: real textbook worked-example page.
- `/data/local/tmp/firebrat-technical-scanned.pdf`: image-only version for OCR.
- `/data/local/tmp/firebrat-illustrated-short.pdf`: intact NASA story PDF spreads
  3–5 (three PDF pages) from You Are Going, downloaded from NASA.
- `/data/local/tmp/firebrat-apollo.pdf`: original 2-page dense technical paper.
- `/data/local/tmp/firebrat-novel.pdf`: two-page explicit-dialogue fixture.

Final checks still required: completed model fidelity scoring on the six worked
claims; full local technical narration and image/formula sync in the normal reader;
short illustrated package playback; subjective novel character-voice listening;
restore normal app build; final tests; save changes. No cloud/offline parity claim.

Latest resumed result: Qwen3 1.7B CPU completed 335 tokens in 596.408 s,
first token 138.501 s; peak PSS 2,545,478 KiB, RSS 2,641,416 KiB.
Manual check: 6/6 required facts retained, correct source page, but equations
remain prose and no formula callouts are authored. Next 0.6B test could not
start because phone locked. Awaiting user unlock. Cable reports AC powered,
so temporary stay-awake changed from USB-only to all charging sources.
Full conversion probe APK built successfully but not installed yet.

Final round completed: illustrated 302 s / 3 sections / 3 images / 42.228 s
audio; technical 329 s / 2 sections / 1 image / 163.513 s audio. Technical
content fidelity FAILED: omitted worked example despite source being present
in checkpoint input, and no formula callouts. Do not advertise full parity.
Qwen1.7B GPU benchmark identical to CPU answer, 122.545 vs 596.408 s.
Normal main app installed with sample-rate metadata fix and 1.7B default.
Normal reader opens illustrated book, shows full image viewer, playback
autoadvances across sections offline. Stopped playback; restored airplane off,
Wi-Fi/data on, stay-awake false. 41 mobile +25 frontend tests pass, analyzers clean.
No conversion/benchmark host queue remains active. Raw results remain ignored
under tmp; do not publish the user's textbook source or extracted text.

Kokoro subsequently tested: initial setup206s; cold offline novel29s/28.716s
non-silent24kHz audio; offline illustrated Adam75s/55.055s with3pageimages,
compiled checkpoints reused. Both novel audio sections0clippedsamples. Root
README has full conditions. Evidence kokoro-offline-novel.json,
kokoro-offline-illustrated.json, kokoro-audio-metrics.json and Adam sample WAV.
Backend novel mode implemented +41 backend tests, app cloud uploads now send
content_mode. Normal app must be reinstalled after Kokoro test probe and network/
stayawake restored (in progress at this note). No real Chatterbox listening test.

Kokoro final playback verified in normal main app while still offline: reader
screenshot shows00:19/00:22 with highlighted third segment; Android media session
then reports PLAYING Orion(section2), error=null. Saved kokoro-normal-reader.png.
Stopped playback and restored airplaneoff/WiFion/dataon/stayawakefalse. Normal
app remains installed. Backend41/frontend25/mobile41 tests pass; both Dart
analyzers clean. No subjective listening assessment claimed.

Automatic voice-casting follow-up: offline fixture detects Alice=female,
Bob=male from single-character narration; Sarah/Michael presets used,32s
processing/32.491s non-silent narration. Evidence automatic-casting-result.json,
automatic-casting-roster.json, automatic-casting-sample.wav. Four new unit tests
cover conflicts, role statements, overrides and serialized requests; UI test
covers saved male voice and named override on narrow/large-text screen.
Backend43 tests pass with conservative role inference + configurable local
male/female reference clips; real Chatterbox listening remains unverified.

Voice-casting final main APK installed successfully. Airplane off, Wi-Fi/data on,
stay-awake false. Final mobile45/frontend25/backend43 tests pass, both Dart
analyzers clean. Existing books/models preserved. No active device test queue.
