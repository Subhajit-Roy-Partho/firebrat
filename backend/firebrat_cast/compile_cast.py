"""raw pages + cast.json -> compiled.json in the existing Firebrat shape.

Same section/page structure as ``firebrat.pipeline.novel.compile_novel``
(one section per non-empty page, ``Page N`` titles), but speakers, emotions
and deliveries come from the cast instead of regex tags alone. Segments carry
``voice_style: {voice_id, emotion, delivery}`` for the voice engine.
"""
from __future__ import annotations

import json
import os

from .cast import EMOTIONS, NARRATOR_ID
from .segmenter import page_text, segment_pages


def _clean_utterances(cast: dict, char_ids: set[str]) -> dict[tuple[int, int], dict]:
    """{(page, idx): utterance} with unknown speakers/emotions repaired."""
    out = {}
    for u in cast.get("utterances", []):
        try:
            key = (int(u["page"]), int(u["idx"]))
        except (KeyError, TypeError, ValueError):
            continue
        speaker = u.get("speaker", NARRATOR_ID)
        emotion = str(u.get("emotion", "neutral")).strip().lower()
        out[key] = {"speaker": speaker if speaker in char_ids else NARRATOR_ID,
                    "emotion": emotion if emotion in EMOTIONS else "neutral",
                    "delivery": str(u.get("delivery") or "")[:60]}
    return out


def _mood(cast: dict, page: int) -> dict:
    mood = cast.get("page_mood", {}).get(str(page), {})
    emotion = str(mood.get("emotion", "neutral")).strip().lower()
    return {"emotion": emotion if emotion in EMOTIONS else "neutral",
            "delivery": str(mood.get("delivery") or "")[:60]}


def compile_cast_dict(raw: dict, cast: dict) -> dict:
    """Build the compiled book from raw pages + a cast (both as dicts)."""
    pages = sorted(raw.get("pages", []), key=lambda p: p.get("page_idx", 0))
    segs = segment_pages(pages)
    characters = cast.get("characters", [])
    char_ids = {c["id"] for c in characters if c.get("id")}
    utterances = _clean_utterances(cast, char_ids | {NARRATOR_ID})
    by_page: dict[int, list] = {}
    for seg in segs:
        by_page.setdefault(seg["page"], []).append(seg)

    sections, total, attributed = [], 0, 0
    for page in pages:
        idx = page.get("page_idx", 0)
        if not page_text(page).strip() or idx not in by_page:
            continue
        segments = []
        for seg in by_page[idx]:
            if seg["kind"] == "quote":
                total += 1
                u = utterances.get((seg["page"], seg["idx"]))
                speaker = u["speaker"] if u else NARRATOR_ID
                emotion = u["emotion"] if u else "neutral"
                delivery = u["delivery"] if u else ""
                if speaker != NARRATOR_ID:
                    attributed += 1
            else:  # narration: page mood sets delivery, narrator reads
                speaker, mood = NARRATOR_ID, _mood(cast, idx)
                emotion, delivery = mood["emotion"], mood["delivery"]
            segments.append({"type": "prose", "text": seg["text"], "ref": None,
                             "speaker_id": speaker,
                             "voice_style": {"voice_id": speaker, "emotion": emotion,
                                             "delivery": delivery}})
        sections.append({"section_id": f"sec_{len(sections) + 1:04d}",
                         "title": page.get("title") or f"Page {idx + 1}",
                         "source_pages": [idx], "segments": segments})
    if not sections:
        raise ValueError("Cast has no usable text; check the raw pages and cast")
    roster = [{"character_id": c["id"], "name": c.get("name", ""),
               "aliases": list(c.get("aliases", [])),
               "voice_gender": c.get("gender", "unknown"),
               "description": c.get("description", ""),
               "voice_style": {"voice_id": c["id"],
                               "voice_gender": c.get("gender", "unknown")}}
              for c in characters if c.get("id")]
    return {"book_id": cast.get("book_id", raw.get("book_id")),
            "content_mode": "novel", "character_roster": roster,
            "sections": sections, "formulas": [],
            "dialogue_stats": {"total": total, "attributed": attributed}}


def compile_cast_file(raw_pages_path: str, cast_path: str, out_path: str) -> dict:
    """File-level wrapper; writes compiled.json atomically and returns it."""
    with open(raw_pages_path, encoding="utf-8") as f:
        raw = json.load(f)
    with open(cast_path, encoding="utf-8") as f:
        cast = json.load(f)
    compiled = compile_cast_dict(raw, cast)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(compiled, f, ensure_ascii=False, indent=2)
    os.replace(tmp, out_path)
    return compiled
