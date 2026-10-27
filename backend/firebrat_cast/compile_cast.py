"""raw pages + cast.json -> compiled.json in the existing Firebrat shape.

Same section/page structure as ``firebrat.pipeline.novel.compile_novel``
(one section per non-empty page, ``Page N`` titles), but speakers, emotions
and deliveries come from the cast instead of regex tags alone. Segments carry
``voice_style: {voice_id, emotion, delivery}`` for the voice engine.
"""
from __future__ import annotations

import json
import os
import re
import unicodedata
from collections import Counter

from .cast import EMOTIONS, NARRATOR_ID
from .segmenter import page_text, segment_pages


_STOP = {"the", "a", "an", "of", "and", "mr", "mrs", "miss", "ms", "dr", "lady", "lord", "sir",
         "colonel", "captain", "major", "professor", "reverend", "uncle", "aunt", "madame", "mme", "m"}


def _name_tokens(name: str) -> frozenset:
    """Accent/honorific/article-free token set ('Josephine \'Jo\' March' -> {josephine, jo, march})."""
    n = unicodedata.normalize("NFKD", name or "")
    n = "".join(c for c in n if not unicodedata.combining(c)).lower().replace("\u2019", "'")
    n = re.sub(r"'s\b", "", re.sub(r"\(([^)]*)\)", r" \1 ", n))
    return frozenset(t for t in re.findall(r"[a-z]+", n) if len(t) > 1 and t not in _STOP)


def _gender_ok(a: str, b: str) -> bool:
    return a == b or "unknown" in (a, b) or not a or not b


def consolidate_roster(cast: dict) -> tuple[dict, dict[str, str]]:
    """Merge roster entries that are the same person under different names.

    The casting LLM often lists one character several times ('Jo March', 'Josephine \'Jo\' March',
    'The Hatter' / 'Hatter'); each entry would get its own voice, so a character would change voice
    mid-book. Entries merge when their name tokens are equal, or one is a strict subset of exactly
    one other used entry (gender must not conflict, so 'Mr. Bennet' never folds into 'Jane Bennet').
    'Narrator (...)' entries are read by the narrator. Returns (new cast, {old_id: new_id}).
    """
    chars = [c for c in cast.get("characters", []) if c.get("id")]
    counts = Counter(u.get("speaker") for u in cast.get("utterances", []))
    mapping: dict[str, str] = {}
    used = []
    for c in chars:
        if str(c.get("name", "")).strip().lower().startswith("narrator"):
            mapping[c["id"]] = NARRATOR_ID
        elif counts.get(c["id"], 0) > 0:
            used.append(c)
    toks = {c["id"]: _name_tokens(c.get("name", "")) for c in used}
    parent = {c["id"]: c["id"] for c in used}

    def find(x: str) -> str:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for i, a in enumerate(used):
        for b in used[i + 1:]:
            if toks[a["id"]] and toks[a["id"]] == toks[b["id"]] and _gender_ok(a.get("gender", ""), b.get("gender", "")):
                parent[find(a["id"])] = find(b["id"])
    for a in used:
        ta = toks[a["id"]]
        if not ta:
            continue
        cands = {find(b["id"]) for b in used
                 if b is not a and ta < toks[b["id"]] and _gender_ok(a.get("gender", ""), b.get("gender", ""))}
        cands.discard(find(a["id"]))
        if len(cands) == 1:
            parent[find(a["id"])] = cands.pop()
    groups: dict[str, list[dict]] = {}
    for c in used:
        groups.setdefault(find(c["id"]), []).append(c)
    keep: list[dict] = []
    for members in groups.values():
        canon = max(members, key=lambda c: (counts[c["id"]], len(c.get("name", ""))))
        merged = dict(canon)
        aliases = list(canon.get("aliases", []))
        for m in members:
            mapping[m["id"]] = canon["id"]
            for al in [m.get("name", "")] + list(m.get("aliases", [])):
                if al and al != canon.get("name") and al not in aliases:
                    aliases.append(al)
        merged["aliases"] = aliases[:12]
        keep.append(merged)
    order = {c["id"]: i for i, c in enumerate(chars)}
    keep.sort(key=lambda c: order.get(c["id"], 0))
    new = dict(cast)
    new["characters"] = keep
    new["utterances"] = [{**u, "speaker": mapping.get(u.get("speaker"), u.get("speaker"))}
                         for u in cast.get("utterances", [])]
    return new, {k: v for k, v in mapping.items() if k != v}


