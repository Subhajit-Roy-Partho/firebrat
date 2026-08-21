#!/usr/bin/env bash
set -euo pipefail
# Run Firebrat conversion with the right env + MIG targeting + ffmpeg.
# Usage: ./run_conversion.sh ../arm-fundamentals-soc.pdf [--pages 10] [other convert.py flags]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-MIG-b36117af-4e57-514f-a05d-13fb7d1c4280}"
export HF_HOME="${HF_HOME:-/scratch/sroy85/.cache/huggingface}"
export MODEL_API_KEY="${MODEL_API_KEY:-}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
# ffmpeg via module if available
if command -v module &>/dev/null; then
  module load ffmpeg-6.0-2a 2>/dev/null || true
fi
# Also ensure ffmpeg binary is on PATH when available via known prefix
for cand in /packages/apps/spack/21.2/opt/spack/x86_64_v3/gcc-12.3.0/ffmpeg-6.0-2ac3emh/bin; do
  if [[ -x "$cand/ffmpeg" ]]; then export PATH="$cand:$PATH"; fi
done

# Use the firebrat-extract env's python (it has marker+pymupdf+fastapi); falls back to system python
PY="${FIREBRAT_PYTHON:-/scratch/sroy85/conda-envs/firebrat-extract/bin/python}"
if [[ ! -x "$PY" ]]; then PY="python3"; fi

exec "$PY" "$BACKEND_DIR/convert.py" "$@"
