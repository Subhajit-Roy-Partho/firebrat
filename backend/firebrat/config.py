"""Central configuration — import-safe, no heavy deps at import time."""
import os

# ── LLM API ──────────────────────────────────────────────────────
NANO_API_URL = os.environ.get("NANO_API_URL", "https://nano-gpt.com/api/v1")
# Accept either env name; MODEL_API_KEY is set by default in this cluster
NANO_API_KEY = os.environ.get("NANO_API_KEY") or os.environ.get("MODEL_API_KEY", "")

# meta/muse-spark-1.2-contributor (originally requested) is community-hosted on
# nano-gpt and returns "empty_response" on every request as of 2026-08-21 — verified
# via direct curl, not a transient blip. Using deepseek/deepseek-v4-flash for the
# cheap tier instead, keeping deepseek/deepseek-v4-pro:thinking for the strong tier
# as requested. See AGENTS.md.
SPARK_MODEL = "deepseek/deepseek-v4-flash"
DEEPSEEK_MODEL = "deepseek/deepseek-v4-pro:thinking"

# ── Audio / TTS ──────────────────────────────────────────────────
SAMPLE_RATE = 24000
PAUSE_MS = 220  # silence gap between segments
TTS_EXAGGERATION = 0.4
TTS_CFG_WEIGHT = 0.5

# ── Pipeline ─────────────────────────────────────────────────────
CHUNK_PAGES = 10           # pages per LLM chunk
PIPELINE_VERSION = "0.1.0"
SCHEMA_VERSION = "1.0"
MIG_UUID = "MIG-b36117af-4e57-514f-a05d-13fb7d1c4280"

# ── Paths ────────────────────────────────────────────────────────
# OUTPUT_DIR is resolved relative to the backend/ directory unless absolute
_DEFAULT_OUTPUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "output")
OUTPUT_DIR = os.environ.get("FIREBRAT_OUTPUT_DIR", _DEFAULT_OUTPUT)

# HF cache redirect (avoid small home quota on shared clusters)
DEFAULT_HF_HOME = "/scratch/sroy85/.cache/huggingface"
