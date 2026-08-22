# AGENTS.md — orientation for a coding agent picking this up cold

Read this before touching anything. It exists so a fresh agent (or a future you) doesn't have to re-derive the environment quirks that already cost real time to figure out once.

## What this project is

PDF → narrated, figure/formula-synced audiobook, read by a Flutter Android app. Full architecture rationale: `docs/ARCHITECTURE.md`. Data shapes: `docs/DATA_SCHEMA.md`. API surface: `docs/API.md`. Narrator voice setup: `docs/VOICE.md`. Current build status: `TASK.md`.

## Current handover (2026-08-22 — what a new agent should know first)

- **Latest archive is complete and at:** `/scratch/sroy85/Github/firebrat/backend/output/arm-fundamentals-soc.tar.gz` (430.5 MB, 2026-08-22 04:51) + unpacked `backend/output/arm-fundamentals-soc/` — 242 sections, 659/659 pages, 135 figs, 73 formulas, 441.6 min, calm female `backend/voice/narrator_ref.wav` (exaggeration 0.28, pause 260). Previous 204-section 336 MB tar at 09:26 is superseded; 44 sections are honest `needs_review:true` deterministic supplements (35 `sec_patch_*` + 9 fixed placeholders) that can be LLM-refined via `retry_failed=True` without re-extracting. `backend/full_conversion.log:1` holds the full 3-stage run + fix + calm TTS (PYTHONUNBUFFERED + tee -a).
- **Background work is now idle:** `tmux:firebrat_tts_calm:1` finished 12:39 in `backend/`. To continue: `PYTHONPATH=backend /scratch/sroy85/conda-envs/firebrat-serve/bin/python -m pytest tests/ -v` (7/7), `flutter analyze` clean, then optionally LLM-refine supplements in a new tmux with `FIREBRAT_SPARK_MODEL=deepseek/deepseek-v4-pro:thinking`.
- **Resume behaviour:** `compile_llm.py:239` `resume=True` by default — skips fully covered `source_pages`; `retry_failed=True` also redoes placeholder titles. `tmp/incremental_tts.py:1` skips existing `sections/*/audio.m4a` whose `segments.json` segment count/text already matches `compiled.json`. Safe to re-run.
- **Voice:** `DEFAULT_VOICE_REF backend/voice/narrator_ref.wav` `backend/firebrat/config.py:23` auto-used if present; delete to revert to default voice. Manifest records `narrator_voice.reference_clip`.

## Environment gotchas (confirmed, not assumed — re-verify if anything here seems stale)

- **This whole session runs inside a SLURM allocation capped at 6GB total RAM** (`scontrol show job <id>` → `mem=6000M`; check `cat /sys/fs/cgroup/memory/slurm/uid_*/job_*/memory.limit_in_bytes` to confirm the current cgroup). This is a *shared budget across every process in the job at once* — it OOM-killed a full-book marker-pdf run within seconds, and separately OOM-killed a Gradle release build that ran concurrently with the (memory-light-looking but nonzero) extraction pipeline. Consequences:
  - **Stage 1 extraction is batched.** marker-pdf batch-processes every page of whatever file it's given at once, so `convert.py` never calls it on the whole book — it runs `firebrat/pipeline/extract_batch_cli.py` as a fresh subprocess per `EXTRACT_BATCH_PAGES`-sized page range (`firebrat/config.py`, default 15), so peak memory is bounded regardless of book length and is fully released between batches. Do not "optimize" this back into a single whole-file call.
  - **Never run a Gradle/Flutter release build at the same time as the conversion pipeline** (or any other memory-heavy job in this session) — both can independently fit under 6GB but not simultaneously. `frontend/firebrat_app/android/gradle.properties` is already tuned down to `-Xmx2G` with `org.gradle.daemon=false`; if a release build still gets killed, check `free -h` / the cgroup usage file first before assuming it's a Flutter/Gradle bug.
  - If you hit an unexplained `SIGKILL` (exit 137) or "daemon disappeared unexpectedly" on anything, suspect this cgroup limit before anything else — check `dmesg | grep -i "killed process"` for `Memory cgroup out of memory` entries naming the PID.
