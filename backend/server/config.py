"""FastAPI server config."""
import logging
import os
import sys

_BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

OUTPUT_DIR = os.environ.get("FIREBRAT_OUTPUT_DIR", os.path.join(_BACKEND_DIR, "output"))
HOST = os.environ.get("FIREBRAT_HOST", "0.0.0.0")
PORT = int(os.environ.get("FIREBRAT_PORT", "8000"))

_log = logging.getLogger("firebrat.server.config")


def _int_env(name: str, default: int, lo: int, hi: int) -> int:
    """Integer env var clamped to [lo, hi]. A typo'd or out-of-range value
    must never stop the server booting or wedge the queue, so it falls back
    (non-numeric) or clamps (out of range) and says so in the log."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        _log.warning("%s=%r is not an integer; using %d", name, raw, default)
        return default
    clamped = max(lo, min(hi, value))
    if clamped != value:
        _log.warning("%s=%d is outside %d-%d; using %d", name, value, lo, hi, clamped)
    return clamped


# ── Upload + conversion job queue ───────────────────────────────
UPLOAD_DIR = os.environ.get("FIREBRAT_UPLOAD_DIR", os.path.join(_BACKEND_DIR, "uploads"))
JOBS_DB_PATH = os.environ.get("FIREBRAT_JOBS_DB", os.path.join(_BACKEND_DIR, "jobs.sqlite3"))
CONVERT_SCRIPT = os.path.join(_BACKEND_DIR, "convert.py")
# The python that runs convert.py itself (it auto-delegates the TTS stage
# onward when needed — see AGENTS.md). Defaults to whatever's running the
# server, which is correct inside a single-env container; on the dev
# cluster's split conda envs this must point at the extract env's python.
CONVERT_PY = os.environ.get("FIREBRAT_CONVERT_PY", sys.executable)
# Operators may upgrade the API before a customized conversion engine. Keep
# unsupported newer inputs out of its queue instead of accepting doomed jobs.
CONVERTER_SUPPORTS_EBOOKS = os.environ.get(
    "FIREBRAT_CONVERTER_SUPPORTS_EBOOKS", "true").strip().lower() not in {"0", "false", "no"}
CONVERTER_SUPPORTS_CHARACTER_TRAITS = os.environ.get(
    "FIREBRAT_CONVERTER_SUPPORTS_CHARACTER_TRAITS", "true").strip().lower() not in {"0", "false", "no"}
# How many conversions run at once (extra uploads wait in the queue).
# Conversion is memory/GPU heavy (see AGENTS.md's 6GB cgroup note: each
# running job holds several GB of RAM plus GPU memory), so the default is
# strictly one at a time. Raise it in .env only on a host with the headroom
# for that many simultaneous jobs. Clamped to 1-16.
MAX_CONCURRENT_JOBS = _int_env("FIREBRAT_MAX_CONCURRENT_JOBS", 1, 1, 16)
MAX_UPLOAD_MB = int(os.environ.get("FIREBRAT_MAX_UPLOAD_MB", "500"))
# Profile avatars (PUT /me/avatar): stored next to the uploads dir by default.
AVATAR_DIR = os.environ.get("FIREBRAT_AVATAR_DIR", os.path.join(os.path.dirname(UPLOAD_DIR), "avatars"))
MAX_AVATAR_KB = _int_env("FIREBRAT_MAX_AVATAR_KB", 2048, 16, 10240)

# ── Expressive-cast ("cast") mode ───────────────────────────────
# Additive: when FIREBRAT_CAST_ENABLED=1 the server exposes content_mode=cast
# (multi-voice books via firebrat_cast.scheduler) and supervises the
# scheduler as a child process. Disabled servers 400 on cast uploads and
# hide the option (see INTEGRATION.md). Read at call time via the helpers
# below so tests can flip env vars without reimporting this module.
def cast_enabled() -> bool:
    """True only when the operator opted in via FIREBRAT_CAST_ENABLED=1."""
    return os.environ.get("FIREBRAT_CAST_ENABLED", "").strip() == "1"


def cast_root() -> str:
    """Work root for the cast scheduler (inbox/, jobs/, out/).

    Defaults to <FIREBRAT_OUTPUT_DIR>/../cast so the package output lands
    next to the normal output dir. Resolved at call time so tests that
    monkeypatch OUTPUT_DIR get an isolated root for free.
    """
    return os.environ.get("FIREBRAT_CAST_ROOT",
                           os.path.join(os.path.dirname(OUTPUT_DIR), "cast"))


def cast_available() -> bool:
    """True when cast uploads can actually run: enabled + the scheduler
    launcher (owned by another worker) is importable."""
    if not cast_enabled():
        return False
    try:
        __import__("firebrat_cast.scheduler")
    except ImportError:
        return False
    return True


# Interpreters that run the scheduler's GPU stages (own venvs on the GPU
# server so VRAM is fully released between stages); empty = in-process.
CAST_LLM_PY = os.environ.get("FIREBRAT_CAST_LLM_PY", "")
CAST_TTS_PY = os.environ.get("FIREBRAT_CAST_TTS_PY", "")
CAST_VLLM_BIN = os.environ.get("FIREBRAT_CAST_VLLM_BIN", "")

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


def iam_enabled() -> bool:
    """True only when the operator opted in via FIREBRAT_IAM=1 (accounts and
    roles; see server/iam.py and INTEGRATION2.md). Off by default so existing
    shared-server installs keep working unchanged. Read at call time so tests
    can flip the env var without reimporting this module."""
    return os.environ.get("FIREBRAT_IAM", "").strip() == "1"
