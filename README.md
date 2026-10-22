# Firebrat

An audiobook generator and reader built specifically for technical books — the kind with formulas, circuit diagrams, register tables, and figures that a plain text-to-speech reading destroys.

**[subhajit-roy-partho.github.io/firebrat](https://subhajit-roy-partho.github.io/firebrat/)** — project site, with a longer writeup of the accessibility mission and how the pipeline works.

## Why this exists

Most audiobook tools treat a PDF as a wall of text to flatten into speech. That works for a novel. It falls apart the moment a book says "as shown in Figure 6.65" or writes out an equation — the audio either skips the thing you actually need to see, or reads a LaTeX expression aloud as noise.

Firebrat is built for readers who need the audio to *be* the primary way they get through a book, not a background convenience layered on top of the page. I'm dyslexic, and sustained silent reading — the kind a 600-page technical textbook demands — is genuinely exhausting and painful for me in a way it isn't for most people. Listening is how I actually get through dense material. But technical books can't just be *read aloud*; the diagrams and formulas are load-bearing. So Firebrat narrates the book and keeps the relevant figure or formula visible and highlighted exactly while it's being talked about, without ever hiding the rest of the page's diagrams from you. You can also always jump back and forth, freely, at any point — nothing about it is a strict linear "just sit there and listen."

This project is for anyone who'd rather listen than stare at a page for hours, but it's designed first for people who find sustained reading of technical material genuinely difficult: dyslexic readers, people with low vision, ADHD, or anyone who processes spoken language better than dense printed text. Adjustable text size, high-contrast highlighting, and short-segment pacing are core design decisions, not accessibility add-ons bolted on afterward.

## How it works

Firebrat converts a PDF into a self-contained **book package**: narrated audio broken into small segments, each tagged with what it's talking about (plain prose, a figure callout, a formula callout, a table callout). The companion Flutter app reads a section at a time, keeps every figure/table for that section visible in a scrollable gallery (never hiding the others), renders and highlights the formula currently being spoken, and lets you jump around freely — by tapping any segment, using prev/next controls, or on autoplay with a configurable delay.

```
PDF ──► Stage 1: extraction ──► Stage 2: LLM compilation ──► Stage 3: TTS + sync ──► book package
        (marker-pdf +           (nano-gpt: groups pages       (Chatterbox TTS,        (manifest.json +
         PyMuPDF)                into sections, writes         per-segment audio,      per-section audio
                                  narration text, authors       sample-accurate         + timing + assets)
                                  LaTeX for formulas it         timestamps)
                                  recognizes in the text)
                                                                        │
                                                                        ▼
                                                          FastAPI serves the package ──► Flutter app
                                                          (download once, then fully offline)
```

Full rationale for each design decision is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Status

**2026-08-25 — repaired & repackaged.** `arm-fundamentals-soc` 242 sections, `659/659` pages, `135` figures, `73` formulas (all PNGs now present — `formula_0026` LaTeX escape repaired), `436.3 min` audio, calm female voice; `digital-design-and-computer-architecture` 196 sections `46` figs `158` formulas `264.8 min` — both re-manifested 2026-08-25 (duplicate `sec_0016/0019/0022/0024` → `sec_9001-9004` with placeholder silence, `status.json` rewritten, `compiled.json` synced). Archives: `backend/output/arm-fundamentals-soc.tar.gz` (430.5 MB) + `backend/output/digital-design-and-computer-architecture.tar.gz` (334 MB). Full run log `backend/full_conversion.log`; 15/15 backend tests, `flutter analyze` / `flutter test` clean.

**Icon:** happy worm opening book (`assets/icon/app_icon.svg`) with 4 usage-driven moods (`assets/icon/moods/` + `lib/services/app_icon_service.dart`) — see `docs/ICON.md`.

**Notifications:** local playback `audio_service` + conversion `flutter_foreground_task`; operator Telegram pings (`TELEGRAM_BOT_TOKEN`) + optional Firebase Cloud Messaging (`docs/FIREBASE.md`).

**Env:** all variables documented (`docs/ENV.md` + `backend/.env.example`); previously deferred extraction fidelity fix (`aeda268` — marker `Document` blocks) is now in-code but existing packages still need re-extraction for full table coverage.

## Repository layout

- `backend/` — PDF → book package conversion pipeline, and the FastAPI server that distributes book packages to the app. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- `frontend/firebrat_app/` — the Flutter reader app (Android-first, responsive to larger screens).
- `docs/` — architecture, API, data schema, and voice-setup reference docs.
- `AGENTS.md` — orientation for a coding agent (or a future you) picking this project up cold; environment gotchas that cost real time to discover once.

## Quick start

### Option A: one command (`./run.sh`)

```bash
./run.sh                        # asks GPU? provider? key — then boots
./run.sh --provider local --model qwen3-1.7b   # small-VRAM laptop, no key needed
./run.sh --provider nanogpt     # cloud LLM (needs MODEL_API_KEY)
```

Detects docker + NVIDIA runtime, sizes the local model to your VRAM
(1.7B <6GB, 4B ~12GB, 8B 20GB+), writes `.env` (gitignored), and boots
the right compose profile. Then open **http://localhost:8000** — the
built-in web control room (upload PDFs, watch parallel jobs, download
books, switch provider/model) — or point the app at the same URL.

### Option B: Docker, by hand

Published images: [`subhajitroy/firebrat`](https://hub.docker.com/r/subhajitroy/firebrat) on Docker Hub, built by [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml). Three tags:

- **`cpu`** — everything in one container (API + extraction + narration), runs anywhere with plain `docker run`, no GPU needed. Slower conversions.
- **`gpu`** (= `latest`) — same, but expects `--gpus all` and [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) on the host. Much faster.
- **`api`** — just the server + upload/job-queue endpoints, no marker-pdf/torch/chatterbox — point `FIREBRAT_EXTRACT_PY`/`FIREBRAT_TTS_PY` at conda envs you already have (e.g. bind-mounted in) instead.

```bash
docker compose --profile cpu up   # or --profile gpu / --profile api
```

Then open the app and point it at `http://<this-machine>:8000`, or upload a PDF straight from the app's new "Convert a new book" screen — see [docs/API.md](docs/API.md) for the upload/status/retry endpoints if you'd rather script it. Book packages, uploads, and the job database persist in the `firebrat-data` Docker volume across restarts.

Set `MODEL_API_KEY` (your nano-gpt or OpenAI-compatible key) in a `.env` file next to `docker-compose.yml` — Compose reads it automatically. `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` are optional (progress pings).

#### Publishing an updated image (maintainers)

Images are built and pushed by [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml) on GitHub's own runners — no local Docker install needed, which is why the images are built there instead of by hand.

One-time setup: add two repo secrets under **Settings → Secrets and variables → Actions**:
- `DOCKERHUB_USERNAME` — your Docker Hub username.
- `DOCKERHUB_TOKEN` — a Docker Hub **access token**, not your password (hub.docker.com → Account Settings → Security → New Access Token).

After that, a new version publishes automatically on every push to `master` or a `v*` tag, or on demand:

```bash
gh workflow run docker-publish.yml
gh run watch                        # follow the in-progress build
```

The build installs `marker-pdf`/`chatterbox-tts`/torch from scratch (no layer cache to seed it from on the first run), so expect the `cpu` and `gpu` variants to take a while the first time; `api` is fast. If a run fails with `Username and password required`, the two secrets above haven't been added yet — that's the only thing `docker-publish.yml` needs to work.

### Option B: from source

#### 1. Set up the three conda environments

marker-pdf's and Chatterbox's dependency pins conflict, so extraction, TTS, and the API server each get their own environment:

```bash
cd backend
mamba env create -f env/extract-environment.yml -p /path/to/envs/firebrat-extract
mamba env create -f env/tts-environment.yml      -p /path/to/envs/firebrat-tts
mamba env create -f env/serve-environment.yml    -p /path/to/envs/firebrat-serve
```

Point `convert.py` at them via env vars — `FIREBRAT_EXTRACT_PY`, `FIREBRAT_TTS_PY`, `FIREBRAT_SERVE_PY` — or edit the defaults at the top of `backend/convert.py` directly.

#### 2. Convert a PDF into a book package

```bash
export MODEL_API_KEY=...        # nano-gpt (or any OpenAI-compatible) API key
export TELEGRAM_BOT_TOKEN=...   # optional — progress pings
export TELEGRAM_CHAT_ID=...
cd backend
python convert.py path/to/book.pdf
```

This runs all three stages and writes `backend/output/<book_id>/` — a complete, self-contained package (manifest, per-section audio, figure/formula/table images). See [docs/DATA_SCHEMA.md](docs/DATA_SCHEMA.md) for the exact shape.

If `deepseek/deepseek-v4-flash` keeps timing out (seen 240s ×5 retries on ~40% of chunks in the 659-page book), force the strong model for all chunks:

```bash
FIREBRAT_SPARK_MODEL=deepseek/deepseek-v4-pro:thinking python convert.py path/to/book.pdf
```

Long runs should use `tmux` so they survive disconnects and keep telegram pings (`pipeline/notify.py:9`). Example that produced the current calm-voice archive:

```bash
tmux new -s firebrat_convert -c backend "bash -c '
  source ~/.zshrc
  export CUDA_VISIBLE_DEVICES=\"MIG-b36117af-4e57-514f-a05d-13fb7d1c4280\"
  export HF_HOME=/scratch/sroy85/.cache/huggingface
  export MODEL_API_KEY=sk-nano-...
  export FIREBRAT_SPARK_MODEL=deepseek/deepseek-v4-pro:thinking
  export PYTHONUNBUFFERED=1
  PYTHONPATH=backend /scratch/sroy85/conda-envs/firebrat-extract/bin/python -u convert.py ../arm-fundamentals-soc.pdf 2>&1 | tee -a full_conversion.log
'"
```

Interrupted runs resume automatically — Stage 2 skips already-covered pages (`raw/compiled.json` checkpoint), and Stage 3 skips sections already fully narrated+assembled, so re-running the same command picks up where it left off. To specifically retry placeholder (`needs_review`) chunks/sections without redoing anything that already succeeded: `python convert.py path/to/book.pdf --skip-extraction --retry-failed`. (The server's `POST /jobs/{id}/retry` — see [docs/API.md](docs/API.md) — does exactly this automatically when converting through the API/app instead of the CLI.) Calm female voice now defaults via `backend/voice/narrator_ref.wav` `backend/firebrat/config.py:23` (`exaggeration 0.28` / `PAUSE 260`); delete that wav to fall back to default voice.

#### 3. Serve book packages

```bash
cd backend
PYTHONPATH=/scratch/sroy85/Github/firebrat/backend /path/to/envs/firebrat-serve/bin/python -m uvicorn server.main:app --host 0.0.0.0 --port 8000
# or: cd backend && PYTHONPATH=. pytest tests/ -v
```

See [docs/API.md](docs/API.md) for the full route reference. Tests require `PYTHONPATH=backend` so `firebrat` package resolves (the pipeline CLI adds it via `sys.path` at runtime, but `pytest` does not).

With the server running, you can also upload a PDF directly instead of running `convert.py` by hand:

```bash
curl -F "file=@path/to/book.pdf" http://localhost:8000/books/upload
curl http://localhost:8000/jobs   # watch it convert
```

— or from the app itself (see below). The server queues uploads one at a time by default (`FIREBRAT_MAX_CONCURRENT_JOBS`) since conversion is memory/GPU heavy.

#### 4. Run the Flutter app

```bash
cd frontend/firebrat_app
flutter pub get
flutter run --dart-define=FIREBRAT_API_BASE_URL=http://<your-server-host>:8000
```

The app defaults to offline reading of imported packages. Server mode downloads finished books or submits uploads; On-device mode converts locally with downloaded model weights and an installed offline voice. The optional cloud helper is off by default.

Beyond the reader itself, the app has:
- **Upload a book** — the cloud-upload icon on the library screen opens a "Conversions" view: pick a PDF, watch live stage/progress for every upload (queued/converting/done/failed), and retry a failed or `needs_review` conversion with one tap.
- **Focus mode** — the fullscreen icon in the reader turns the screen into just the current image/formula, crossfading as playback moves on, with transport controls pinned at the bottom.
- **Lock-screen controls** — playback keeps running and stays controllable (play/pause, prev/next segment) from the lock screen and notification shade, with the current figure/formula as the artwork.

## Offline Android benchmarks and correctness

<!-- DEVICE_BENCHMARK_START -->
Measured on a **Pixel 9a, Android 17, approximately 7.4 GiB RAM**, on 2026-10-20.
These are debug-app device measurements, not desktop throughput estimates.
The native inference libraries use `-O3`; the device-specific build enables
`armv8.2-a+dotprod+fp16`. Portable builds retain baseline CPU compatibility.

### Test conditions

- Model weights are cached before testing; the phone uses airplane mode with Wi-Fi off.
- Nonessential background apps are closed using Android's `stop-app` and cached-app
  cleanup. Seven remaining optional apps were stopped; essential Android services,
  accessibility, the keyboard, and offline speech remain available. About 2.9 GiB
  was available immediately afterward. Apps may restart when Android schedules work.
- Each model starts in a fresh Firebrat process and receives the same worked
  noise-margin example from *Digital Design and Computer Architecture*, PDF page 35
  (printed page 24). Source text is retained to check identical input; completed runs also save a SHA-256 hash.
- Q4_K_M weights; 4 CPU threads; 4,096-token context; batch 1,536; microbatch 128;
  temperature 0.2; seed 42; maximum 2,400 generated tokens. Model-specific chat
  templates are used, including Gemma's instructions within the initial user turn.
- Time to first token includes tokenization and prompt evaluation, but excludes
  loading weights. Decode rate excludes prompt evaluation. Total inference time
  includes prompt processing and generation. Download time is excluded.
- Peak app PSS/RSS is sampled approximately every 5 seconds. This includes the
  reader/debug runtime and model, rather than claiming model-only RAM. File caches,
  device heat, and background OS activity are not fully controlled. These are single
  runs, not statistically robust averages. Battery/power efficiency is not measured
  because the phone is plugged in; speed and memory are the efficiency measures.

### Measured model results

**Phone testing resumed after the user's call.** Gemma 3 1B, Qwen3 1.7B, and
Qwen3 0.6B are being tested on the same repaired technical passage. Gemma 1B
completed but failed source fidelity. Completed component/novel checks are below.

| Controlled configuration | Observed first token | Completion / progress | Peak app PSS / RSS | Correctness |
|---|---:|---|---:|---|
| Qwen3 0.6B, CPU, background apps closed | About 67 s (5 s sampling) | At least 320 reported tokens in a 305.6 s measurement window | 1.66 / 1.78 GiB | Interrupted by user request; unscored |
| Qwen3 0.6B, CPU, completed rerun | 62.778 s (internal timer) | Complete: 365 tokens, 278.215 s generation | 1.69 / 1.79 GiB | Failed: wrong voltage variables in both margin equations, copied prompt example; 4/6 checked facts fully retained |
| Qwen3 0.6B, GPU layers=99 | 44.997 s (internal timer) | Complete: 549 tokens, 69.570 s generation | 2.02 / 2.08 GiB | Failed: same two variable errors and invented prompt-example narration; 4/6 checked facts fully retained |
| Gemma 3 1B, CPU | 73.514 s (internal timer) | Complete: 563 tokens, 314.318 s generation | 1.79 / 1.90 GiB | Failed: 0/6 required facts faithfully retained; invented formulas and source pages |
| Qwen3 1.7B, CPU | 138.501 s (internal timer) | Complete: 335 tokens, 596.408 s generation | 2.43 / 2.52 GiB | 6/6 checked facts retained; equations left in prose, no formula callouts |

Qwen3 1.7B GPU layers=99 completed the **identical raw answer** as CPU in
122.545 s versus 596.408 s (4.87× faster), with first token at 99.235 s,
335 output tokens, peak PSS 2.72 GiB / RSS 2.66 GiB. The six-fact fidelity
result is unchanged; missing formula callouts remain a limitation. These are
single sequential debug runs, not repeated thermal/power-controlled trials.

Gemma returned parseable JSON but copied the schema’s alternative-type string,
invented five sections/page ranges for a one-page passage, and omitted all six
required numerical/conclusion facts. This is a conversion failure, not an accuracy
pass. Its average output rate was 1.79 tokens/s including first-token latency.
Qwen3 1.7B retained all six checked facts and the correct source page, but
returned symbolic equations inside long prose segments instead of separate
formula callouts. Its average output rate was 0.56 tokens/s including first-token
latency. This single-passage fidelity check is not a general accuracy benchmark.

The interrupted Qwen first-token observation is sampled externally; the incomplete run has no final
native timing counters or complete JSON. Do not infer an accuracy pass/fail from
this pause. Earlier source-selection diagnostic errors are excluded from model
results because inference never started.

Preliminary exploratory runs are separate:

| Exploratory configuration | Observation | Correctness result |
|---|---|---|
| Qwen3 4B, GPU | Android low-memory kill, about 3.9 GB RSS in exit report | No completed output; unscored |
| Qwen3 1.7B, GPU | No tokens during the observed prompt-evaluation interval; test stopped | Unscored; no GPU speed advantage established |
| Qwen3 1.7B, portable CPU | First 32 tokens at about 198 s | Partial output only; unscored |
| Qwen3 1.7B, specialized CPU | First 32 tokens at 196 s; 320 at 535 s on the longer Apollo input | Partial output only; no large speed improvement demonstrated |

The exploratory inputs and background-app state differ from the controlled runs;
these rows cannot be treated as a fair model leaderboard. Initial main-thread
blocking was fixed by moving native inference to a dedicated worker isolate.

### What correctness means here

For the textbook example, inspect the generated narration and formulas against six
source facts: low noise margin 1.02 V; high noise margin 0.69 V; tolerance of 1 V
noise on LOW; failure to guarantee HIGH with that noise; 3.84 − 1 = 2.84 V;
and 2.84 V below the required 3.15 V HIGH threshold. Report claims preserved out of
six, malformed JSON, omissions, invented statements, truncation, and bad references
separately. A valid JSON object alone is not an accuracy pass. This is a small
source-fidelity test, not a general reasoning benchmark.

The technical PDF exposed joined-word extraction (`Theinverternoisemarginsare`).
Extraction now rebuilds lines from PDF word boxes; a positioned-word regression
fails on the old extractor and passes with the fix. Scanned OCR and original page
rendering are tested independently, since an LLM cannot repair every extraction error.

### Reader, narration, and visuals

| Flow | Current evidence |
|---|---|
| Existing imported technical book | Earlier device test opened sections and played narration offline; user confirmed audio |
| Offline novel fixture, 2 pages | 3 s conversion; 2 sections; 16.007 s non-silent audio; Alice and Bob detected across both pages |
| Technical PDF extraction + original visuals | 153 ms text extraction + 345 ms rendering = 498 ms; all six checked numeric strings retained |
| Image-only scanned version + OCR + visuals | 181 ms initial extraction + 1,345 ms OCR + 146 ms rendering = 1,674 ms; all six numeric strings retained |
| Three-page illustrated conversion, Qwen1.7B GPU=99 | 302 s; 3 sections, 3 full-page images, 42.228 s non-silent audio; normal offline reader opens images and advances playback |
| Full local technical conversion, Qwen1.7B GPU=99 | 329 s; 2 sections, 1 full-page image, 163.513 s audio; **content fidelity FAILED**: omitted worked noise-margin example, no formula callouts |
| Short illustrated story excerpt | Three intact PDF pages from NASA's *You Are Going* prepared for end-to-end testing |

Novel attribution currently uses explicit named speech tags over the full extracted
book. Ambiguous/untagged speech stays with the narrator; this is not unrestricted
character understanding. Voice styles are stable, but no human listening score is
claimed from a non-silent-WAV check alone.

Original page images preserve circuit diagrams, photographs, and their placement.
They synchronize by source page. Individual semantic figure cropping, precise
figure-level narration alignment, and cloud narrator voice cloning are not yet
matched by this offline path. OCR, equations, and model hallucinations still require
quality review before relying on a long technical conversion.

The same-source Qwen3 0.6B GPU-requested run finished generation about 4.0×
faster than CPU (69.570 vs 278.215 s), while generating different-length outputs
(549 vs 365 tokens). Including first-token latency, rates were 7.89 vs 1.31
tokens/s. This is one sequential comparison, not a thermally controlled repeated
trial; GPU rounding can change output despite a fixed seed. Both outputs failed
fidelity, so speed does not establish conversion quality.

### Published Gemma/Qwen benchmarks (not phone measurements)

| Model | Publisher-reported MMLU-Pro |
|---|---:|
| Gemma 3 4B IT | 43.6 |
| Gemma 4 E2B | 60.0 |
| Gemma 4 E4B | 69.4 |
| Qwen3 4B Instruct 2507 | 69.6 |

Sources: [Gemma 3](https://ai.google.dev/gemma/docs/core/model_card_3),
[Gemma 4](https://ai.google.dev/gemma/docs/core/model_card_4),
[Qwen3](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507).
Different publisher evaluation setups and full-precision results are not a direct
comparison of these quantized phone builds.

Gemma 4 E2B's mobile text-only weights are listed at approximately 0.84 GB, and
E4B at 2.2 GB, excluding runtime/context memory. Those mobile versions require
LiteRT-LM, which is not integrated here. The pinned llama.cpp engine supports
Gemma 3/3n but not Gemma 4; Gemma 4 is not silently substituted into the older
Gemma prompt format. [Google memory documentation](https://ai.google.dev/gemma/docs/core)

### Reproduce

The development entry points are `tool/model_benchmark.dart` for inference and
component diagnostics, and `tool/local_conversion_probe.dart` for the real foreground
conversion service. Both live under `frontend/firebrat_app`; normal app builds use
`lib/main.dart`. Download/cache models first and push the selected PDF to the device.
Build the benchmark entry point, install it while preserving data, then run
`tool/benchmark_android_models.py` with `--models`, `--output-dir`, and the source
PDF/marker options. The script restarts only Firebrat and saves raw responses,
source text/hash, timings, memory samples, device state, and failures. Raw textbook
text/results stay in local test output rather than being published in this README.

Detailed investigation notes: [offline device testing](docs/OFFLINE_DEVICE_TESTING.md).
<!-- DEVICE_BENCHMARK_END -->

## License

Firebrat is licensed under the [GNU Affero General Public License v3.0](LICENSE). The narrator voice setup and its licensing considerations are documented separately in [docs/VOICE.md](docs/VOICE.md).

The full-page technical test exposes a larger-context failure that the short
passage benchmark missed: the source contains the worked example but generated
narration omits it. A working pipeline/package is not proof of content accuracy.
Technical offline conversion is not yet at cloud/server parity. The illustrated
fixture retained its checked claims (teamwork, Orion, SLS, Statue of Liberty,
160,000 engines), with repetitive paraphrasing on the first page. Page images
were inspected in the normal reader, including the full-image viewer; playback
advanced across sections while airplane mode remained on. Fine-grained semantic
figure placement and formula extraction remain unresolved.

The default local model is now Qwen3 1.7B. GPU remains opt-in because performance
and memory safety vary by device. A discovered manifest sample-rate mismatch was
fixed: metadata now uses the actual narration sample rate (24 kHz on this phone).
41 mobile pipeline tests and 25 frontend tests pass; both analyzers report clean.

### Kokoro neural voice device verification

The earlier stock-voice tests did **not** test Kokoro. Kokoro was subsequently
verified on the same Pixel 9a through the production foreground conversion
pipeline, using its quantized ONNX model on CPU. This is local neural speech,
not Android stock TTS and not a cloud voice service. This integration exposes
six presets: Default, Bella, Nicole, Sarah, Adam, Michael; there is no cloning.

| Test | Processing time | Generated audio | Result |
|---|---:|---:|---|
| Initial setup + two-page novel, Bella narrator | 206 s including network downloads | 28.716 s | Two sections, named-character roster, non-silent WAVs |
| Cold app restart, same novel, airplane mode + Wi-Fi off | 29 s | 28.716 s | Offline synthesis passed; narrator Bella plus character presets Default/Nicole |
| Three-page illustrated book, Adam narrator, offline | 75 s | 55.055 s | Three sections and all three page images; existing LLM compilation checkpoints reused |

The offline novel run took about 1.01 seconds of total pipeline time per second
of output audio. Illustrated timing includes model loading, cached compilation,
rendering, synthesis and packaging; it is not an isolated TTS kernel benchmark.
The model/voice/espeak asset directory occupied 112,589 KiB (about 110 MiB).
One memory snapshot during offline novel synthesis showed 751,804 KiB app PSS;
this is **not** a sampled peak. Both novel WAVs were mono 24 kHz, non-silent,
with zero clipped PCM samples (peaks 20,028 and 20,418 of 32,767).
Timing, waveform checks and successful generation do not establish subjective
voice preference or an exhaustive pronunciation benchmark. The initial round exercised Bella/Default/Nicole/Adam. A subsequent automatic
casting device test also exercised Sarah/Michael, covering all six presets. The first-time download requires internet; subsequent
cold-start narration passed with networking disabled. No stock-voice fallback
was used. Kokoro does not fix the technical LLM coverage failure described above.

Backend novel conversion is also implemented via multipart `content_mode=novel`
and CLI `--content-mode novel`; app server uploads now carry the selected book
type. See [backend novel documentation](docs/BACKEND_NOVELS.md). Backend automated
tests pass, but real server Chatterbox character voice quality has not been
listening-tested in this device session.

Final normal-reader Kokoro playback was verified offline: the highlighted
segment and playback position advanced (19/22 s), then Android reported the next
Orion section playing with no media-session error. Normal app is restored, and
temporary airplane/stay-awake settings were reset after testing.

### Voice selection and automatic novel casting

In Conversion settings → On-device → Kokoro, the narrator picker labels four
female presets (Default, Bella, Nicole, Sarah) and two male presets (Adam,
Michael). These are voices of the same Kokoro model, not six separate models.
Novel mode additionally offers a male character voice, female character voice,
and exact-name overrides such as `Alice=Nicole` and `Bob=Michael` (one per line).
Choices survive restarts and are included in background conversion requests.
Overrides take priority over automatic casting. Changes apply to new narration;
existing audio does not change just by changing settings.

The full extracted book is scanned before casting. Mobile casting uses explicit
role statements and narrowly bounded narration such as `Alice smiled as she
waved` or `Bob nodded as he left`. Only one known named character may be present
in the sentence. Quoted speech is removed before collecting evidence; mere names,
reported `Alice said that he left`, and conflicting evidence remain unknown.
Unknown characters use the narrator preset. This is a conservative English
heuristic, not complete literary coreference or a determination of identity;
manual overrides are provided for missed/incorrect casting. Pronoun-only speech
still cannot identify its speaker. The saved roster records evidence and, for
Kokoro, selected voices so results can be inspected.

Pixel 9a offline test with Sarah/Michael: two-page fixture, two detected
characters, 32 s total pipeline time, 32.491 s non-silent 24 kHz narration.
Automatic female/male categories were confirmed in the saved roster. This
validates the supported patterns, not arbitrary novels or subjective voice quality.
Tests cover unknown/conflicting evidence, reported speech, overrides, persistence,
and background request serialization. Backend uses explicit role statements and
optional local Chatterbox male/female reference clips; see
[backend voice casting](docs/BACKEND_NOVELS.md). No additional server voices are
bundled, and no client-supplied filesystem path is accepted by the upload API.


## Apple app and published PWA (1.6.1)

- [Open the Apple PWA](https://subhajit-roy-partho.github.io/firebrat/): server-only conversion, a short original narrated sample, and explicitly saved offline reading. The previous website is under its **Documentation** link.
- [Native iPhone/iPad app, setup and measured results](frontend/FirebratNative/README.md): local OCR, PDF conversion, Kokoro voices, novel casting, optional Qwen/Gemma compilation, and Metal selection.
- [PWA source, deployment and offline behavior](frontend/firebrat_pwa/README.md).
- [Release downloads](https://github.com/Subhajit-Roy-Partho/firebrat/releases/latest): Android APK and a clearly labeled **unsigned IPA**. The IPA needs signing before installation; it is not an App Store or TestFlight distribution.

The native library has a visible trash button with confirmation; deleting a local
copy keeps the original import file and server copy. Physical iPad measurements
(including CPU/Metal comparisons) are in the native app README.

Swift and Flutter store their preferences independently. The native source and
remaining platform limits are documented explicitly; small simulator tests do not
establish physical-iPhone performance or full-book semantic accuracy.

## Desktop server installer (preview)

[Guided Apple silicon macOS DMG and Linux installer](https://github.com/Subhajit-Roy-Partho/firebrat/releases/tag/server-v0.1.3)
lets you choose a PDF on your computer, convert it there, and download the result
in Firebrat on your phone. Setup manages isolated Python environments; Docker is
not required. First setup/model downloads need internet and around 20–40 GB of
free disk space. macOS builds are unsigned/not notarized; no paid Apple enrollment
is performed. Native Intel macOS is unsupported by the required PyTorch wheels; use a Linux backend/VM. [Full installation, privacy and troubleshooting guide](installer/server/README.md).

Choose **On this computer** with native Ollama, or enter your existing
OpenAI-compatible LLM API and model ID. **Voice generation always runs locally**
with Chatterbox. API mode sends extracted text to your chosen LLM provider and
can incur that provider's LLM fees; it never uses a paid speech API. Cached local
models allow offline conversion after initial downloads. Apple silicon can use
Metal for native Ollama; Mac voice generation stays on CPU. Compatible NVIDIA
GPUs can accelerate local LLMs and speech on Linux.

These are conservative capacity estimates, not measured PC quality rankings:

| Computer | Suggested starting model |
|---|---|
| 8 GB RAM / small CPU laptop | Existing LLM API + local CPU voice; optionally Qwen3 1.7B |
| 16–24 GB Apple silicon | Qwen3 4B Instruct; 1.7B if memory is tight |
| 32 GB Apple silicon | Qwen3 8B |
| NVIDIA 6 GB VRAM | Qwen3 1.7B; use CPU voice if VRAM is tight |
| NVIDIA 8–12 GB VRAM | Qwen3 4B Instruct |
| NVIDIA 16 GB VRAM | Qwen3 8B |
| NVIDIA 24+ GB / 64+ GB unified RAM | Qwen3 14B, or test Gemma 3 12B/27B |
| CPU-only desktop with 32+ GB RAM | Qwen3 4B/8B if patient, or an LLM API |

Leave memory for extraction, context and speech, and try a few representative
pages first. Gemma is an alternative, not a benchmark-proven winner here. For an
API, prefer a capable instruction model with chat/completions support and at
least 16K context, using the exact ID in your provider's current model list.
See [Ollama model sizes](https://ollama.com/library/qwen3/tags) and the detailed
installer guide for tradeoffs. Review converted technical facts and formulas.

For effective private web/phone access, install **Tailscale** on the PC and phone,
join the same tailnet, and run this on the PC:

```sh
tailscale serve --bg http://127.0.0.1:8000
```

Use its printed HTTPS address as your app's server URL, or open that address
with `/pwa/` appended in the phone browser. The PC must stay awake. Share the
backend port, not the private setup screen. Tailscale Serve is private to your
tailnet; router port forwarding and public Funnel are unnecessary. Allowed
members of your tailnet can read this server's books. Headscale, NetBird or a
similar mesh VPN can also work with private reachability and valid HTTPS.
[Official Tailscale Serve instructions](https://tailscale.com/docs/reference/tailscale-cli/serve).

Linux users can also use the [Docker launcher](installer/server/firebrat-docker.sh): run it with `cpu` or `gpu` to open the same desktop conversion screen. The images are `subhajitroy/firebrat:desktop-cpu` and `subhajitroy/firebrat:desktop-gpu`; the GPU option requires NVIDIA Container Toolkit. Books, models, and settings persist on the host. See the [Docker setup and update guide](installer/server/README.md#linux-docker-installer). Narration always runs locally, including when an LLM API is selected.

Measured desktop startup and cached offline CPU speech results are recorded in the [installer validation guide](installer/server/README.md#measured-desktop-validation-2026-10-21).
