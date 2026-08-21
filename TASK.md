# Firebrat — Build Task List

Living checklist. Update the checkbox and add a one-line note when a phase completes or a decision changes. Full rationale lives in `docs/ARCHITECTURE.md`; this file is just status.

- [x] **Phase 0 — Scaffold**: directory layout, doc skeletons, `.gitignore`, git init.
- [x] **Phase 1 — Extraction**: `marker-pdf==1.9.3` (not 2.0.0 — needs Docker) + PyMuPDF, batched into `EXTRACT_BATCH_PAGES`-sized subprocess calls (this session's 6GB memory cap OOM-killed a whole-book single call). Verified on real page ranges of the sample book.
- [x] **Phase 2 — LLM compilation**: chunking + nano-gpt calls → per-section narration segments with figure/table refs. Formulas turned out to need a different approach — see below. Model routing uses `deepseek/deepseek-v4-flash` (cheap tier) / `deepseek/deepseek-v4-pro:thinking` (strong tier); `meta/muse-spark-1.2-contributor` was dropped after verifying it returns `empty_response` on every request.
- [x] **Phase 3 — TTS + sync**: Chatterbox TTS narration per segment, sample-accurate concatenation → `segments.json`. Verified: computed timestamps matched actual `ffprobe` audio duration exactly on a real sample.
- [x] **Phase 4 — FastAPI backend**: `/books`, `/books/{id}/manifest`, `/books/{id}/download`, `/books/{id}/assets/*`. 4/4 backend tests pass (schema, audio timing, API).
- [x] **Phase 5 — Flutter app**: library screen, reader screen (zoom via photo_view, LaTeX highlight sync via flutter_math_fork, playback controls, autoplay/manual nav that always works), responsive layout, adjustable font scale. `flutter analyze` clean, 6/6 pure-Dart tests pass, debug APK builds.
- [ ] **Phase 6 — End-to-end run**: full 659-page book conversion in progress (background). Release APK build deferred until it finishes (both compete for the same 6GB session memory budget when run concurrently). GitHub repo publishing in progress.

## Real deviations from the original plan (found during implementation, not anticipated)

- **Formulas are LLM-authored, not Stage-1-extracted.** The sample book typesets math as plain inline text (e.g. `tCK = 1/f = 10 ns`), not LaTeX-taggable blocks — both marker's equation detection and a `$...$` regex found effectively zero real formulas across genuinely mathematical pages. Stage 2's LLM now recognizes relationships in the page text itself and authors LaTeX directly (`formula_callout` segments carry a `latex` field); our code still mints the `formula_NNNN` id, never the LLM. See `docs/DATA_SCHEMA.md`.
- **marker-pdf pinned to 1.9.3**, not 2.0.0 — 2.0's layout backend requires Docker (not installed here), exactly the risk called out in the original plan.
- **This session has a hard 6GB total RAM cap** (SLURM allocation), not just "GPU is MIG-partitioned" as originally scoped — this affected Stage 1 (had to batch) and the Flutter release build (must not run concurrently with the conversion pipeline). See `AGENTS.md`.

## Known deferred / out of scope for v1

- Live device/emulator smoke testing (adb does not run in this sandbox — see AGENTS.md).
- Multi-book concurrent conversion queue (pipeline is single-book CLI for now).
- Manifest diffing / incremental re-conversion (schema has `generated_at` to support this later).
- Per-chunk/per-section resume within a single Stage 2 or Stage 3 run if interrupted partway (Stage 1 batching is resumable in spirit since each batch is independent, but the orchestrator doesn't currently skip already-completed batches on restart).
