#!/bin/bash
# Phase-3+ watcher, process-aware (replaces autopilot_ddca.sh's session-only
# checks — the TTS workers outlived their tmux sessions, so session checks
# alone would spawn duplicates). Watches WORKER PROCESSES + FINISHED
# markers, then packages, swaps, verifies, telegrams.
set -u
grep -E '^export TELEGRAM_(BOT_TOKEN|CHAT_ID)=' ~/.zshrc > /tmp/fb_tg_env 2>/dev/null || true
# shellcheck disable=SC1091
source /tmp/fb_tg_env 2>/dev/null || true

PKG=/scratch/sroy85/ddca-full/digital-design-and-computer-architecture
COMPILED=$PKG/compiled.json
LIVE=/scratch/sroy85/Github/firebrat/backend/output/digital-design-and-computer-architecture
SERVEPY=/scratch/sroy85/conda-envs/firebrat-serve/bin/python
EXTRACTPY=/scratch/sroy85/conda-envs/firebrat-extract/bin/python
TTSPY=/scratch/sroy85/conda-envs/firebrat-tts/bin/python
REPO=/scratch/sroy85/Github/firebrat/backend
COMMON='export PYTHONUNBUFFERED=1 HF_HOME=/scratch/sroy85/.cache/huggingface CUDA_VISIBLE_DEVICES=0; export PATH="/packages/apps/spack/21.2/opt/spack/x86_64_v3/gcc-12.3.0/ffmpeg-6.0-2ac3emh/bin:$PATH"'

tg() {
  curl -s -m 30 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text@-" <<<"$1" | head -c 60
  echo
}

# A shard is HEALTHY if its worker process lives OR its log says FINISHED.
# Relaunch only when NEITHER is true (dead without finishing).
shard_ok() { # $1 = index
  grep -q "FINISHED" /scratch/sroy85/tts-shard$1.log 2>/dev/null && return 0
  pgrep -f "tts_shard.py.*--index $1" >/dev/null 2>&1 && return 0
  return 1
}

launch_shard() { # $1 = index
  tmux kill-session -t fb_tts$1 2>/dev/null || true
  tmux new-session -d -s fb_tts$1 -c "$REPO" \
    "$COMMON; $TTSPY scripts/tts_shard.py --pkg-dir $PKG --compiled $COMPILED --index $1 --count 2 2>&1 | tee -a /scratch/sroy85/tts-shard$1.log"
}

echo "=== WATCHER2 START $(date -u) ==="
waited=0
while true; do
  sleep 300; waited=$((waited + 300))
  for i in 0 1; do
    if ! shard_ok "$i"; then
      echo "shard $i dead without FINISHED — relaunching"
      tg "Watcher: TTS shard $i died — relaunching (completed sections safe)."
      launch_shard "$i"
    fi
  done
  if grep -q "FINISHED" /scratch/sroy85/tts-shard0.log 2>/dev/null && \
     grep -q "FINISHED" /scratch/sroy85/tts-shard1.log 2>/dev/null; then
    break
  fi
  if [ "$waited" -ge 216000 ]; then tg "WATCHER TIMEOUT after 60h."; exit 1; fi
done
echo "BOTH SHARDS FINISHED"

# ── Package (TTS loop inside skips assembled in seconds) ─────────────
tmux new-session -d -s fb_ddca_pack -c "$REPO" \
  "$COMMON; env -u MODEL_API_KEY -u NANO_API_KEY $EXTRACTPY convert.py ../input/digital-design-and-computer-architecture.pdf --skip-extraction --skip-compilation --skip-tts --output /scratch/sroy85/ddca-full --book-id digital-design-and-computer-architecture 2>&1 | tee /scratch/sroy85/ddca-pack.log"
waited=0
while tmux has-session -t fb_ddca_pack 2>/dev/null; do
  sleep 120; waited=$((waited + 120))
  if [ "$waited" -ge 7200 ]; then tg "WATCHER TIMEOUT: packaging."; exit 1; fi
done
tg "Watcher: package built. Swapping the live book now."

# ── Swap + verify ────────────────────────────────────────────────────
STAMP=$(date -u +%Y%m%d%H%M)
mv "$LIVE" "/scratch/sroy85/Github/firebrat/backend/output/_superseded_summary_${STAMP}"
mv "$PKG" "$LIVE"
rm -f /tmp/firebrat_digital-design-and-computer-architecture.zip
sleep 3
SECTIONS=$(curl -s -m 30 http://127.0.0.1:8000/books/digital-design-and-computer-architecture/manifest | $SERVEPY -c "import json,sys; print(len(json.load(sys.stdin)['sections']))")
PDF_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 60 http://127.0.0.1:8000/books/digital-design-and-computer-architecture/assets/source.pdf)
if [ "$SECTIONS" -gt 1000 ] && [ "$PDF_CODE" = "200" ]; then
  tg "SWAPPED AND VERIFIED: live DDCA is now the unabridged edition ($SECTIONS sections, source PDF served). Old summary archived."
else
  tg "WATCHER PROBLEM: swap done but verification off (sections=$SECTIONS, pdf=$PDF_CODE). Old package archived — check before announcing."
  exit 1
fi
echo "=== WATCHER2 COMPLETE $(date -u) ==="
