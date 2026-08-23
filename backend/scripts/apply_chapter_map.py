#!/usr/bin/env python3
"""Annotate compiled.json's sections with a chapter number, using the
chapter_map.json produced by prepare_chapter_input.py. Run this between
Stage 2 (compilation) and Stage 3 (TTS) for a merged multi-chapter input —
manifest.py already reads `sections[i]["chapter"]` if present, so this is
the only piece needed to make chapter numbers show up in manifest.json for
this kind of input; see backend/scripts/prepare_chapter_input.py.

Usage:
  python apply_chapter_map.py path/to/compiled.json path/to/chapter_map.json
"""
import json
import sys


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    compiled_path, chapter_map_path = sys.argv[1], sys.argv[2]

    with open(compiled_path, "r", encoding="utf-8") as f:
        compiled = json.load(f)
    with open(chapter_map_path, "r", encoding="utf-8") as f:
        chapter_map = json.load(f)

    ranges = [(e["start_page"], e["end_page"], e["chapter"]) for e in chapter_map]

    annotated = 0
    for sec in compiled.get("sections", []):
        source_pages = sec.get("source_pages") or []
        if not source_pages:
            continue
        # chapter of the range containing the most of this section's pages
        counts: dict[int | None, int] = {}
        for p in source_pages:
            for start, end, chapter in ranges:
                if start <= p <= end:
                    counts[chapter] = counts.get(chapter, 0) + 1
                    break
        if counts:
            sec["chapter"] = max(counts, key=lambda k: counts[k])
            annotated += 1

    with open(compiled_path, "w", encoding="utf-8") as f:
        json.dump(compiled, f, ensure_ascii=False, indent=2)

    print(f"Annotated {annotated}/{len(compiled.get('sections', []))} sections with a chapter number.")


if __name__ == "__main__":
    main()
