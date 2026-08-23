# Firebrat, all-in-one image: API server + the full PDF -> audiobook pipeline
# (extraction, LLM compilation, formula rendering, TTS) in one container.
#
# Mirrors the project's real environment split (see AGENTS.md: marker-pdf's
# and chatterbox-tts's pinned torch/transformers versions genuinely conflict)
# with three separate venvs instead of conda envs, wired together exactly
# the way convert.py already expects via FIREBRAT_*_PY env vars.
#
# Build for CPU (default, runs anywhere, no GPU/driver required):
#   docker build -f backend/docker/Dockerfile -t firebrat:cpu .
#
# Build for GPU (needs nvidia-container-toolkit + `docker run --gpus all`):
#   docker build -f backend/docker/Dockerfile \
#     --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu121 \
#     -t firebrat:gpu .
#
# NOTE: this Dockerfile was authored and reviewed but could not be built or
# run in the environment that wrote it (no Docker/rootless-build tooling
# available there — see the GitHub Actions workflow at
# .github/workflows/docker-publish.yml, which is what actually builds and
# publishes it). Sanity-check a local build before relying on it.

FROM python:3.11-slim AS base

# ffmpeg: audio export (pydub, pipeline/audio_assemble.py, tts.py)
# pdflatex + ghostscript + imagemagick: formula LaTeX -> PNG rendering (pipeline/formulas.py)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        ghostscript \
        imagemagick \
        texlive-latex-base \
        texlive-latex-extra \
        texlive-fonts-recommended \
        curl \
    && rm -rf /var/lib/apt/lists/*

ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cpu

WORKDIR /app
COPY backend/ /app/backend/

# ── firebrat-extract venv (marker-pdf + pymupdf) ─────────────────────────
# Also runs convert.py itself plus Stages 1/2/2b/manifest/package (only
# Stage 3 TTS delegates out to the tts venv) — pydantic/requests are for
# firebrat/pipeline/schema.py and notify.py respectively, not marker-pdf.
RUN python -m venv /opt/venvs/extract && \
    /opt/venvs/extract/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venvs/extract/bin/pip install --no-cache-dir --extra-index-url "$TORCH_INDEX_URL" \
        marker-pdf==1.9.3 pymupdf pydantic requests

# ── firebrat-tts venv (chatterbox-tts) ───────────────────────────────────
RUN python -m venv /opt/venvs/tts && \
    /opt/venvs/tts/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venvs/tts/bin/pip install --no-cache-dir --extra-index-url "$TORCH_INDEX_URL" \
        chatterbox-tts==0.1.7 pydub soundfile pydantic requests "setuptools<81"

# ── firebrat-serve venv (the API server itself, no torch at all) ────────
RUN python -m venv /opt/venvs/serve && \
    /opt/venvs/serve/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venvs/serve/bin/pip install --no-cache-dir \
        fastapi "uvicorn[standard]" python-multipart pydantic requests pydub pytest httpx

ENV FIREBRAT_EXTRACT_PY=/opt/venvs/extract/bin/python \
    FIREBRAT_TTS_PY=/opt/venvs/tts/bin/python \
    FIREBRAT_SERVE_PY=/opt/venvs/serve/bin/python \
    FIREBRAT_CONVERT_PY=/opt/venvs/extract/bin/python \
    FIREBRAT_OUTPUT_DIR=/data/output \
    FIREBRAT_UPLOAD_DIR=/data/uploads \
    FIREBRAT_JOBS_DB=/data/jobs.sqlite3 \
    FIREBRAT_HOST=0.0.0.0 \
    FIREBRAT_PORT=8000 \
    HF_HOME=/data/hf-cache \
    PYTHONPATH=/app/backend

RUN mkdir -p /data/output /data/uploads /data/hf-cache

EXPOSE 8000
VOLUME ["/data"]

WORKDIR /app/backend
ENTRYPOINT ["/opt/venvs/serve/bin/python", "-m", "uvicorn", "server.main:app", "--host", "0.0.0.0", "--port", "8000"]
