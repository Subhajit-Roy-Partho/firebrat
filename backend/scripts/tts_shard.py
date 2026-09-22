"""Strided TTS shard worker: synthesizes every Nth section (starting at
`--index`) of an already-compiled package, in its own process with its own
Chatterbox model on the shared GPU.

Why processes, not threads: Chatterbox holds ~GBs of CUDA + RAM state per
instance and has leaked memory over multi-hour runs before (OOM-killed at
~2GB RSS here); a dead shard loses only its in-flight section because
everything completed is already on disk (per-section segments.json +
audio.m4a, per-segment wavs), and the next launch skips it. Run 2 shards
for ~2x throughput on a 16GB card; run 1 if memory pressure bites.

Usage (after Stage 2 compiled.json exists; llm_server must be STOPPED so
both shards fit in VRAM alongside nothing else):
  shard 0: <tts-python> backend/scripts/tts_shard.py --pkg-dir <pkg> --compiled <compiled.json> --index 0 --count 2 [--voice-ref ...]
  shard 1: ... --index 1 --count 2
Wait for both, then run the main convert.py (same flags incl.
--skip-extraction) to do manifest+package — its own TTS loop will skip
every already-assembled section in seconds and finish the book.

Each shard logs to --log (default <pkg>/tts_shard_<index>.log).
"""
import argparse
import json
import logging
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pkg-dir", required=True)
    ap.add_argument("--compiled", required=True)
    ap.add_argument("--index", type=int, required=True)
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--voice-ref", default=None)
    ap.add_argument("--log", default=None)
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )
    log = logging.getLogger(f"tts_shard_{args.index}")

    with open(args.compiled, "r", encoding="utf-8") as f:
        compiled = json.load(f)
    sections = compiled.get("sections", [])
    mine = [s for i, s in enumerate(sections) if i % args.count == args.index]
    log.info("shard %d/%d: %d of %d sections", args.index, args.count, len(mine), len(sections))

    from firebrat.config import DEFAULT_VOICE_REF as _DEFAULT_VOICE_REF
    from firebrat.pipeline.tts import FirebratTTS
    from firebrat.pipeline.audio_assemble import assemble_section

    voice = args.voice_ref or (_DEFAULT_VOICE_REF if os.path.isfile(_DEFAULT_VOICE_REF) else None)
    if voice:
        log.info("voice ref: %s", voice)
    tts = FirebratTTS(voice_ref=voice)

    seg_wavs_dir = os.path.join(args.pkg_dir, "_segment_wavs")
    os.makedirs(seg_wavs_dir, exist_ok=True)

    done = skipped = 0
    for sec in mine:
        sid = sec["section_id"]
        segs = sec.get("segments", [])
        seg_json_path = os.path.join(args.pkg_dir, "sections", sid, "segments.json")
        if os.path.isfile(seg_json_path):
            try:
                with open(seg_json_path, "r", encoding="utf-8") as f:
                    existing = json.load(f)
                if len(existing.get("segments", [])) == len(segs):
                    skipped += 1
                    continue
            except (OSError, ValueError):
                pass
        seg_wavs: dict[str, str] = {}
        for seg in segs:
            wav_path = os.path.join(seg_wavs_dir, f"{seg['segment_id']}.wav")
            if os.path.isfile(wav_path) and os.path.getsize(wav_path) > 0:
                seg_wavs[seg["segment_id"]] = wav_path
                continue
            if tts.synthesize(seg.get("text", ""), wav_path):
                seg_wavs[seg["segment_id"]] = wav_path
            elif os.path.isfile(wav_path):
                seg_wavs[seg["segment_id"]] = wav_path
        assemble_section(sec, segs, seg_wavs, args.pkg_dir)
        done += 1
        if done % 10 == 0:
            log.info("shard %d: %d done, %d skipped", args.index, done, skipped)
    log.info("shard %d FINISHED: %d synthesized, %d skipped", args.index, done, skipped)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
