# AGENTS.md — orientation for a coding agent picking this up cold

Read this before touching anything. It exists so a fresh agent (or a future you) doesn't have to re-derive the environment quirks that already cost real time to figure out once.

## What this project is

PDF → narrated, figure/formula-synced audiobook, read by a Flutter Android app. Full architecture rationale: `docs/ARCHITECTURE.md`. Data shapes: `docs/DATA_SCHEMA.md`. API surface: `docs/API.md`. Narrator voice setup: `docs/VOICE.md`. Current build status: `TASK.md`.

## Environment gotchas (confirmed, not assumed — re-verify if anything here seems stale)

- **Three separate conda environments are mandatory**, not a convenience: `extract` (marker-pdf, pymupdf, torch), `tts` (chatterbox-tts, pydub, soundfile — hard-pins `torch==2.6.0`/`transformers==5.2.0`), `serve` (fastapi, uvicorn, zero torch). Do not try to merge `extract` and `tts` into one env — their pinned dependency sets conflict.
- **GPU is MIG-partitioned.** `nvidia-smi -L` shows GPU0 exposes a single `MIG 3g.20gb` slice (~20GB usable), not a full 40GB card. Target it explicitly: `CUDA_VISIBLE_DEVICES=<MIG-UUID>` (get the current UUID from `nvidia-smi -L`, it can change if the partition is rebuilt — don't hardcode it blindly). GPU1 is a full A100 but shared with other cluster jobs; treat it as opportunistic overflow only, never assume its free memory.
- **`adb` cannot run in this sandbox** — starting the adb daemon crashes on a network-interface probe (`OSP_CHECK` failure in `network_interface_linux.cc`). This means Flutter verification here is limited to `flutter analyze` and `flutter build apk` (static build check). There is no live device/emulator smoke test possible in this environment — do not claim the app "works on device" from inside this sandbox; say explicitly that only a static build was verified.
- **`ffmpeg` is not on `$PATH`** by default; it's available via the module system: `module load ffmpeg-6.0-2a`. `pydub` shells out to `ffmpeg` for AAC/MP3 export — load the module before running anything in `pipeline/audio_assemble.py` or `pipeline/tts.py`'s export step, or exports will fail silently/confusingly.
- **Redirect `HF_HOME`** (e.g. `export HF_HOME=/scratch/sroy85/.cache/huggingface`) before the first Chatterbox run — its weights auto-download from HuggingFace and home directories on this cluster tend to be quota-limited.
- System already has `pdflatex`, `dvipng`, `convert` (ImageMagick), `gs`, with `amsmath`/`amssymb` texlive packages — formula rendering shells out to these directly rather than using matplotlib mathtext (which can't render the amsmath macros marker-pdf's LaTeX extraction actually produces).
- Telegram progress pings use `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`, already exported in `~/.zshrc` — don't re-request these from the user, they're already available in the shell environment.
- nano-gpt LLM endpoint: `https://nano-gpt.com/api/v1`, OpenAI-compatible. Model routing: `deepseek/deepseek-v4-pro:thinking` for chunks containing a formula or ≥2 figures/tables, `meta/muse-spark-1.2-contributor` otherwise. No published rate-limit numbers — Phase 2 was verified only at small scale (2-3 chapters); extrapolate before running the full book and watch for 429s.
- There is an unrelated prior project at `/scratch/sroy85/audiobook/alexandria-audiobook` (belongs to the same user, different TTS stack). Do not modify it. Its `app/tts.py` has a useful `compute_timeline()`-style pattern that this project's `audio_assemble.py` adapts — read-only reference, not a dependency.

## Common commands

<!-- fill in exact commands as each phase lands: conda env create, convert.py invocation, uvicorn launch, flutter build -->

## Where to look first

- Pipeline entrypoint: `backend/convert.py` → `backend/firebrat/pipeline/*.py` (extract → compile_llm → tts/formulas/audio_assemble → manifest).
- Shared schema (used by extraction, LLM validation, manifest building, and API responses): `backend/firebrat/pipeline/schema.py`.
- API contract: `backend/server/routes/books.py`, must match `docs/API.md` and `docs/DATA_SCHEMA.md` exactly.
- Reader sync logic (the actual "highlight while it's spoken" feature): `frontend/firebrat_app/lib/services/playback_controller.dart`.