- **GPU is MIG-partitioned.** `nvidia-smi -L` shows GPU0 exposes a single `MIG 3g.20gb` slice (~20GB usable), not a full 40GB card. Target it explicitly: `CUDA_VISIBLE_DEVICES=<MIG-UUID>` (get the current UUID from `nvidia-smi -L`, it can change if the partition is rebuilt — don't hardcode it blindly). GPU1 is a full A100 but shared with other cluster jobs; treat it as opportunistic overflow only, never assume its free memory.
- **Three separate conda environments are mandatory**, not a convenience: `extract` (marker-pdf, pymupdf, torch), `tts` (chatterbox-tts, pydub, soundfile — hard-pins `torch==2.6.0`/`transformers==5.2.0`, and needs `setuptools<81` pinned too or `ChatterboxTTS.from_pretrained()` raises `'NoneType' object is not callable` because its watermarker's `pkg_resources` import silently fails), `serve` (fastapi, uvicorn, zero torch). Do not try to merge `extract` and `tts` into one env — their pinned dependency sets conflict.
- **`marker-pdf` must be pinned to `1.9.3`, not `2.0.0`.** 2.0.0's layout backend (surya's vLLM path) hard-requires a `docker` binary, which isn't installed here — it fails immediately with `SpawnError: docker binary not found`. 1.9.3 uses the older local-torch Surya+Texify pipeline and works.
- **Formulas in this book are LLM-authored, not Stage-1-extracted.** This particular PDF typesets math as plain inline text (e.g. `tCK = 1/f = 10 ns`), not as LaTeX-taggable blocks — marker's equation extraction and a naive `$...$`-regex both find effectively zero real formulas. The Stage 2 LLM prompt (`firebrat/pipeline/compile_llm.py`) instead asks the model to recognize mathematical relationships in the page text itself and author real LaTeX for `formula_callout` segments via a `latex` field; **our own code mints the `formula_NNNN` id from that LaTeX, the LLM never assigns one** (same invariant as figure/table ids, just sourced differently). If you ever process a different, LaTeX-native PDF, re-check whether Stage 1's formula detection actually finds anything before assuming this LLM-authoring path is still necessary.
- A single malformed LLM ref (e.g. `"fig_1.15"` instead of `"fig_0001"`) will fail pydantic validation for the *whole chunk* unless pre-sanitized — `compile_llm.py`'s `_sanitize_refs()` nulls out any ref that doesn't match `^(fig|formula|tbl)_\d{4}$` before strict validation runs, so one bad ref doesn't discard an otherwise-good chunk's narration.
- **`adb` cannot run in this sandbox** — starting the adb daemon crashes on a network-interface probe (`OSP_CHECK` failure in `network_interface_linux.cc`). This means Flutter verification here is limited to `flutter analyze` and `flutter build apk` (static build check). There is no live device/emulator smoke test possible in this environment — do not claim the app "works on device" from inside this sandbox; say explicitly that only a static build was verified.
- **`ffmpeg` is not on `$PATH`** by default; it's available via the module system: `module load ffmpeg-6.0-2a`. `pydub` shells out to `ffmpeg` for AAC/MP3 export — load the module before running anything in `pipeline/audio_assemble.py` or `pipeline/tts.py`'s export step, or exports will fail silently/confusingly.
- **Redirect `HF_HOME`** (e.g. `export HF_HOME=/scratch/sroy85/.cache/huggingface`) before the first Chatterbox run — its weights auto-download from HuggingFace and home directories on this cluster tend to be quota-limited.
- System already has `pdflatex`, `dvipng`, `convert` (ImageMagick), `gs`, with `amsmath`/`amssymb` texlive packages — formula rendering shells out to these directly rather than using matplotlib mathtext (which can't render the amsmath macros marker-pdf's LaTeX extraction actually produces).
- Telegram progress pings use `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`, already exported in `~/.zshrc` — don't re-request these from the user, they're already available in the shell environment.
- nano-gpt LLM endpoint: `https://nano-gpt.com/api/v1`, OpenAI-compatible, key via `MODEL_API_KEY` (or `NANO_API_KEY`) env var — **do not** rely on a `MODEL_API_KEY` that might already be sitting in `~/.zshrc` without checking it first; one such pre-existing value in this environment was for an unrelated service that happened to authenticate against nano-gpt's public `/v1/models` listing but returned 401 on `/chat/completions`. Verify with a real chat completion call, not just a models listing, before trusting an ambient key. Model routing: `deepseek/deepseek-v4-pro:thinking` for chunks containing a likely equation (`=` pattern heuristic) or ≥2 figures/tables, `deepseek/deepseek-v4-flash` otherwise — **not** `meta/muse-spark-1.2-contributor` as originally planned, which returned `empty_response` on every single request when tested directly (community-hosted "contributor" tier model, unreliable — re-test before switching back to it). No published rate-limit numbers — extrapolate cost/time from a small run before committing to the full book and watch for 429s/read timeouts (120s timeout with retry/backoff is already implemented in `llm_client.py`, but individual `deepseek/deepseek-v4-pro:thinking` calls can legitimately take 60-90s).
- There is an unrelated prior project at `/scratch/sroy85/audiobook/alexandria-audiobook` (belongs to the same user, different TTS stack). Do not modify it. Its `app/tts.py` has a useful `compute_timeline()`-style pattern that this project's `audio_assemble.py` adapts — read-only reference, not a dependency.

## Common commands

```bash
# Full conversion (all 3 stages), run under the extract env — it auto-delegates
# Stage 3 to the tts env via subprocess when chatterbox isn't importable:
cd backend
export CUDA_VISIBLE_DEVICES="$(nvidia-smi -L | grep -oP 'MIG-[a-f0-9-]+' | head -1)"
export HF_HOME=/scratch/sroy85/.cache/huggingface
export MODEL_API_KEY=sk-...
export PATH="/packages/apps/spack/21.2/opt/spack/x86_64_v3/gcc-12.3.0/ffmpeg-6.0-2ac3emh/bin:$PATH"
/scratch/sroy85/conda-envs/firebrat-extract/bin/python convert.py ../arm-fundamentals-soc.pdf

# Quick test on a page slice instead of the whole book:
python convert.py ../book.pdf --start-page 40 --pages 32 --skip-tts

# Run backend tests (lightweight — serve env has everything needed, no GPU):
cd backend && /scratch/sroy85/conda-envs/firebrat-serve/bin/python -m pytest tests/ -v

# Serve book packages:
/scratch/sroy85/conda-envs/firebrat-serve/bin/python -m uvicorn server.main:app --host 0.0.0.0 --port 8000

# Flutter: analyze, test, build (see the memory-cgroup gotcha above before
# building while the conversion pipeline is also running):
cd frontend/firebrat_app
flutter analyze
flutter test
flutter build apk --debug    # or --release
```

Long conversions must run in `tmux` (not bare `nohup ... &` which does not survive in this harness) — see `backend/scripts/run_conversion.sh` and `README.md` quick-start for the env-var/PATH/`PYTHONUNBUFFERED=1` setup a background run needs, and `tmux capture-pane -p -t <session>` + `tail -f backend/full_conversion.log` to monitor. Use `FIREBRAT_SPARK_MODEL=deepseek/deepseek-v4-pro:thinking` if flash keeps timing out.

## Where to look first

- Pipeline entrypoint: `backend/convert.py` → `backend/firebrat/pipeline/*.py` (extract/extract_batch_cli → compile_llm → formulas/tts/audio_assemble → manifest).
- Shared schema (used by extraction, LLM validation, manifest building, and API responses): `backend/firebrat/pipeline/schema.py`.
- API contract: `backend/server/routes/books.py`, must match `docs/API.md` and `docs/DATA_SCHEMA.md` exactly.
- Reader sync logic (the actual "highlight while it's spoken" feature): `frontend/firebrat_app/lib/services/playback_controller.dart` (drives active-segment state from position stream) and `lib/state/reader_providers.dart` (owns the section/playback session, autoplay logic).

## Flutter-specific note

This project pins `flutter_riverpod: ^3.3.2`, not the latest 3.4.x — the installed Dart SDK (3.11.1, from Flutter 3.41.3) is below riverpod 3.4's `^3.12.0` requirement. Riverpod 3.x's family-notifier pattern also differs from 2.x/codegen examples you may recall: there's no `FamilyNotifier<State, Arg>` base class in this version. Instead, extend plain `Notifier<State>`, take the family arg via the notifier's own constructor, and wire it up as `NotifierProvider.family<MyNotifier, State, Arg>((arg) => MyNotifier(arg))` — see `lib/state/reader_providers.dart`'s `ReaderController` for the working pattern before assuming a codegen-style API is available.
