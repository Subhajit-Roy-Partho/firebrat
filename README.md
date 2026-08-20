# Firebrat

An audiobook generator and reader built specifically for technical books — the kind with formulas, circuit diagrams, register tables, and figures that a plain text-to-speech reading destroys.

Firebrat converts a PDF into a self-contained "book package": narrated audio broken into small segments, each tagged with what it's talking about (plain prose, a figure, a formula, a table). The companion Flutter app reads a section at a time, keeps every figure for that section visible (never hiding the others), highlights the formula currently being spoken, and lets you jump around freely — manually or on autoplay.

## Status

See [TASK.md](TASK.md) for current build phase and what's done.

## Repository layout

- `backend/` — PDF → book package conversion pipeline, and the FastAPI server that distributes book packages to the app. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- `frontend/firebrat_app/` — the Flutter reader app (Android-first, responsive to larger screens).
- `docs/` — architecture, API, data schema, and voice-setup reference docs.
- `AGENTS.md` — orientation for a coding agent picking this project up cold.

## Quick start

### 1. Convert a PDF into a book package

<!-- filled in as the pipeline is built: conda envs, convert.py usage -->

### 2. Serve book packages

<!-- filled in during Phase 4: uvicorn command -->

### 3. Run the Flutter app

<!-- filled in during Phase 5: flutter pub get / flutter run / flutter build apk -->

## License / voice

The narrator voice setup and its licensing considerations are documented in [docs/VOICE.md](docs/VOICE.md).
