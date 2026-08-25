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

### Option A: Docker (easiest)

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

The app downloads a book's package once and reads/plays it fully offline afterward — the backend server only needs to be reachable during that initial download (or while converting a new upload).

Beyond the reader itself, the app has:
- **Upload a book** — the cloud-upload icon on the library screen opens a "Conversions" view: pick a PDF, watch live stage/progress for every upload (queued/converting/done/failed), and retry a failed or `needs_review` conversion with one tap.
- **Focus mode** — the fullscreen icon in the reader turns the screen into just the current image/formula, crossfading as playback moves on, with transport controls pinned at the bottom.
- **Lock-screen controls** — playback keeps running and stays controllable (play/pause, prev/next segment) from the lock screen and notification shade, with the current figure/formula as the artwork.

## License

Firebrat is licensed under the [GNU Affero General Public License v3.0](LICENSE). The narrator voice setup and its licensing considerations are documented separately in [docs/VOICE.md](docs/VOICE.md).
