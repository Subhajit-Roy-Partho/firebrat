"""Stable id helpers."""
import hashlib
import os
import re

def sanitize_book_id(pdf_path: str) -> str:
    stem = os.path.splitext(os.path.basename(pdf_path))[0]
    stem = re.sub(r"[^a-zA-Z0-9_-]+", "-", stem).strip("-").lower()
    return stem or "book"

def make_figure_id(n: int) -> str:
    return f"fig_{n:04d}"

def make_formula_id(n: int) -> str:
    return f"formula_{n:04d}"

def make_table_id(n: int) -> str:
    return f"tbl_{n:04d}"

def make_section_id(n: int) -> str:
    return f"sec_{n:04d}"

def make_segment_id(section_id: str, idx: int) -> str:
    # 1-based human ids
    return f"{section_id}_seg_{idx+1:03d}"


def normalize_section_ids(sections: list[dict], dup_start: int = 9001) -> list[dict]:
    """Ensure every section has a unique section_id, in place.

    First occurrence of an id keeps it; later duplicates are reminted as
    sec_9001, sec_9002, ... (guaranteed collision-free); sections with no
    id get order-based sec_NNNN ids. Segment ids derived from a reminted
    section id are retargeted to match.

    This MUST be the single scheme used by Stage 3 (TTS output dirs),
    tts_shard.py, and manifest.py — a manifest referencing sec_900x while
    TTS wrote only the duplicated original id leaves dangling audio_path
    refs that the app's completeness gate correctly refuses to list
    (2026-09 DDCA incident: 22 sections).
    """
    seen: set[str] = set()
    next_dup = dup_start
    for order, sec in enumerate(sections):
        raw_sid = sec.get("section_id")
        if raw_sid and raw_sid not in seen:
            sid = raw_sid
        else:
            if raw_sid:
                while make_section_id(next_dup) in seen:
                    next_dup += 1
                sid = make_section_id(next_dup)
                next_dup += 1
            else:
                sid = make_section_id(order + 1)
                while sid in seen:
                    sid = make_section_id(next_dup)
                    next_dup += 1
            if raw_sid and raw_sid != sid:
                for s in sec.get("segments", []):
                    old_seg = s.get("segment_id", "")
                    if old_seg.startswith(raw_sid):
                        s["segment_id"] = old_seg.replace(raw_sid, sid, 1)
        seen.add(sid)
        sec["section_id"] = sid
    return sections

def short_hash(text: str, length: int = 8) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:length]
