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

**2026-08-22 — pipeline complete.** Full 659-page book converted → `242` sections, `659/659` pages covered (104 missing pages patched as honest `needs_review` supplements), `135` figures, `73` formulas, `441.6 min` audio, calm female voice. Archive at `backend/output/arm-fundamentals-soc.tar.gz` (430.5 MB) + unpacked `backend/output/arm-fundamentals-soc/` — see [TASK.md](TASK.md) handover and `backend/full_conversion.log` for the full run log. Backend tests 7/7, `flutter analyze` clean, APK builds.

Previous incremental-archive stage (204 sections, 336 MB @2026-08-22 09:26) is superseded by the calm-voice 242-section archive @04:51; 44 sections are flagged `needs_review:true` deterministic supplements that can be LLM-refined later without re-extracting.

## Repository layout

- `backend/` — PDF → book package conversion pipeline, and the FastAPI server that distributes book packages to the app. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- `frontend/firebrat_app/` — the Flutter reader app (Android-first, responsive to larger screens).
- `docs/` — architecture, API, data schema, and voice-setup reference docs.
- `AGENTS.md` — orientation for a coding agent (or a future you) picking this project up cold; environment gotchas that cost real time to discover once.

## Quick start

### 1. Set up the three conda environments

marker-pdf's and Chatterbox's dependency pins conflict, so extraction, TTS, and the API server each get their own environment:

```bash
cd backend
mamba env create -f env/extract-environment.yml -p /path/to/envs/firebrat-extract
mamba env create -f env/tts-environment.yml      -p /path/to/envs/firebrat-tts
mamba env create -f env/serve-environment.yml    -p /path/to/envs/firebrat-serve
```

Update the hardcoded env paths at the top of `backend/convert.py` (`EXTRACT_PY`, `TTS_PY`, `SERVE_PY`) to match wherever you created them.

### 2. Convert a PDF into a book package

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

Interrupted Stage 2 runs resume automatically from `raw/compiled.json` — already-covered pages are skipped, so re-running the same command picks up where it left off. To retry placeholder (`needs review`) chunks: `PYTHONPATH=backend python -c "from firebrat.pipeline.compile_llm import run_compilation; run_compilation('raw/raw_pages.json','output/<book>', retry_failed=True)"`. Calm female voice now defaults via `backend/voice/narrator_ref.wav` `backend/firebrat/config.py:23` (`exaggeration 0.28` / `PAUSE 260`); delete that wav to fall back to default voice.

### 3. Serve book packages

```bash
cd backend
PYTHONPATH=/scratch/sroy85/Github/firebrat/backend /path/to/envs/firebrat-serve/bin/python -m uvicorn server.main:app --host 0.0.0.0 --port 8000
# or: cd backend && PYTHONPATH=. pytest tests/ -v
```

See [docs/API.md](docs/API.md) for the full route reference. Tests require `PYTHONPATH=backend` so `firebrat` package resolves (the pipeline CLI adds it via `sys.path` at runtime, but `pytest` does not).

### 4. Run the Flutter app

```bash
cd frontend/firebrat_app
flutter pub get
flutter run --dart-define=FIREBRAT_API_BASE_URL=http://<your-server-host>:8000
```

The app downloads a book's package once and reads/plays it fully offline afterward — the backend server only needs to be reachable during that initial download.

## License

Firebrat is licensed under the [GNU Affero General Public License v3.0](LICENSE). The narrator voice setup and its licensing considerations are documented separately in [docs/VOICE.md](docs/VOICE.md).
