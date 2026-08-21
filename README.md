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

See [TASK.md](TASK.md) for current build phase and what's done. Short version: backend pipeline and Flutter app are both implemented and verified end-to-end on real content from the sample book; a full-book conversion run is what actually populates the library.

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

### 3. Serve book packages

```bash
cd backend
/path/to/envs/firebrat-serve/bin/python -m uvicorn server.main:app --host 0.0.0.0 --port 8000
```

See [docs/API.md](docs/API.md) for the full route reference.

### 4. Run the Flutter app

```bash
cd frontend/firebrat_app
flutter pub get
flutter run --dart-define=FIREBRAT_API_BASE_URL=http://<your-server-host>:8000
```

The app downloads a book's package once and reads/plays it fully offline afterward — the backend server only needs to be reachable during that initial download.

## License

Firebrat is licensed under the [GNU Affero General Public License v3.0](LICENSE). The narrator voice setup and its licensing considerations are documented separately in [docs/VOICE.md](docs/VOICE.md).
