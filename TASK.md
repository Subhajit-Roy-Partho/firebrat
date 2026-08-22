# Firebrat — Build Task List

Living checklist. Update the checkbox and add a one-line note when a phase completes or a decision changes. Full rationale lives in `docs/ARCHITECTURE.md`; this file is just status.

- [x] **Phase 0 — Scaffold**: directory layout, doc skeletons, `.gitignore`, git init.
- [x] **Phase 1 — Extraction**: `marker-pdf==1.9.3` (not 2.0.0 — needs Docker) + PyMuPDF, batched into `EXTRACT_BATCH_PAGES`-sized subprocess calls (this session's 6GB memory cap OOM-killed a whole-book single call). Verified on real page ranges of the sample book.
- [x] **Phase 2 — LLM compilation**: chunking + nano-gpt calls → per-section narration segments with figure/table refs. Formulas turned out to need a different approach — see below. Model routing uses `deepseek/deepseek-v4-flash` (cheap tier) / `deepseek/deepseek-v4-pro:thinking` (strong tier); `meta/muse-spark-1.2-contributor` was dropped after verifying it returns `empty_response` on every request.
- [x] **Phase 3 — TTS + sync**: Chatterbox TTS narration per segment, sample-accurate concatenation → `segments.json`. Verified: computed timestamps matched actual `ffprobe` audio duration exactly on a real sample.
- [x] **Phase 4 — FastAPI backend**: `/books`, `/books/{id}/manifest`, `/books/{id}/download`, `/books/{id}/assets/*`. 4/4 backend tests pass (schema, audio timing, API).
- [x] **Phase 5 — Flutter app**: library screen, reader screen (zoom via photo_view, LaTeX highlight sync via flutter_math_fork, playback controls, autoplay/manual nav that always works), responsive layout, adjustable font scale. `flutter analyze` clean, 6/6 pure-Dart tests pass, debug APK builds.
- [x] **Phase 6 — End-to-end run**: **complete 2026-08-22**. 659-page book → 242 sections, 659/659 pages covered (was 558/659 before fix — 104 missing pages patched as 35 `sec_patch_*` supplements + 9 placeholder `needs_review` sections rewritten from raw text), 135 figures, 73 formulas, `441.6 min` audio, `430.5 MB` `backend/output/arm-fundamentals-soc.tar.gz` + unpacked `backend/output/arm-fundamentals-soc/` (manifest 144 K). Calm female voice `backend/voice/narrator_ref.wav` 12s ref, `TTS_EXAGGERATION 0.28` `PAUSE 260 ms` `backend/firebrat/config.py:23` (was 0.4/220). `FIREBRAT_SPARK_MODEL=deepseek/deepseek-v4-pro:thinking` forced after flash timed out ~40% of chunks; resume-from-checkpoint `compile_llm.py:239` + `retry_failed=True` + manifest `needs_review` propagation `manifest.py:120` landed. GitHub Pages site live; debug APK builds (release deferred while conversion held 6GB cgroup, now free).

## Real deviations from the original plan (found during implementation, not anticipated)

- **Formulas are LLM-authored, not Stage-1-extracted.** The sample book typesets math as plain inline text (e.g. `tCK = 1/f = 10 ns`), not LaTeX-taggable blocks — both marker's equation detection and a `$...$` regex found effectively zero real formulas across genuinely mathematical pages. Stage 2's LLM now recognizes relationships in the page text itself and authors LaTeX directly (`formula_callout` segments carry a `latex` field); our code still mints the `formula_NNNN` id, never the LLM. See `docs/DATA_SCHEMA.md`.
- **marker-pdf pinned to 1.9.3**, not 2.0.0 — 2.0's layout backend requires Docker (not installed here), exactly the risk called out in the original plan.
- **This session has a hard 6GB total RAM cap** (SLURM allocation), not just "GPU is MIG-partitioned" as originally scoped — this affected Stage 1 (had to batch) and the Flutter release build (must not run concurrently with the conversion pipeline). See `AGENTS.md`.

## Known deferred / out of scope for v1

- Live device/emulator smoke testing (adb does not run in this sandbox — see AGENTS.md).
- Multi-book concurrent conversion queue (pipeline is single-book CLI for now).
- Manifest diffing / incremental re-conversion (schema has `generated_at` to support this later).
- LLM-quality rewrite of the 44 `needs_review:true` supplements (35 `sec_patch_*` + 9 rewritten placeholders) — currently deterministic raw-text prose, flagged honestly; rerun `run_compilation(..., retry_failed=True)` with `FIREBRAT_SPARK_MODEL=deepseek/deepseek-v4-pro:thinking` in a tmux session to replace them.

## Handover — where to pick up (2026-08-22)

- **Latest archive:** `/scratch/sroy85/Github/firebrat/backend/output/arm-fundamentals-soc.tar.gz` (430.5 MB, 2026-08-22 04:51) + unpacked `backend/output/arm-fundamentals-soc/` with `manifest.json` 242 sections, `sections/sec_*/audio.m4a`, `assets/{figures 135, formulas 73}`. Old 204-section 336 MB tar at 09:26 is superseded.
- **Voice:** calm female `backend/voice/narrator_ref.wav` (12s, 384 KB) auto-used via `DEFAULT_VOICE_REF` `backend/firebrat/config.py:23` and recorded in `manifest.narrator_voice.reference_clip`. Delete it to fall back to default voice.
- **Resume:** `raw/compiled.json` 659/659 pages, 242 sections. Incremental TTS `tmp/incremental_tts.py:1` skips existing `sections/*/audio.m4a` + `segments.json` if segment count/text matches — safe to rerun. `tmux:firebrat_tts_calm:1` completed 12:39, now idle; `backend/full_conversion.log:1` has full history with `PYTHONUNBUFFERED=1` + `tee -a`.
- **Next steps:** `PYTHONPATH=backend /scratch/sroy85/conda-envs/firebrat-serve/bin/python -m pytest tests/ -v` (7/7), `flutter analyze` clean, then optionally LLM-refine the 44 supplements, then `flutter build apk --release` (now free of cgroup contention).
