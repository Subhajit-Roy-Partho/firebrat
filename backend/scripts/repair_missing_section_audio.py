#!/usr/bin/env python3
"""Repair book packages whose manifest references section audio that was never built.

Root cause (2026-09 DDCA incident): compiled.json contained duplicate
section_ids; Stage 3 TTS (convert.py prologue used setdefault-only id
normalization) wrote both copies into the same sections/<sid>/ dir, while
manifest.py minted sec_9001+ replacements for the duplicates — leaving
manifest audio_path refs with no files behind. The app's completeness gate
then refuses to list the book at all ("downloaded but never appears").

What this does for --pkg-dir <pkg>:
  1. Applies the shared normalize_section_ids() to compiled.json (the same
     scheme manifest.py/convert.py/tts_shard.py now all use) and persists it.
  2. For every section whose audio file is missing, assembles a silence
     placeholder via assemble_section() with the section's REAL segments —
     real text + estimated timing, silence audio (same recipe as the ARM
     book's reminted sections) — and flags needs_review=true so a later run
     with TTS available can refill just these sections (delete their
     sections/<sid>/ dirs and re-run Stage 3; resumability skips the rest).
  3. Rebuilds manifest.json, repackages the .tar.gz, updates status.json.

No GPU/LLM needed. Idempotent: re-running repairs nothing new.
"""
import argparse
import json
import logging
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("repair_missing_audio")

AUDIO_CANDIDATES = ("audio.m4a", "audio.mp3", "audio.wav")


def section_has_audio(pkg_dir: str, sid: str) -> bool:
    sec_dir = os.path.join(pkg_dir, "sections", sid)
    return any(
        os.path.isfile(os.path.join(sec_dir, name)) for name in AUDIO_CANDIDATES
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--pkg-dir", required=True, help="package dir (must contain manifest.json + compiled.json)")
    ap.add_argument("--dry-run", action="store_true", help="report only, change nothing")
    args = ap.parse_args()

    pkg_dir = args.pkg_dir
    compiled_path = os.path.join(pkg_dir, "compiled.json")
    if not os.path.isfile(os.path.join(pkg_dir, "manifest.json")):
        print(f"{pkg_dir} has no manifest.json — not a finished book package", file=sys.stderr)
        return 2
    if not os.path.isfile(compiled_path):
        print(f"{pkg_dir} has no compiled.json — nothing to repair from", file=sys.stderr)
        return 2

    with open(compiled_path, "r", encoding="utf-8") as f:
        compiled = json.load(f)
    sections = compiled.get("sections", [])

    from firebrat.utils.ids import normalize_section_ids, make_segment_id
    normalize_section_ids(sections)
    for sec in sections:
        for si, seg in enumerate(sec.get("segments", [])):
            seg.setdefault("segment_id", make_segment_id(sec["section_id"], si))
            seg.setdefault("type", "prose")
            seg.setdefault("text", "")

    missing = [s for s in sections if not section_has_audio(pkg_dir, s["section_id"])]
    print(f"{len(sections)} sections, {len(missing)} missing audio: "
          f"{[s['section_id'] for s in missing][:10]}")
    if args.dry_run or not missing:
        return 0

    from firebrat.pipeline.audio_assemble import assemble_section
    repaired = []
    for sec in missing:
        sec["needs_review"] = True  # synthetic silence — refill with real TTS later
        res = assemble_section(sec, sec.get("segments", []), {}, pkg_dir)
        repaired.append((sec["section_id"], res["duration_ms"]))
    print(f"assembled silence placeholders for {len(repaired)} sections")

    with open(compiled_path, "w", encoding="utf-8") as f:
        json.dump(compiled, f, ensure_ascii=False, indent=2)

    old_manifest = json.load(open(os.path.join(pkg_dir, "manifest.json"), encoding="utf-8"))
    from firebrat.pipeline.manifest import build_manifest
    build_manifest(
        pkg_dir,
        old_manifest.get("book_id", os.path.basename(os.path.normpath(pkg_dir))),
        old_manifest.get("title", ""),
        old_manifest.get("source_pdf", ""),
        voice_ref=(old_manifest.get("narrator_voice") or {}).get("reference_clip"),
        source_pdf_path=None,  # already embedded as source.pdf; don't re-copy
    )

    from firebrat.pipeline.package import package_book
    archive_path = package_book(pkg_dir)
    archive_mb = os.path.getsize(archive_path) / (1024 * 1024)

    manifest = json.load(open(os.path.join(pkg_dir, "manifest.json"), encoding="utf-8"))
    secs = len(manifest.get("sections", []))
    dur = manifest.get("total_duration_ms", 0)
    nr = sum(1 for s in manifest.get("sections", []) if s.get("needs_review"))
    summary = (f"{secs} sections, {len(manifest.get('figures', []))} figures, "
               f"{len(manifest.get('formulas', []))} formulas, {dur/60000:.1f} min audio")
    from firebrat.pipeline.status import write_status
    write_status(pkg_dir, status="done", stage="done", error=None, progress=1.0,
                 needs_review_count=nr,
                 detail=f"{summary} — packaged {archive_mb:.0f} MB")
    print(f"repaired: {summary}, needs_review={nr}, tar={archive_mb:.0f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
