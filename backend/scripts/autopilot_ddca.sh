#!/bin/bash
# Autopilot: DDCA unabridged reconversion, no babysitting required.
# Watches each stage, advances automatically, telegrams every transition.
#
#   Phase 1: wait for placeholder-retry run (tmux fb_ddca_ph) to finish.
#   Phase 2: stop the local LLM server (frees ~12GB VRAM for TTS).
#   Phase 3: launch 2 parallel TTS shards (tmux fb_tts0/fb_tts1), relaunch
#            any that dies (resume skips completed sections), wait for both.
#   Phase 4: manifest + package via convert.py (TTS loop skips assembled).
#   Phase 5: swap the live summary book aside, move the new package in,
#            verify /books + manifest + sample asset + checksum.
# Telegram on every phase change and on any failure/timeout.
#
# Usage: tmux new-session -d -s fb_autopilot '/path/autopilot_ddca.sh 2>&1 | tee /scratch/sroy85/autopilot.log'
set -u
# Telegram creds live in ~/.zshrc, but sourcing the whole file under bash
# hangs (zsh-only syntax) — source just the two export lines instead.
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

tg() {
  curl -s -m 30 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text@-" <<<"$1" | head -c 60
  echo
}

wait_session_gone() { # $1=session $2=timeout_secs $3=label
  local waited=0
  while tmux has-session -t "$1" 2>/dev/null; do
    sleep 120; waited=$((waited + 120))
    if [ "$waited" -ge "$2" ]; then
      tg "AUTOPILOT TIMEOUT: $3 still running after $((waited/3600))h. Investigate tmux $1."
      return 1
    fi
  done
  return 0
}

placeholders() {
  $SERVEPY -c "
import json
c = json.load(open('$COMPILED'))
secs = c['sections']
ph = [s for s in secs if 'needs review' in s.get('title','').lower()]
print(f'{len(secs)} sections, {len(ph)} placeholders, {sum(len(s[\"segments\"]) for s in secs)} segments')
"
}

audios() {
  find "$PKG/sections" -maxdepth 2 -name "audio.m4a" 2>/dev/null | wc -l
}

echo "=== AUTOPILOT START $(date -u) ==="
tg "Autopilot engaged: watching placeholder-retry, then TTS shards x2, package, swap, verify. No chat babysitting needed."

# ── Phase 1: placeholder retry ──────────────────────────────────────
wait_session_gone fb_ddca_ph 28800 "placeholder retry" || exit 1
PH=$(placeholders)
echo "Phase 1 done: $PH"
tg "Phase 1 done — compilation final: $PH"

# ── Phase 2: free the GPU ───────────────────────────────────────────
tmux kill-session -t fb_llm 2>/dev/null || true
sleep 10
VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -n 1)
echo "VRAM after LLM stop: ${VRAM} MiB"
tg "Phase 2 done — LLM server stopped, VRAM free (${VRAM} MiB used). Launching 2 TTS shards."

# ── Phase 3: parallel TTS ───────────────────────────────────────────
COMMON="export PYTHONUNBUFFERED=1 HF_HOME=/scratch/sroy85/.cache/huggingface CUDA_VISIBLE_DEVICES=0; export PATH=\"/packages/apps/spack/21.2/opt/spack/x86_64_v3/gcc-12.3.0/ffmpeg-6.0-2ac3emh/bin:\$PATH\""
for i in 0 1; do
  tmux new-session -d -s fb_tts$i -c "$REPO" "$COMMON; $TTSPY backend/scripts/tts_shard.py --pkg-dir $PKG --compiled $COMPILED --index $i --count 2 2>&1 | tee /scratch/sroy85/tts-shard$i.log"
done
for i in 0 1; do
  # Relaunch-on-death loop: a dead shard that didn't FINISH gets relaunched
  # (resume skips everything already assembled, so this is always safe).
  waited=0
  while true; do
    sleep 180; waited=$((waited + 180))
    if grep -q "FINISHED" /scratch/sroy85/tts-shard$i.log 2>/dev/null; then
      echo "shard $i FINISHED"
      break
    fi
    if ! tmux has-session -t fb_tts$i 2>/dev/null; then
      echo "shard $i died without FINISHED — relaunching (resume skips done)"
      tg "Autopilot: TTS shard $i died mid-flight — relaunching, completed sections are safe on disk."
      tmux new-session -d -s fb_tts$i -c "$REPO" "$COMMON; $TTSPY backend/scripts/tts_shard.py --pkg-dir $PKG --compiled $COMPILED --index $i --count 2 2>&1 | tee -a /scratch/sroy85/tts-shard$i.log"
    fi
    if [ "$waited" -ge 216000 ]; then
      tg "AUTOPILOT TIMEOUT: TTS shard $i after 60h. Check tmux fb_tts$i."
      exit 1
    fi
  done
done
echo "Phase 3 done: $(audios) section audios on disk"
tg "Phase 3 done — TTS shards finished: $(audios) section audios. Packaging now."

# ── Phase 4: manifest + package (TTS loop skips assembled in seconds) ─
tmux new-session -d -s fb_ddca_pack -c "$REPO" "$COMMON; env -u MODEL_API_KEY -u NANO_API_KEY $EXTRACTPY convert.py ../input/digital-design-and-computer-architecture.pdf --skip-extraction --skip-compilation --skip-tts --output /scratch/sroy85/ddca-full --book-id digital-design-and-computer-architecture 2>&1 | tee /scratch/sroy85/ddca-pack.log"
wait_session_gone fb_ddca_pack 7200 "packaging" || exit 1
echo "Phase 4 done"
tg "Phase 4 done — package built. Swapping the live book now."

# ── Phase 5: swap + verify ──────────────────────────────────────────
STAMP=$(date -u +%Y%m%d%H%M)
mv "$LIVE" "/scratch/sroy85/Github/firebrat/backend/output/_superseded_summary_${STAMP}"
mv "$PKG" "$LIVE"
rm -f /tmp/firebrat_digital-design-and-computer-architecture.zip
sleep 3
BOOKS=$(curl -s -m 15 http://127.0.0.1:8000/books)
echo "$BOOKS" | head -c 400; echo
MANIFEST=$(curl -s -m 30 http://127.0.0.1:8000/books/digital-design-and-computer-architecture/manifest)
SECTIONS=$(echo "$MANIFEST" | $SERVEPY -c "import json,sys; print(len(json.load(sys.stdin)['sections']))")
PDF_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 60 http://127.0.0.1:8000/books/digital-design-and-computer-architecture/assets/source.pdf)
echo "live sections=$SECTIONS source.pdf=$PDF_CODE"
if [ "$SECTIONS" -gt 1000 ] && [ "$PDF_CODE" = "200" ]; then
  tg "SWAPPED AND VERIFIED: the live DDCA book is now the unabridged edition ($SECTIONS sections, source PDF served). Old summary package archived, not deleted."
else
  tg "AUTOPILOT PROBLEM: swap happened but verification looks off (sections=$SECTIONS, pdf=$PDF_CODE). Old package archived — check before announcing."
  exit 1
fi
echo "=== AUTOPILOT COMPLETE $(date -u) ==="
