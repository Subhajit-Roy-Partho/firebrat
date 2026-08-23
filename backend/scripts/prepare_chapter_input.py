#!/usr/bin/env python3
"""Merge an Elsevier ScienceDirect-style "download chapter PDFs" export
(a zip of one PDF per chapter/front-matter/appendix/index) into a single
PDF the normal convert.py pipeline can ingest, plus a chapter_map.json
recording which merged-PDF page range each original chapter file covers.

Elsevier's chapter export filenames look like:
  1---From-Zero-to-One_2016_Digital-Design-and-Computer-Architecture.pdf
  e9---I-O-Systems_2016_Digital-Design-and-Computer-Architecture.pdf
  A---Digital-System-Implementatio_2016_Digital-Design-and-Computer-Architectu.pdf
  Preface_2016_Digital-Design-and-Computer-Architecture.pdf   <- no "---", front matter

Ordering heuristic (best-effort — filenames don't encode true book order):
  1. named front-matter pieces, in a fixed reasonable sequence
  2. numbered chapters (1, 2, 3, ...) ascending. If both "N" and "eN"
     variants exist for the same number (seen in real exports — "e9" was a
     ~5.5MB full chapter, "9" a ~124KB stub with the same title), the
     larger file is kept and the smaller one dropped as a near-duplicate.
  3. lettered appendices (A, B, C, ...) ascending, same eX-vs-X dedup
  4. Index, last

Usage:
  python prepare_chapter_input.py book.zip --output merged.pdf --chapter-map chapter_map.json
  python prepare_chapter_input.py /path/to/already/extracted/dir --output merged.pdf --chapter-map chapter_map.json
"""
import argparse
import json
import os
import re
import sys
import tempfile
import zipfile

import pymupdf

_FRONT_MATTER_ORDER = [
    "in-praise", "front-matter", "copyright", "dedication", "preface",
]


def _parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("input", help="zip file or directory of per-chapter PDFs")
    p.add_argument("--output", "-o", required=True, help="merged PDF output path")
    p.add_argument("--chapter-map", required=True, help="chapter_map.json output path")
    return p.parse_args()


def _extract_zip_if_needed(input_path: str) -> str:
    if os.path.isdir(input_path):
        return input_path
    if not zipfile.is_zipfile(input_path):
        print(f"error: {input_path} is neither a directory nor a zip file", file=sys.stderr)
        sys.exit(2)
    dest = tempfile.mkdtemp(prefix="firebrat_chapters_")
    with zipfile.ZipFile(input_path) as z:
        z.extractall(dest)
    return dest


def _identifier(basename: str) -> str:
    """The part of the filename before Elsevier's '_YYYY_BookTitle.pdf'
    suffix — e.g. '1---From-Zero-to-One', 'Index', 'In-Praise-of-...'."""
    stem = basename[:-4] if basename.lower().endswith(".pdf") else basename
    return re.split(r"_\d{4}_", stem, maxsplit=1)[0]


def _prefix(identifier: str) -> str:
    """The chapter/appendix token — '1', 'e9', 'A' — or the whole
    identifier for front-matter/index files that have no '---' part."""
    return identifier.split("---")[0].strip()


def _sort_key(basename: str):
    """Returns a tuple — lower sorts first."""
    prefix = _prefix(_identifier(basename))
    lower = prefix.lower()

    for i, tag in enumerate(_FRONT_MATTER_ORDER):
        if lower.startswith(tag):
            return (0, i, prefix)
    if lower == "index":
        return (3, 0, prefix)

    m = re.match(r"^e?(\d+)$", prefix)
    if m:
        return (1, int(m.group(1)), prefix)

    m = re.match(r"^e?([A-Za-z])$", prefix)
    if m:
        return (2, ord(m.group(1).upper()), prefix)

    # Unrecognized prefix — sort with front matter (before chapter 1) so
    # it's at least visible near the top of the merge log for review,
    # rather than silently landing somewhere unexpected mid-book.
    return (0, len(_FRONT_MATTER_ORDER), prefix)


def _dedupe_numbered(paths: list[str]) -> list[str]:
    """When both 'N' and 'eN' (or 'X'/'eX') exist for the same chapter/
    appendix number, keep only the larger file — see module docstring."""
    by_key: dict[str, list[str]] = {}
    others = []
    for path in paths:
        prefix = _prefix(_identifier(os.path.basename(path)))
        m = re.match(r"^e?(\d+|[A-Za-z])$", prefix)
        if m:
            norm_key = m.group(1).upper()
            by_key.setdefault(norm_key, []).append(path)
        else:
            others.append(path)
    deduped = list(others)
    for norm_key, variants in by_key.items():
        if len(variants) == 1:
            deduped.append(variants[0])
        else:
            deduped.append(max(variants, key=os.path.getsize))
    return deduped


def main():
    args = _parse_args()
    src_dir = _extract_zip_if_needed(args.input)

    all_pdfs = [
        os.path.join(src_dir, f) for f in os.listdir(src_dir)
        if f.lower().endswith(".pdf")
    ]
    if not all_pdfs:
        subdirs = [os.path.join(src_dir, d) for d in os.listdir(src_dir)
                   if os.path.isdir(os.path.join(src_dir, d))]
        for d in subdirs:
            all_pdfs.extend(os.path.join(d, f) for f in os.listdir(d) if f.lower().endswith(".pdf"))
    if not all_pdfs:
        print(f"error: no PDFs found under {src_dir}", file=sys.stderr)
        sys.exit(2)

    deduped = _dedupe_numbered(all_pdfs)
    ordered = sorted(deduped, key=lambda p: _sort_key(os.path.basename(p)))

    print(f"Merging {len(ordered)} files (of {len(all_pdfs)} found) in this order:")
    for p in ordered:
        print(f"  {os.path.basename(p)}")

    out_doc = pymupdf.open()
    chapter_map = []
    cursor = 0
    for path in ordered:
        basename = os.path.basename(path)
        identifier = _identifier(basename)
        prefix = _prefix(identifier)
        title = identifier[len(prefix):].lstrip("-").replace("-", " ").strip() or prefix

        chapter_num = None
        m = re.match(r"^e?(\d+)$", prefix)
        if m:
            chapter_num = int(m.group(1))

        src = pymupdf.open(path)
        page_count = src.page_count
        out_doc.insert_pdf(src)
        src.close()

        chapter_map.append({
            "chapter": chapter_num,
            "title": title,
            "source_file": basename,
            "start_page": cursor,
            "end_page": cursor + page_count - 1,
        })
        cursor += page_count

    out_doc.save(args.output)
    out_doc.close()

    with open(args.chapter_map, "w", encoding="utf-8") as f:
        json.dump(chapter_map, f, indent=2)

    print(f"\nWrote {args.output} ({cursor} pages) and {args.chapter_map}")


if __name__ == "__main__":
    main()
