# Developer Guide

How to work on Firebrat: local setup, tests, and every GitHub Action. Start with
`AGENTS.md` (environment gotchas) and `docs/ARCHITECTURE.md` (system design).

## 1. Prerequisites

- **Python 3.11** with three separate conda envs (mandatory, do not merge —
  their pinned dependencies conflict):
  - `firebrat-extract` — marker-pdf, pymupdf, torch (Stage 1 extraction)
  - `firebrat-tts` — chatterbox-tts, pydub, soundfile; pins `torch==2.6.0`,
    `transformers==5.2.0`, `setuptools<81`
  - `firebrat-serve` — fastapi, uvicorn, zero torch (tests + API server)
- **Flutter** stable channel (`flutter analyze`, `flutter test`,
  `flutter build apk/appbundle`). Note `flutter_riverpod` is pinned to `^3.3.2`
  (see `AGENTS.md`).
- **System tools:** `pdflatex`, `dvipng`, `convert` (ImageMagick), `gs`,
  `ffmpeg` (via `module load ffmpeg-6.0-2a` on the cluster, not `$PATH`).
- **Cluster gotchas:** the SLURM job has a shared RAM cgroup cap (check
  `memory.limit_in_bytes` + `free -h`); never run a Gradle release build
  concurrently with the conversion pipeline. GPU is a MIG slice — get the UUID
  from `nvidia-smi -L` each session. `marker-pdf` must stay at `1.9.3`
  (2.0.0 requires a `docker` binary).

## 2. Key commands

```bash
# Backend tests (lightweight, serve env has everything, no GPU):
cd backend && /scratch/sroy85/conda-envs/firebrat-serve/bin/python -m pytest tests/ -v

# Serve book packages:
.../firebrat-serve/bin/python -m uvicorn server.main:app --host 0.0.0.0 --port 8000

# Full conversion (extract env auto-delegates Stage 3 to tts env):
cd backend
export CUDA_VISIBLE_DEVICES="$(nvidia-smi -L | grep -oP 'MIG-[a-f0-9-]+' | head -1)"
export HF_HOME=/scratch/sroy85/.cache/huggingface   # keep weights off home quota
export MODEL_API_KEY=sk-...
/scratch/sroy85/conda-envs/firebrat-extract/bin/python convert.py ../book.pdf

# Quick slice without TTS:
python convert.py ../book.pdf --start-page 40 --pages 32 --skip-tts

# Flutter:
cd frontend/firebrat_app
flutter analyze
flutter test
flutter build apk --debug
```

Long conversions must run in `tmux` (not bare `nohup`), with `PYTHONUNBUFFERED=1`
— see `backend/scripts/run_conversion.sh`. Monitor with
`tmux capture-pane -p -t <session>` + `tail -f backend/full_conversion.log`.

## 3. Environment variables

Full table in `docs/ENV.md`. Most important:

| Var | Purpose |
|---|---|
| `MODEL_API_KEY` / `NANO_API_KEY` (aliases) | Stage-2 LLM key (nano-gpt). Verify with a real chat/completions call, not a models listing |
| `NANO_API_URL` | LLM endpoint (default `https://nano-gpt.com/api/v1`) |
| `LLM_PROVIDER` | `nanogpt` \| `local` |
| `FIREBRAT_SPARK_MODEL` | Chunk model override, e.g. `deepseek/deepseek-v4-pro:thinking` |
| `FIREBRAT_CHUNK_PAGES` | Pages per LLM chunk (default 10) |
| `FIREBRAT_*_PY` | Stage interpreter overrides |
| `FIREBRAT_OUTPUT_DIR` / `UPLOAD_DIR` / `JOBS_DB` / `MAX_CONCURRENT_JOBS` (≤16) / `MAX_UPLOAD_MB` (500) | Server paths and caps |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | Progress pings (already in shell) |
| `HF_HOME` | Redirect model downloads off quota-limited home |
| `CUDA_VISIBLE_DEVICES` | MIG UUID from `nvidia-smi -L` |
| `FIREBRAT_API_BASE_URL` | Dart-define, default `http://10.0.2.2:8000` |

Server modules must use `from server import config` + call-time `config.X`
— never `from server.config import X` (freezes values, breaks tests).

## 4. GitHub Actions

All workflows live in `.github/workflows/`. Helper script:
`.github/scripts/publish-server-docker-release.sh` (appends Docker image notes +
launcher to a server release).

