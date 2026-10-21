"""FastAPI server config."""
import os
import sys

_BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

OUTPUT_DIR = os.environ.get("FIREBRAT_OUTPUT_DIR", os.path.join(_BACKEND_DIR, "output"))
HOST = os.environ.get("FIREBRAT_HOST", "0.0.0.0")
PORT = int(os.environ.get("FIREBRAT_PORT", "8000"))

# ── Upload + conversion job queue ───────────────────────────────
UPLOAD_DIR = os.environ.get("FIREBRAT_UPLOAD_DIR", os.path.join(_BACKEND_DIR, "uploads"))
JOBS_DB_PATH = os.environ.get("FIREBRAT_JOBS_DB", os.path.join(_BACKEND_DIR, "jobs.sqlite3"))
CONVERT_SCRIPT = os.path.join(_BACKEND_DIR, "convert.py")
# The python that runs convert.py itself (it auto-delegates the TTS stage
# onward when needed — see AGENTS.md). Defaults to whatever's running the
# server, which is correct inside a single-env container; on the dev
# cluster's split conda envs this must point at the extract env's python.
CONVERT_PY = os.environ.get("FIREBRAT_CONVERT_PY", sys.executable)
# How many conversions run at once. Conversion is memory/GPU heavy (see
# AGENTS.md's 6GB cgroup note) — default to strictly one at a time unless a
# deployment explicitly knows it has headroom for more.
MAX_CONCURRENT_JOBS = int(os.environ.get("FIREBRAT_MAX_CONCURRENT_JOBS", "1"))
MAX_UPLOAD_MB = int(os.environ.get("FIREBRAT_MAX_UPLOAD_MB", "500"))

# ── Stage-2 LLM routing ─────────────────────────────────────────
# Jobs may choose provider=local (on-server GPU model) instead of the
# default nanogpt cloud endpoint. The local OpenAI-compatible shim
# (backend/scripts/llm_server.py, or the Docker entrypoint's local mode)
# listens here; per-job env override in job_runner points the pipeline
# at it. Empty/unreachable => those chunks fail into placeholders, the
# same honest failure as any dead endpoint (never silent).
LOCAL_LLM_URL = os.environ.get("FIREBRAT_LOCAL_LLM_URL", "http://127.0.0.1:8080/v1")
# Which local weights to load, by machine size. Keys into
# server/models.py LOCAL_MODEL_PRESETS (repo id + VRAM note). The Docker
# entrypoint auto-downloads the preset when the dir is empty.
LOCAL_MODEL_PRESET = os.environ.get("LOCAL_MODEL_PRESET", "qwen3-4b")
LOCAL_MODEL_DIR = os.environ.get("LOCAL_MODEL_DIR", "")
