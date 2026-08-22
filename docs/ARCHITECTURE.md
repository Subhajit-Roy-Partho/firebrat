# Architecture

## Overview

Firebrat has two independent halves that only touch through the book package format (`docs/DATA_SCHEMA.md`):

1. **Backend pipeline** (`backend/`) — a one-shot CLI (`convert.py`) that turns a PDF into a self-contained book package, plus a thin FastAPI layer that serves finished packages.
2. **Flutter app** (`frontend/firebrat_app/`) — downloads a book package once, then reads and plays it fully offline.

Nothing in the reader ever calls back into the pipeline or requires the backend to stay running after the initial download.

## Pipeline stages

### Stage 1 — Extraction (`firebrat/pipeline/extract.py`, `extract_batch_cli.py`)

Input: the source PDF. Output: `raw/raw_pages.json` (per-page text + detected figure/table/formula assets) and `assets/{pages,figures,tables}/*.png`.

Two tools, two jobs:
- **marker-pdf** (pinned to `1.9.3`) does layout-aware markdown extraction — better paragraph/heading structure than raw PyMuPDF text.
- **PyMuPDF** renders every page to PNG (the reader's pinch-zoom fallback) and crops embedded images into `assets/figures/*.png` with stable ids.

This stage runs in small page-range batches, each a separate subprocess (`extract_batch_cli.py`), not one call over the whole book — marker batch-processes every page it's given at once, and this environment's memory budget can't hold a 600+ page book's worth of layout/OCR model activations at once. See `AGENTS.md` for the specific constraint that forced this.

Formula detection in this stage is a low-confidence supplementary signal only (a `$...$` regex over extracted text) — for born-digital PDFs that typeset math as plain text rather than embedded LaTeX, it typically finds nothing, and that's expected. Formulas are actually sourced in Stage 2.

### Stage 2 — LLM compilation (`firebrat/pipeline/compile_llm.py`)

Input: `raw_pages.json`. Output: `compiled.json` (sections of ordered narration segments) plus a `formulas` list.

Pages are grouped into `CHUNK_PAGES`-sized chunks. Each chunk is sent to an LLM (nano-gpt endpoint) with:
- The raw page text for that chunk.
- A **catalog** of the figure/table ids and captions Stage 1 already found on those pages — the model may only reference ids from this catalog, never invent one, and refs are pattern-validated then cross-checked against the catalog after parsing.

The model returns narration-ready prose, broken into short segments (`heading` / `prose` / `figure_callout` / `formula_callout` / `table_callout`), each optionally referencing a figure/table id and flagged `visually_essential` when audio alone can't convey it.

**Formulas are the one place the model contributes content beyond narration text.** This book typesets math as plain inline text (`tCK = 1/f = 10 ns`), not LaTeX — so there's nothing for Stage 1 to extract. The model is asked to recognize the relationship itself and write real LaTeX into a `latex` field on `formula_callout` segments. Our own code (never the model) then mints the `formula_NNNN` id from that LaTeX and adds it to a `formulas` catalog — the "ids come from code, not the LLM" invariant holds for formulas too, just via a different data source.

Chunks route to a stronger model (`deepseek/deepseek-v4-pro:thinking`) when they look equation-dense or figure/table-heavy, and a cheaper one (`deepseek/deepseek-v4-flash`) otherwise. Malformed JSON gets retried with the parse error appended to the prompt, then escalated to the strong model; a chunk that still fails becomes a `needs_review: true` placeholder rather than aborting the whole run. A single malformed ref (wrong id format) is sanitized to `null` before validation, so it doesn't discard the rest of an otherwise-good chunk.

### Reliability notes (added 2026-08-21 after full-book run)

- **Flash tier is currently flaky.** On the 659-page run, `deepseek/deepseek-v4-flash` timed out (240s ×5 retries, `requests.exceptions.ReadTimeout`) on ~40% of chunks while `pro:thinking` on the same pages succeeded — the flash endpoint appears overloaded, not a prompt bug. Both model names are env-overridable (`firebrat/config.py:14`): set `FIREBRAT_SPARK_MODEL=deepseek/deepseek-v4-pro:thinking` to force the strong model for all chunks if flash keeps failing. Cost is ~2-3× tokens but avoids 17 min wasted per failed chunk.
- **Resume from checkpoint.** `compile_llm.py:239` now loads an existing `compiled.json` if present, computes the set of already-covered `source_pages`, and skips chunks fully covered (`resume=True` by default). `formula_counter` and `needs_review_chunks` are restored from the checkpoint too (`formula_counter` persisted explicitly). A failed placeholder can be retried by re-running with `retry_failed=True` (clears its placeholder sections first). Each chunk still checkpoints immediately (`compile_llm.py:317`), so an interrupted run loses at most one chunk.
- **Schema hallucination guard.** Some `pro:thinking` responses returned a JSON Schema (`{"type":"object","properties":…}`) instead of an instance — detected explicitly (`compile_llm.py:274`) and retried. Blank-title chunks are repaired via `_fill_blank_titles` before validation, and validation failures now get one fallback-model retry before falling back to a placeholder.
- **Timeout tuning.** `firebrat/llm_client.py:30` defaults to 240s because observed latency is 60-150s even on success; tightening it just burns another retry cycle. Increase via `chat_completion(..., timeout=...)` if your endpoint is slower.

### Stage 3 — TTS + sync (`firebrat/pipeline/tts.py`, `formulas.py`, `audio_assemble.py`)

Input: `compiled.json`. Output: `sections/<id>/audio.m4a` + `sections/<id>/segments.json`, and `assets/formulas/*.png`.

- **`formulas.py`** renders each LLM-authored LaTeX string to a cropped PNG via `pdflatex` (article class — `standalone.cls` isn't installed on this host) → Ghostscript rasterization → ImageMagick trim. This is the fallback path if the app's live vector rendering (`flutter_math_fork`) can't parse a given LaTeX string.
- **`tts.py`** wraps Chatterbox TTS, synthesizing one WAV per segment with the calm female voice `backend/voice/narrator_ref.wav` + `exaggeration 0.28` / `cfg 0.45` `backend/firebrat/config.py:23` — see `docs/VOICE.md`. 242-section archive total 441.6 min with this voice.
- **`audio_assemble.py`** concatenates a section's segment WAVs with `PAUSE 260 ms` between them, tracking a running `cursor_ms` from each clip's *actual* sample-derived duration (not an estimate) to produce exact `start_ms`/`end_ms` per segment — this is what makes the reader's highlight-while-spoken feature frame-accurate rather than approximate.

Because Chatterbox's dependency pins conflict with marker-pdf's, this stage runs under a separate conda env. `convert.py` detects whether `chatterbox` is importable in the current process and auto-delegates Stage 3 to the right env's Python via subprocess if not — a single `convert.py` invocation still does the whole pipeline end to end.

### Manifest (`firebrat/pipeline/manifest.py`)

Merges Stage 1's figures/tables, Stage 2's LLM-authored formulas, and Stage 3's per-section durations into the final `manifest.json` — the one file the Flutter app actually reads to know what a book contains. Now records `narrator_voice.reference_clip` (calm female), `exaggeration 0.28`, `needs_review` via title/placeholder heuristic (`manifest.py:120` — 44 `needs_review:true` supplements in current 242-section archive).

## Backend serving model

`server/` is deliberately thin: list packages under `backend/output/`, serve a manifest, zip-and-serve a full package on demand (cached until the manifest's mtime changes), serve individual assets with path-traversal guarding. It holds no state beyond the filesystem and needs no database. See `docs/API.md`.

## Frontend architecture

- **State**: Riverpod. `library_providers.dart` (catalog, downloads), `reader_providers.dart` (per-book session: manifest, current section, live `PlaybackController`), `settings_providers.dart` (speed, autoplay, font scale — persisted via `shared_preferences`).
- **Audio**: `just_audio`, one player per reader session, wrapped by `PlaybackController`. Its `positionStream` drives a binary search over the current section's `segments.json` to find the active segment — that active-segment id is the single source of truth every highlight widget watches.
- **Manual navigation always works.** Tapping a segment, or the prev/next segment buttons, calls `player.seek()` directly — this is completely independent of whether autoplay is enabled. Autoplay is implemented as a `sectionCompleteStream` listener that, if enabled, waits a configurable delay and advances — it never gates or blocks a manual action.
- **Figures/tables never hide.** `FigureGallery` always renders every figure/table for the current section in a horizontally-scrollable row; the one currently referenced by the active segment gets a border/glow, nothing is removed from view.

## Why these choices

- **Chatterbox TTS over Kokoro-82M**: chosen for narration naturalness/expressiveness on long-form technical content, given ample A100 headroom; Kokoro would have been the faster/lighter choice.
- **marker-pdf over hand-rolled PyMuPDF-only extraction**: layout-aware markdown structure (headings, paragraph grouping) that raw text extraction doesn't give you — even though, for this particular book, its formula detection turned out not to be the useful part.
- **Per-segment TTS synthesis + timestamp bookkeeping over forced alignment**: exact boundaries with no separate alignment model or its failure modes — the cost is many small TTS calls instead of one long one, which is a fine tradeoff given GPU availability.
- **Offline-first package download over live streaming**: a mobile audiobook reader should work on a train with no signal once you've downloaded a book; the backend's job ends at "hand over a complete package."