| Workflow | Trigger | What it does | Secrets needed |
|---|---|---|---|
| `ci.yml` — CI | push to `main`/`master`, PRs, manual | Backend tests · `flutter analyze` + `flutter test` · debug APK build · pipeline import smoke checks | `GOOGLE_SERVICES_JSON` (debug build only) |
| `flutter-release.yml` — Flutter release | **`v*` tag push** or manual (`flavor`: apk/appbundle/both; `play_status`: draft/completed/none) | Release build (signed) → 16 KB alignment + ONNX checks → Play upload (manual dispatch only) → **GitHub Release page with APK+AAB (tag pushes only)** | Keystore ×4, `GOOGLE_SERVICES_JSON`, `PLAY_SERVICE_ACCOUNT_JSON` |
| `play-store.yml` — Play Store bundle | manual only (`play_status`: draft/completed) | Signed AAB build, then calls `play-upload.yml` | Keystore ×4, `GOOGLE_SERVICES_JSON`, Play SA (inherited) |
| `play-upload.yml` — Upload verified bundle to Play | manual or called by `play-store.yml` (`build_run_id` required; `verify_only` dry-run) | Re-verifies a built AAB, uploads to Play **alpha** track | `PLAY_SERVICE_ACCOUNT_JSON` |
| `play-listing.yml` — Play listing | manual only (`dry_run`, default true) | Publishes store text + screenshots in one atomic Play edit | `PLAY_SERVICE_ACCOUNT_JSON` |
| `apple-release.yml` — Apple unsigned release | `v*` tag push or manual | Unsigned IPA + SHA-256, attaches to tag release | none |
| `server-installers.yml` — Desktop server installers | `server-v*` / `v*` tag push or manual | macOS DMG + Linux RUN installer + smoke test, attaches to tag release | none |
| `docker-publish.yml` — Publish Docker images | push to `main`, `v*`/`server-v*` tags, or manual | CPU/GPU/API images → Docker Hub; desktop image with smoke test | `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` |
| `generate-book.yml` — Generate book (pipeline) | manual only (`pdf_url`, `book_id`, `spark_model`, `skip_tts`) | Runs the full conversion pipeline in CI (up to 6 h), uploads book packages + log | `MODEL_API_KEY`, `NANO_API_KEY` |

CI check scripts in `frontend/firebrat_app/tool/` (fail the build with a
readable reason): `check_native_alignment.py` (16 KB pages),
`check_onnx_classes.py` (R8 kept ONNX JNI), `check_play_access.py` (Play grant
probe), `play_listing.py` (listing publisher). `benchmark_android_models.py` and
the debug entry points (`model_benchmark.dart`, `local_conversion_probe.dart`)
are manual-only, not CI.

### Secrets inventory

- Android signing: `ANDROID_KEYSTORE_BASE64`, `KEY_STORE_PASSWORD`,
  `KEY_ALIAS`, `KEY_PASSWORD`
- Firebase: `GOOGLE_SERVICES_JSON` (base64 `google-services.json`)
- Play Console: `PLAY_SERVICE_ACCOUNT_JSON` (needs a Users-and-permissions
  grant on the app)
- Other: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `MODEL_API_KEY`,
  `NANO_API_KEY`

### Release process

1. Bump `version:` in `frontend/firebrat_app/pubspec.yaml` (`1.7.3+32` =
   versionName 1.7.3, versionCode 32).
2. Push a tag: `git tag -a v1.7.3 -m "1.7.3" && git push origin v1.7.3`.
   This builds signed artifacts and creates the **GitHub Release page**
   automatically. Tag pushes never upload to Play.
3. Play Console uploads are always manual: run `Play Store bundle`
   (build + upload to alpha as draft/completed) or upload the AAB yourself.
   Write cumulative release notes (cover everything since the last Play
   release — Play testers on old versions only see the latest notes).

### What works on a fork (no secrets)

`ci.yml` backend tests, `flutter analyze`/`test`, and pipeline smoke checks run
secretless, as do `server-installers.yml` and `apple-release.yml` builds
(only their release-attach step needs a token, auto-provided). Anything
signing/uploading (release keystore, Play, Docker Hub, LLM pipeline) needs
maintainer secrets.

## 5. Conventions

- **Git identity:** never `git config user.name/email` — rely on system
  identity; use Co-Authored-By trailers.
- Read files with read/grep tools, not `cat/head/sed` pipelines; use shell for
  execution (tests, builds, git).
- Docs: `docs/API.md` + `docs/DATA_SCHEMA.md` are the API contract;
  `docs/PLAY_STORE_RELEASE.md` tracks submission gates; `TASK.md` tracks build
  status. Update them when behavior changes.
