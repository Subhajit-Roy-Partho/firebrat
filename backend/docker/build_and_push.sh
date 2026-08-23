#!/usr/bin/env bash
# Manual fallback for building+pushing all three Firebrat images from any
# machine that has Docker — the primary path is the GitHub Actions workflow
# at .github/workflows/docker-publish.yml, which needs no local Docker at
# all. Use this script only if you're not using CI (e.g. testing a change
# to a Dockerfile before pushing it).
#
# Usage:
#   DOCKERHUB_USERNAME=subhajitroy DOCKERHUB_TOKEN=dckr_pat_xxx ./build_and_push.sh
#
# Never pass the token as a CLI argument (it would land in shell history /
# `ps` output) — always via this env var, and `docker login --password-stdin`.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

: "${DOCKERHUB_USERNAME:?set DOCKERHUB_USERNAME}"
: "${DOCKERHUB_TOKEN:?set DOCKERHUB_TOKEN}"

echo "$DOCKERHUB_TOKEN" | docker login --username "$DOCKERHUB_USERNAME" --password-stdin

docker build -f backend/docker/Dockerfile \
  --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cpu \
  -t subhajitroy/firebrat:cpu .
docker push subhajitroy/firebrat:cpu

docker build -f backend/docker/Dockerfile \
  --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu121 \
  -t subhajitroy/firebrat:gpu \
  -t subhajitroy/firebrat:latest .
docker push subhajitroy/firebrat:gpu
docker push subhajitroy/firebrat:latest

docker build -f backend/docker/Dockerfile.api -t subhajitroy/firebrat:api .
docker push subhajitroy/firebrat:api

docker logout
echo "Done — pushed cpu, gpu, latest (=gpu), and api tags."
