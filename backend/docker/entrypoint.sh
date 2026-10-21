#!/bin/bash
# Firebrat container entrypoint: picks the Stage-2 LLM provider, then runs
# whatever CMD was given (default: the API server).
#
#   LLM_PROVIDER=nanogpt  (default) — chunks go to an OpenAI-compatible
#       endpoint. Needs MODEL_API_KEY (or NANO_API_KEY) and optionally
#       NANO_API_URL (default https://nano-gpt.com/api/v1).
#   LLM_PROVIDER=local — a Qwen3-class HF model runs on the container's GPU
#       via backend/scripts/llm_server.py (OpenAI-compatible shim on
#       127.0.0.1:$LOCAL_LLM_PORT), and the pipeline is pointed at it with
#       zero code changes. Needs LOCAL_MODEL_DIR mounted with the model
#       weights (a HF snapshot dir, e.g. Qwen/Qwen3-4B-Instruct-2507) plus
#       enough VRAM (4B fp16 ≈ 8GB weights + ~2.5GB KV cache at 16k ctx).
#
# Examples:
#   # nano-gpt (or any OpenAI-compatible endpoint):
#   docker run -e MODEL_API_KEY=sk-... -v books:/data -p 8000:8000 \
#       subhajitroy/firebrat:latest
#   # local GPU model (needs --gpus all + a models volume):
#   docker run --gpus all -e LLM_PROVIDER=local \
#       -e LOCAL_MODEL_DIR=/models/qwen3-4b -v /host/models:/models \
#       -v books:/data -p 8000:8000 subhajitroy/firebrat:latest
set -euo pipefail

PROVIDER="${LLM_PROVIDER:-nanogpt}"

if [ "$PROVIDER" = "local" ]; then
    : "${LOCAL_MODEL_DIR:?LLM_PROVIDER=local requires LOCAL_MODEL_DIR (mount your HF model snapshot there)}"
    LOCAL_LLM_PORT="${LOCAL_LLM_PORT:-8080}"
    LOCAL_MAX_SEQ_LEN="${LOCAL_MAX_SEQ_LEN:-16384}"
    # Preset convenience: LOCAL_MODEL_PRESET (qwen3-1.7b|qwen3-4b|qwen3-8b,
    # see backend/server/models.py) auto-downloads the weights when the
    # dir is empty, so small-VRAM laptops don't hand-assemble snapshots.
    # Skip with LOCAL_MODEL_PRESET="" when you mount weights yourself.
    if [ -n "${LOCAL_MODEL_PRESET:-}" ] && [ -z "$(ls -A "$LOCAL_MODEL_DIR" 2>/dev/null)" ]; then
        echo "[entrypoint] downloading preset $LOCAL_MODEL_PRESET into $LOCAL_MODEL_DIR"
        /opt/venvs/extract/bin/python - "$LOCAL_MODEL_DIR" "$LOCAL_MODEL_PRESET" <<'EOF'
import json, os, sys
from huggingface_hub import snapshot_download
sys.path.insert(0, "/app/backend")
from server.models import preset_or_default
target, entry = preset_or_default(os.environ.get("LOCAL_MODEL_PRESET", ""))
d = sys.argv[1]
snapshot_download(entry["repo"], local_dir=d,
                  allow_patterns=["*.json", "*.safetensors", "tokenizer*", "*.txt"])
print("preset ready:", target, entry["repo"])
EOF
    fi
    echo "[entrypoint] starting local LLM: $LOCAL_MODEL_DIR (port $LOCAL_LLM_PORT, ctx $LOCAL_MAX_SEQ_LEN)"
    /opt/venvs/extract/bin/python /app/backend/scripts/llm_server.py \
        --model-dir "$LOCAL_MODEL_DIR" \
        --port "$LOCAL_LLM_PORT" \
        --max-seq-len "$LOCAL_MAX_SEQ_LEN" &
    LLM_PID=$!
    # Wait until the shim answers before the pipeline/server starts asking.
    for i in $(seq 1 120); do
        if curl -sf "http://127.0.0.1:${LOCAL_LLM_PORT}/v1/models" >/dev/null 2>&1; then
            echo "[entrypoint] local LLM ready"
            break
        fi
        if ! kill -0 "$LLM_PID" 2>/dev/null; then
            echo "[entrypoint] local LLM server died during startup — see log above" >&2
            exit 1
        fi
        sleep 10
    done
    export NANO_API_URL="http://127.0.0.1:${LOCAL_LLM_PORT}/v1"
    # The shim accepts any bearer token; keep one set so shared client code
    # that requires a non-empty key keeps working.
    export MODEL_API_KEY="${MODEL_API_KEY:-local}"
    echo "[entrypoint] pipeline will use NANO_API_URL=$NANO_API_URL"
fi

exec "$@"
