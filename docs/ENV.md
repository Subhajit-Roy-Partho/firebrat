# Environment Variables

All variables are read at process start via `firebrat/config.py:12` `_load_dotenv()` (loads `backend/.env`) and `server/config.py`. Shell exports (e.g. `~/.zshrc`, `tmux` launch command) override `.env` via `os.environ.setdefault` — the shell wins.

## Backend pipeline (`backend/.env`)

| Variable | Default | Required | Description |
|---|---|---|---|
| `MODEL_API_KEY` | `""` | **yes** for Stage 2 | nano-gpt / OpenAI-compatible key. `NANO_API_KEY` is an alias (`config.py:31`). Set in `~/.zshrc` on this cluster; `backend/.env` is the portable place. Test with a real `chat/completions` call, not just `models` listing (see `AGENTS.md`). |
| `NANO_API_URL` | `https://nano-gpt.com/api/v1` | no | Override for self-hosted OpenAI-compatible endpoint. |
| `LLM_PROVIDER` | `nanogpt` | no | Docker entrypoint only: `local` also boots `backend/scripts/llm_server.py` on the container GPU. Bare-metal runs set `NANO_API_URL` directly. See `docs/LLM_PROVIDERS.md`. |
| `LOCAL_MODEL_DIR` | — | yes, for `LLM_PROVIDER=local` | Mounted HF snapshot dir (e.g. `/models/qwen3-4b`). Weights are never baked into the image. |
| `LOCAL_LLM_PORT` / `LOCAL_MAX_SEQ_LEN` | `8080` / `16384` | no | Local shim port and context cap (KV cache must fit VRAM). |
| `FIREBRAT_CHUNK_PAGES` | `10` | no | Pages per LLM chunk. Lower (e.g. `2`) when the endpoint kills long generations — see `docs/LLM_PROVIDERS.md`. |
| `FIREBRAT_SPARK_MODEL` | `deepseek/deepseek-v4-flash` | no | Cheap tier model. Set to `deepseek/deepseek-v4-pro:thinking` if flash times out (~40% of chunks on 659-page book). |
| `FIREBRAT_DEEPSEEK_MODEL` | `deepseek/deepseek-v4-pro:thinking` | no | Strong tier model (auto-selected for equation/table-heavy chunks). |
| `TELEGRAM_BOT_TOKEN` | `""` | no | Telegram progress pings (`pipeline/notify.py:14`). Already exported in `~/.zshrc` on this host; optional but recommended for long runs (`backend/scripts/run_conversion.sh` loads it). |
| `TELEGRAM_CHAT_ID` | `""` | no | Paired with `TELEGRAM_BOT_TOKEN`. |
| `HF_HOME` | `/scratch/sroy85/.cache/huggingface` | no | HuggingFace cache for Chatterbox weights (home quota is small on this cluster). |
| `FIREBRAT_OUTPUT_DIR` | `backend/output` | no | Where book packages are written. |
| `FIREBRAT_EXTRACT_PY` | `/scratch/sroy85/conda-envs/firebrat-extract/bin/python` | no | Python for Stage 1 (marker-pdf). Overridden inside Docker to the single-env python. |
| `FIREBRAT_TTS_PY` | `/scratch/sroy85/conda-envs/firebrat-tts/bin/python` | no | Python for Stage 3 (chatterbox). |
| `FIREBRAT_CONVERT_PY` | `sys.executable` | no | For `server/job_runner.py` when running the server in split-env mode. |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | `""` | no | Path to Firebase service-account JSON for backend FCM sends (see `docs/FIREBASE.md`). |

Example `backend/.env` (gitignored):

```ini
MODEL_API_KEY=sk-nano-...         # or NANO_API_KEY
TELEGRAM_BOT_TOKEN=8338741962:AAF...
TELEGRAM_CHAT_ID=5765775772
HF_HOME=/scratch/sroy85/.cache/huggingface
# FIREBRAT_SPARK_MODEL=deepseek/deepseek-v4-pro:thinking
```

## Server (`server/config.py`)

| Variable | Default | Description |
|---|---|---|
| `FIREBRAT_OUTPUT_DIR` | `backend/output` | Same as pipeline output. |
| `FIREBRAT_HOST` | `0.0.0.0` | Uvicorn bind. |
| `FIREBRAT_PORT` | `8000` | Uvicorn port. |
| `FIREBRAT_UPLOAD_DIR` | `backend/uploads` | Temp PDFs from `POST /books/upload`. |
| `FIREBRAT_JOBS_DB` | `backend/jobs.sqlite3` | SQLite for job queue. |
| `FIREBRAT_MAX_CONCURRENT_JOBS` | `1` | How many books convert at the same time; further uploads wait in the queue (1-16, invalid values fall back to 1 with a log warning). Keep 1 on a 6GB cgroup; raise only with headroom, since each running job holds several GB of RAM plus GPU memory. Set it in `.env` (see `.env.example`). The web UI and `GET /settings` show the worker count. |
| `FIREBRAT_MAX_UPLOAD_MB` | `500` | Upload cap. |
| `FIREBRAT_AVATAR_DIR` | `<uploads dir>/../avatars` | Where profile avatars are stored (`PUT /me/avatar`). |
| `FIREBRAT_MAX_AVATAR_KB` | `2048` | Largest accepted avatar (16-10240). |
| `FIREBRAT_LOCAL_LLM_URL` | `http://127.0.0.1:8080/v1` | Where provider=local jobs point (the shim, or Docker local mode). |
| `FIREBASE_WEB_API_KEY` | _(android key)_ | Browser sign-in override if the default key is restricted. |

## Frontend (`--dart-define`)

| Variable | Default | Description |
|---|---|---|
| `FIREBRAT_API_BASE_URL` | `http://10.0.2.2:8000` | Fallback API URL (emulator). Runtime value is `conversionModeProvider.cloudServerUrl` from *Conversion settings* screen; dart-define only seeds a fresh install. |

## Verifying

```bash
# Backend pipeline
PYTHONPATH=backend /scratch/sroy85/conda-envs/firebrat-serve/bin/python -m pytest backend/tests -v  # 15 passed
# Env check
grep -E "MODEL_API|TELEGRAM|HF_HOME|FIREBRAT" backend/.env
env | grep -E "MODEL_API|TELEGRAM|HF_HOME|FIREBRAT"
# Server
PYTHONPATH=backend /scratch/sroy85/conda-envs/firebrat-serve/bin/python -m uvicorn server.main:app --host 0.0.0.0 --port 8000
# Flutter
flutter analyze  # No issues found
```

All 15 backend tests + `flutter analyze` / `flutter test` must pass before pushing (see `TASK.md`).

