"""Central configuration — import-safe, no heavy deps at import time."""
import os


def _load_dotenv() -> None:
    """Loads backend/.env (gitignored, local credentials only) into
    os.environ, without overriding anything already set there — shell
    exports (e.g. ~/.zshrc, a tmux launch command) still win. No
    python-dotenv dependency needed across all three conda envs for
    something this small.
    """
    env_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
    if not os.path.isfile(env_path):
        return
    with open(env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            os.environ.setdefault(key, value)


_load_dotenv()

# ── LLM API ──────────────────────────────────────────────────────
NANO_API_URL = os.environ.get("NANO_API_URL", "https://nano-gpt.com/api/v1")
# Accept either env name; MODEL_API_KEY is set by default in this cluster
NANO_API_KEY = os.environ.get("NANO_API_KEY") or os.environ.get("MODEL_API_KEY", "")

# meta/muse-spark-1.2-contributor (originally requested) is community-hosted on
# nano-gpt and returns "empty_response" on every request as of 2026-08-21 — verified
# via direct curl, not a transient blip. Using deepseek/deepseek-v4-flash for the
# cheap tier instead, keeping deepseek/deepseek-v4-pro:thinking for the strong tier
# as requested. See AGENTS.md.
# NOTE 2026-08-21 full-book run: flash timed out on ~40% of chunks (240s x5 retries)
# while pro:thinking succeeded on same pages — flash endpoint appears overloaded.
# Both models are overridable via env so a run can force pro for all chunks:
#   FIREBRAT_SPARK_MODEL=deepseek/deepseek-v4-pro:thinking python convert.py ...
SPARK_MODEL = os.environ.get("FIREBRAT_SPARK_MODEL", "deepseek/deepseek-v4-flash")
DEEPSEEK_MODEL = os.environ.get("FIREBRAT_DEEPSEEK_MODEL", "deepseek/deepseek-v4-pro:thinking")

# ── Audio / TTS ──────────────────────────────────────────────────
SAMPLE_RATE = 24000
PAUSE_MS = 260  # slightly longer pause for calm narration
TTS_EXAGGERATION = 0.28  # calm female: lower than default 0.4
TTS_CFG_WEIGHT = 0.45
# Optional voice reference clip for calm female (place wav at backend/voice/narrator_ref.wav)
# If file exists it will be used automatically; otherwise default voice is used.
DEFAULT_VOICE_REF = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "voice", "narrator_ref.wav")

# ── Pipeline ─────────────────────────────────────────────────────
CHUNK_PAGES = 10           # pages per LLM chunk
PIPELINE_VERSION = "0.1.0"
SCHEMA_VERSION = "1.0"
MIG_UUID = "MIG-b36117af-4e57-514f-a05d-13fb7d1c4280"

# This session's SLURM allocation caps total RAM at 6GB (see AGENTS.md).
# marker-pdf batch-processes every page of whatever file it's given at once,
# so Stage 1 runs it in small page-range batches, each as its own subprocess,
# to keep peak memory bounded regardless of book length.
EXTRACT_BATCH_PAGES = 15

# ── Paths ────────────────────────────────────────────────────────
# OUTPUT_DIR is resolved relative to the backend/ directory unless absolute
_DEFAULT_OUTPUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "output")
OUTPUT_DIR = os.environ.get("FIREBRAT_OUTPUT_DIR", _DEFAULT_OUTPUT)

# HF cache redirect (avoid small home quota on shared clusters)
DEFAULT_HF_HOME = "/scratch/sroy85/.cache/huggingface"
