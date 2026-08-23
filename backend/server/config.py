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
