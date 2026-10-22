#!/usr/bin/env bash
set -euo pipefail
# Called only after both desktop images pass startup checks and are pushed.
tag="${FIREBRAT_RELEASE_TAG:-$GITHUB_REF_NAME}"
[[ "$tag" =~ ^server-v[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo "Invalid server release tag" >&2; exit 1; }
body="$RUNNER_TEMP/server-release-notes.md"
if gh release view "$tag" --json body --jq .body > "$body" 2>/dev/null; then
  if ! rg -q '^### Docker Hub images' "$body"; then
    cat >> "$body" <<NOTES

### Docker Hub images

The guided Linux conversion server is also published to [subhajitroy/firebrat on Docker Hub](https://hub.docker.com/r/subhajitroy/firebrat).

- CPU: \`docker pull subhajitroy/firebrat:${tag}-desktop-cpu\`
- NVIDIA GPU: \`docker pull subhajitroy/firebrat:${tag}-desktop-gpu\` (NVIDIA driver and Container Toolkit required)
- Moving tags: \`desktop-cpu\` and \`desktop-gpu\`.

Download **Firebrat-Server-Docker-Linux.sh** below and run it with \`cpu\` or \`gpu\` to open the setup screen. Model weights download on first use; books and settings persist on the host. LLM APIs are optional, and voice generation always stays local.

[Setup, hardware/model choices, updates and private Tailscale access](https://github.com/${GITHUB_REPOSITORY}/blob/${tag}/installer/server/README.md).

Both images passed a real backend startup check. NVIDIA execution/performance still requires a hardware test. Native macOS downloads support Apple silicon and are unsigned/not notarized; native Intel Mac builds are unavailable with the required PyTorch wheels.
NOTES
  fi
  gh release edit "$tag" --notes-file "$body"
else
  printf 'Firebrat Server backend installers. See the attached setup guide.\n' > "$body"
  gh release create "$tag" --title "Firebrat Server ${tag#server-v}" --notes-file "$body"
  # Re-enter to append the same Docker links on a newly created release.
  exec bash "$0"
fi
cp installer/server/firebrat-docker.sh "$RUNNER_TEMP/Firebrat-Server-Docker-Linux.sh"
cp installer/server/README.md "$RUNNER_TEMP/Firebrat-Server-Getting-Started.md"
gh release upload "$tag" "$RUNNER_TEMP/Firebrat-Server-Docker-Linux.sh" "$RUNNER_TEMP/Firebrat-Server-Getting-Started.md" --clobber
