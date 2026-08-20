# Firebrat — Build Task List

Living checklist. Update the checkbox and add a one-line note when a phase completes or a decision changes. Full rationale lives in `docs/ARCHITECTURE.md`; this file is just status.

- [x] **Phase 0 — Scaffold**: directory layout, doc skeletons, `.gitignore`, git init.
- [ ] **Phase 1 — Extraction**: `marker-pdf` (+ PyMuPDF fallback) on `arm-fundamentals-soc.pdf`, stable id assignment, `raw_pages.json`.
- [ ] **Phase 2 — LLM compilation**: chunking + nano-gpt calls → per-section narration segments with figure/formula/table refs.
- [ ] **Phase 3 — TTS + sync**: Chatterbox TTS narration per segment, LaTeX→PNG formula rendering, sample-accurate concatenation → `segments.json`.
- [ ] **Phase 4 — FastAPI backend**: `/books`, `/books/{id}/manifest`, `/books/{id}/download`, `/books/{id}/assets/*`.
- [ ] **Phase 5 — Flutter app**: library screen, reader screen (zoom, highlight, playback controls, autoplay/manual nav), responsive layout.
- [ ] **Phase 6 — End-to-end run**: full book converted, docs finalized to match as-built code.

## Known deferred / out of scope for v1

- Live device/emulator smoke testing (adb does not run in this sandbox — see AGENTS.md).
- Multi-book concurrent conversion queue (pipeline is single-book CLI for now).
- Manifest diffing / incremental re-conversion (schema has `generated_at` to support this later).
