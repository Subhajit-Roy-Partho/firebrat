#!/usr/bin/env bash
# Linux only. Persistent, user-owned data; no privileged container.
set -euo pipefail
if [[ $(uname -s) != Linux ]]; then echo 'Use the native Mac installer for Apple GPU support.' >&2; exit 1; fi
command -v docker >/dev/null || { echo 'Install Docker Engine first: https://docs.docker.com/engine/install/' >&2; exit 1; }
variant=cpu
args=()
case "${1:-cpu}" in
  cpu) ;;
  gpu) variant=gpu; args+=(--gpus all) ;;
  *) echo 'Usage: firebrat-docker.sh [cpu|gpu]' >&2; exit 1 ;;
esac
image="${FIREBRAT_IMAGE:-subhajitroy/firebrat:desktop-$variant}"
data="${FIREBRAT_DATA:-$HOME/.local/share/firebrat-server-docker}"
mkdir -p "$data"
chmod 700 "$data"
name=firebrat-desktop
if docker container inspect "$name" >/dev/null 2>&1; then
  echo "Container $name already exists. Resume with docker start $name; remove it before changing image/settings." >&2
  docker start "$name" >/dev/null
else
  docker pull "$image"
  docker run -d --name "$name" --network host --user "$(id -u):$(id -g)" \
    --security-opt no-new-privileges --cap-drop ALL "${args[@]}" -v "$data:/data" "$image" >/dev/null
fi
for attempt in {1..30}; do
  if url=$(docker exec "$name" /opt/venvs/serve/bin/python -c 'import json;print(json.load(open("/data/launcher-address.json"))["url"])' 2>/dev/null); then
    echo "Open this private setup address on this PC: $url"
    if command -v xdg-open >/dev/null; then xdg-open "$url" >/dev/null 2>&1 || true; fi
    exit 0
  fi
  sleep 1
done
echo "Startup failed. Inspect docker logs $name" >&2
exit 1