_PITCH_WORDS = ("pitch", "deep", "bass", "baritone", "soprano", "squeak", "shrill", "boom", "tenor", "alto")
_PITCHES = ["low-pitched", "mid-high pitched", "deep", "high-pitched", "medium-low pitched", "bright high"]
_TIMBRES = ["warm and rounded", "husky", "nasal", "bright and crisp", "breathy", "gravelly",
            "smooth", "reedy", "rich and resonant", "thin and sharp"]
_PACES = ["unhurried", "brisk", "steady", "quick and lively", "slow and deliberate"]
_AGE_PHRASE = {
    ("child", "female"): "a young girl about ten years old", ("child", "male"): "a young boy about ten years old",
    ("young", "female"): "a young woman in her twenties", ("young", "male"): "a young man in his twenties",
    ("adult", "female"): "a woman in her forties", ("adult", "male"): "a man in his forties",
    ("elder", "female"): "an elderly woman in her seventies", ("elder", "male"): "an elderly man in his seventies",
}
_ACCENT = {"british": "British English accent", "american": "American accent"}


def build_voice_prompt(char: dict, slot: int) -> str:
    """VoiceDesign instruction for one character.

    The LLM's free-text description alone produced near-identical voices for same-gender characters
    (Alice vs the Duchess: speaker-embedding cosine 0.94). Making age and gender explicit and
    giving every same-gender character in the book its own timbre/pace/pitch slot pushes the
    anchors apart; a pitch is only injected when the description does not already state one.
    """
    gender = char.get("gender", "unknown")
    age = char.get("age", "adult")
    who = _AGE_PHRASE.get((age, gender)) or {"unknown": "an androgynous voice of indeterminate age"}.get(
        gender, "an adult")
    desc = (char.get("description") or "").strip().rstrip(".")
    parts = [f"The voice of {who}"]
    accent = _ACCENT.get(char.get("accent", ""), "")
    if accent:
        parts.append(accent)
    parts.append(f"{_TIMBRES[(slot * 3 + 1) % len(_TIMBRES)]} timbre")
    parts.append(f"{_PACES[slot % len(_PACES)]} pace")
    if not any(w in desc.lower() for w in _PITCH_WORDS):
        parts.append(_PITCHES[slot % len(_PITCHES)] + " voice")
    text = ", ".join(parts) + "."
    if desc:
        text += f" {desc}."
    return text[:480]


_FRONT_RE = re.compile(
    r"project gutenberg|release date|\*\*\* ?start of|\*\*\* ?end of|language: english|produced by|"
    r"credits:|\bebook\b|colophon|copyright|all rights reserved|\bcontents\b|illustrator|"
    r"translated by|transcriber|table of contents|list of illustrations|new york|publishers|"
    r"millennium fulcrum|^\s*\*\*\*", re.I | re.M)
_BACK_RE = re.compile(
    r"project gutenberg|transcri|\*\*\* ?end of|look on the other side|grosset|titles all told|more stories of the sort|"
    r"\bon page \d+|1869 novel|works of louisa|list of (?:the )?works|for the reader'?s convenience|"
    r"originally published in other volumes|\bebook\b|publishers for a complete|new illustrated edition|"
    r"page of ads|\bblurb\b|\d{1,2}mo\b|\d+ cents|\$\d+\.\d\d|little, brown|\bprice \$|can be found at|\bhtml version\b|\[illustration", re.I)


_HEAD_RE = re.compile(r"\bCHAPTER\b|\bChapter [IVXLC\d]+\b")


def _chapter_heads(text: str) -> int:
    return len(re.findall(r"\bCHAPTER\b|\bChapter [IVXLC\d]+\b", text))


def _list_like(text: str) -> bool:
    """Catalogue / title-list pages: many short lines, no sentences."""
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    if len(lines) < 4:
        return False
    avg = sum(len(l) for l in lines) / len(lines)
    sentences = sum(1 for l in lines if re.search(r"[a-z][\.\?!]$", l))
    return avg < 45 and sentences <= len(lines) // 4


_STORY_START_RE = re.compile(
    r"(?:^|\n)\s*(?:(?:CHAPTER|Chapter)\s+(?:I|1|ONE|One|FIRST|First)\b|(?:PART|Part|BOOK|Book)\s+(?:I|1|ONE|One|FIRST|First)\b"
    r"|Letter 1\b|LETTER 1\b|(?:I|1)\.\s*\n)")
