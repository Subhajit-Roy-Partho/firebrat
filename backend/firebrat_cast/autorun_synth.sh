#!/bin/bash
# Unattended + resumable audio stage for the community books (GPU host, run inside tmux).
#   tmux new-session -d -s cb-synth  'WORKER=A bash ~/community-books/autorun-synth.sh'
#   tmux new-session -d -s cb-synth2 'WORKER=B bash ~/community-books/autorun-synth.sh'   # optional 2nd worker
# Every worker walks the same shortest-first list and CLAIMS a book with a lock dir (out/<slug>/.synth.lock,
# holds the worker pid; stale locks of dead pids are taken over), so any number of workers balance themselves.
# A book with built.json is skipped; a killed run resumes per section (sections/*/synth.json fingerprints,
# voices/ anchors). Failures are logged and the loop continues; a second pass retries them.
# Two workers share the 16 GB GPU: each is capped at 45% VRAM (the Qwen engine is CPU/launch bound, so the
# GPU has room for both).
cd ~/community-books || exit 1
. ./cbenv.sh
W=${WORKER:-A}
PY=$HOME/Github/firebrat/.venvs/extract/bin/python   # orchestrator (packaging)
TTSPY=$HOME/community-books/venv-qwen/bin/python      # Qwen3-TTS venv
LOG=autorun-synth.log; CAT=catalog10.json
SLUGS=${SLUGS:-"alices-adventures-in-wonderland-carroll frankenstein-shelley the-picture-of-dorian-gray-wilde anne-of-green-gables-montgomery the-adventures-of-sherlock-holmes-doyle pride-and-prejudice-austen dracula-stoker jane-eyre-bronte little-women-alcott crime-and-punishment-dostoyevsky"}
MINFREE=${MINFREE:-6500}
export FIREBRAT_QWEN_VRAM_FRACTION=${FIREBRAT_QWEN_VRAM_FRACTION:-0.45} FIREBRAT_QWEN_TOKEN_BUDGET=${FIREBRAT_QWEN_TOKEN_BUDGET:-9000}
log(){ echo "$(date '+%F %T') [$W] $*" | tee -a $LOG; }

wait_gpu(){ # never start while someone else holds the GPU (we never kill other processes)
  for i in $(seq 1 360); do
    free=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)
    [ "${free:-0}" -gt $MINFREE ] && return 0
    [ $((i % 30)) -eq 1 ] && log "waiting for GPU (free ${free} MiB, need $MINFREE)"
    sleep 10
  done
  return 1
}
claim(){
  d=out/$1/.synth.lock
  if mkdir $d 2>/dev/null; then echo $$ > $d/pid; return 0; fi
  p=$(cat $d/pid 2>/dev/null)
  if [ -n "$p" ] && kill -0 $p 2>/dev/null; then return 1; fi
  rm -rf $d; mkdir $d 2>/dev/null && echo $$ > $d/pid
}
release(){ rm -rf out/$1/.synth.lock; }

run_book(){
  s=$1
  [ -f out/$s/built.json ] && { log "SKIP $s (already built)"; return 0; }
  [ -f out/$s/cast.json ] || { log "SKIP $s (no cast.json)"; return 1; }
  claim $s || { log "SKIP $s (claimed by another worker)"; return 0; }
  wait_gpu || { log "GPU never became free for $s"; release $s; return 1; }
  log "synth $s"
  $TTSPY -m firebrat_cast.stage_proc synth-wave --catalog $CAT --root $HOME/community-books --tts qwen --slugs $s >> $LOG 2>&1 \
    && $PY -c "
from firebrat_cast import queue_runner as q
e=[x for x in q.load_catalog('$CAT') if x['slug']=='$s'][0]
print(q.do_stage(q.RunnerConfig(catalog='$CAT',root='$HOME/community-books'),e,'package',lambda: q.default_package(e,'$HOME/community-books'),__import__('time').monotonic()))" >> $LOG 2>&1 \
    && { log "DONE $s ($(du -h out/$s.zip 2>/dev/null | cut -f1))"; release $s; return 0; } \
    || { log "FAILED $s"; release $s; return 1; }
}
trap 'for s in $SLUGS; do [ "$(cat out/$s/.synth.lock/pid 2>/dev/null)" = "$$" ] && release $s; done' EXIT

log "autorun-synth start (worker $W, pid $$)"
failed=""
for s in $SLUGS; do run_book $s || failed="$failed $s"; done
for s in $failed; do log "retry $s"; run_book $s; done
log "autorun-synth finished (worker $W)"