_COLOPHON_RE = re.compile(r"\n*\s*(?:CHISWICK PRESS|\[Colophon)[\s\S]*$")


def strip_boilerplate(segs: list[dict], head_scan: int = 70, tail_scan: int = 400,
                      story_window: int = 320) -> tuple[int, int, int]:
    """(first, last, head_trim) kept segment indices (+ chars to cut off the first kept segment) after dropping Project Gutenberg / publisher matter.

    Head: everything up to the LAST front-matter-looking segment within the first ``head_scan``
    segments (licence, title page, colophon, contents lists with 2+ CHAPTER lines, ...), then on
    to the first "Chapter I / Part I / Letter 1 / I." heading within ``story_window`` segments
    (prefaces, dedications and illustration lists are not narrated).
    Tail: a trailing run of transcriber notes / catalogues / ads (short fragments in between are
    tolerated). Segment (page, idx) keys are untouched, so the cast's attributions stay aligned;
    the dropped segments just are not read.
    """
    n = len(segs)
    first = 0
    for i in range(min(head_scan, n // 3)):  # short texts: never scan into the story/tail
        t = segs[i]["text"]
        if _FRONT_RE.search(t) or _chapter_heads(t) >= 2:
            first = i + 1
    head_trim = 0
    for i in range(first, min(first + story_window, n)):
        m = _STORY_START_RE.search(segs[i]["text"])
        # a contents list has later chapter headings after the match; a real start has none
        if m and not any(mm.start() > m.start() + 12 for mm in _HEAD_RE.finditer(segs[i]["text"])):
            first = i
            head_trim = m.start() + len(m.group(0)) - len(m.group(0).lstrip())
            break
    lo = max(first, n - tail_scan)
    cut, j = n, n - 1
    while j >= lo:
        t = segs[j]["text"]
        if _BACK_RE.search(t) or _list_like(t):
            cut = j
        elif len(t.strip()) >= 120:
            break
        j -= 1
    last = cut - 1
    if last < first:  # never drop a whole book
        return 0, n - 1, 0
    return first, last, head_trim


def trim_colophon(text: str) -> str:
    """Cut a printer's colophon glued to the end of the last story segment."""
    return _COLOPHON_RE.sub("", text) if _COLOPHON_RE.search(text) else text


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
    cast, merges = consolidate_roster(cast)
    pages = sorted(raw.get("pages", []), key=lambda p: p.get("page_idx", 0))
    segs = segment_pages(pages)
    characters = cast.get("characters", [])
    char_ids = {c["id"] for c in characters if c.get("id")}
    utterances = _clean_utterances(cast, char_ids | {NARRATOR_ID})
    first, last, head_trim = strip_boilerplate(segs)
    kept = [dict(sg) for sg in segs[first:last + 1]]
    if kept and head_trim:
        kept[0]["text"] = kept[0]["text"][head_trim:]
    if kept:
        kept[-1]["text"] = trim_colophon(kept[-1]["text"]) or kept[-1]["text"]
    by_page: dict[int, list] = {}
    for seg in kept:
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
    slots: dict[tuple, int] = {}
    roster = []
    for c in characters:
        if not c.get("id"):
            continue
        key = (c.get("gender", "unknown"), c.get("age", "adult"))
        slot = slots[key] = slots.get(key, -1) + 1
        roster.append({"character_id": c["id"], "name": c.get("name", ""),
                       "voice_prompt": build_voice_prompt(c, slot + 2 * (c.get("gender") == "female")),
                       "age": c.get("age", "adult"), "accent": c.get("accent", ""),
                       "temperament": c.get("temperament", ""),
                       "aliases": list(c.get("aliases", [])),
                       "voice_gender": c.get("gender", "unknown"),
                       "description": c.get("description", ""),
                       "voice_style": {"voice_id": c["id"],
                                       "voice_gender": c.get("gender", "unknown")}})
    return {"book_id": cast.get("book_id", raw.get("book_id")),
            "title": cast.get("title") or raw.get("title") or "",
            "author": cast.get("author") or "",
            "narrator": dict(cast.get("narrator") or {}),
            "content_mode": "novel", "character_roster": roster,
            "sections": sections, "formulas": [],
            "dialogue_stats": {"total": total, "attributed": attributed},
            "roster_merges": merges,
            "boilerplate": {"dropped_head": first, "dropped_tail": len(segs) - 1 - last}}


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
