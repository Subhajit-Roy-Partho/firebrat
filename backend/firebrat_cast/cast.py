"""Two-pass expressive casting: roster pass + attribution/emotion pass.

Pass 1 scans overlapping windows of the whole book and merges one character
roster (the LLM resolves aliases like 'Lizzy' = 'Elizabeth Bennet'). Pass 2
walks ~2500-word chunks of numbered quotes with +-200 char context and
returns compact ``[idx, speaker_id, emotion, delivery]`` rows. Per-chunk disk
cache makes runs resumable; any LLM failure falls back to the deterministic
regex speaker tags (mirrored from ``firebrat.pipeline.novel``), else narrator.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
from typing import Any

from .llm import LLMBackend, extract_json, extract_json_array, generate_many
from .segmenter import Seg, page_text, segment_pages, word_count

log = logging.getLogger(__name__)


def _batch_size() -> int:
    """LLM batch width from FIREBRAT_CAST_BATCH (default 8), clamped >= 1."""
    try:
        return max(1, int(os.environ.get("FIREBRAT_CAST_BATCH", "8")))
    except (TypeError, ValueError):
        return 8

EMOTIONS = ("neutral", "joy", "sadness", "anger", "fear", "surprise",
            "tenderness", "sarcasm", "disgust", "awe", "suspense")
GENDERS = ("male", "female", "unknown")
AGES = ("child", "young", "adult", "elder")
ACCENTS = ("british", "american", "other")
CHUNK_WORDS = 600          # keeps each attribution prompt well inside an 8k-token context
MAX_QUOTES_PER_CHUNK = 30
WINDOW_WORDS = 3500
WINDOW_OVERLAP = 800
CONTEXT_CHARS = 200
NARRATOR_ID = "narrator"

DEFAULT_NARRATOR = {
    "description": ("Warm mature storyteller with a clear mid-range voice, steady "
                    "unhurried pace, neutral accent, calm and engaging delivery."),
    "accent": "british",
}

ROSTER_SYSTEM = """You are an expert literary analyst and voice director preparing a multi-voice audiobook.
Read the excerpt and identify the NARRATOR plus EVERY character who speaks or is clearly present.
Resolve aliases to one canonical person ("Lizzy" = "Elizabeth Bennet"; "Mr. Darcy" = "Fitzwilliam Darcy").
Minor one-line speakers still count; do not invent people with no textual evidence.

For each character write a voice-design prompt (<=300 chars) a casting director could hand to a
voice actor. Be CONCRETE, not literary: apparent age and gender, pitch (low/mid/high), pace
(measured/brisk/drawling), accent heard in the dialogue, and personality in the voice
(e.g. "warm and teasing", "clipped and imperious"). Describe the voice, never the plot.

Reply with EXACTLY one JSON object and nothing else:
{"narrator": {"description": "<=300 chars voice prompt>", "accent": "british|american|other"},
 "characters": [{"name": "canonical name", "aliases": ["alt names"],
   "gender": "male|female|unknown", "age": "child|young|adult|elder",
   "temperament": "short phrase, e.g. proud and reserved",
   "accent": "british|american|other",
   "description": "<=300 chars concrete voice-design prompt",
   "importance": <rough line count, integer>}]}
Emotion is handled later; do not include it. JSON only."""

ATTRIBUTION_SYSTEM = """You are attributing dialogue for a multi-voice audiobook. Given numbered QUOTES with
surrounding context plus the fixed character roster, decide who speaks each quote and how.
Use context and conversation flow: in alternating dialogue an untagged line usually belongs to
the other participant; narration verbs ("she said") and recently mentioned names disambiguate.
Recover implicit speakers from context, but when truly unknowable use "narrator".
Recently active speakers are listed; prefer them over introducing unlikely ones.

Emotion MUST be exactly one of: neutral, joy, sadness, anger, fear, surprise, tenderness,
sarcasm, disgust, awe, suspense. Delivery is a short stage direction (<=60 chars,
e.g. "whispered, trembling", "coldly, with contempt"); empty string if plain.

Reply with EXACTLY one JSON object and nothing else:
{"utterances": [[<quote number>, "<character id or narrator>", "<emotion>", "<delivery>"], ...]}
Cover every quoted number exactly once. JSON only."""

# --- deterministic regex fallback (mirrors firebrat/pipeline/novel.py) ---
_QUOTE_FALLBACK = re.compile("\u201c[^\u201d]+\u201d|\"[^\"\n]+\"")
_TITLES = r"(?:(?:Mr|Mrs|Miss|Ms|Dr|Lady|Lord|Sir|Colonel|Captain|Major|Professor|Reverend|Uncle|Aunt)\.?\s+)?"
_NAME = r"(" + _TITLES + r"[A-Z][a-z]+(?: [A-Z][a-z]+)?)"
_VERB = (r"(?:said|asked|replied|whispered|shouted|answered|cried|murmured|exclaimed|"
         r"called|remarked|continued|added)")
_AFTER = re.compile(r"^\s*[,;:]?\s*" + _NAME + r"\s+" + _VERB + r"\b")
_AFTER_INV = re.compile(r"^\s*[,;:]?\s*" + _VERB + r"\s+" + _NAME)
_BEFORE = re.compile(_NAME + r"\s+" + _VERB + r"\s*[,;:]?\s*$")
_BEFORE_INV = re.compile(_VERB + r"\s+" + _NAME + r"\s*[,;:]?\s*$")
_TITLE_WORDS = {"mr", "mrs", "miss", "ms", "dr", "lady", "lord", "sir", "colonel",
                "captain", "major", "professor", "reverend", "uncle", "aunt"}
_EXCLUDE = {"He", "She", "They", "It", "I", "We", "You", "The", "A", "An"}


def regex_speaker(text: str, start: int, end: int) -> str | None:
    """Speaker name from the immediate dialogue tag, else None (cf. novel._speaker)."""
    after, before = text[end:end + 100], text[max(0, start - 100):start]
    tag = None
    for pattern, source in ((_AFTER, after), (_AFTER_INV, after)):
        tag = pattern.match(source)
        if tag:
            break
    if tag is None:
        for pattern in (_BEFORE, _BEFORE_INV):
            tag = pattern.search(before)
            if tag:
                break
    name = tag.group(1) if tag else None
    return name if name and name.split()[0].rstrip(".") not in _EXCLUDE else None


def norm_name(name: str) -> str:
    """Lowercase canonical key with honorifics stripped ('Mr. Darcy' -> 'darcy')."""
    words = [w.strip(".").lower() for w in re.split(r"\s+", (name or "").strip()) if w]
    return " ".join(w for w in words if w not in _TITLE_WORDS)


def _pick(value: Any, allowed: tuple[str, ...], default: str) -> str:
    value = str(value or "").strip().lower()
    return value if value in allowed else default


def sanitize_character(raw: Any) -> dict | None:
    """Validate one roster entry; None when it has no usable name."""
    if not isinstance(raw, dict) or not str(raw.get("name") or "").strip():
        return None
    try:
        importance = int(raw.get("importance", 1))
    except (TypeError, ValueError):
        importance = 1
    return {"name": str(raw["name"]).strip(),
            "aliases": [str(a).strip() for a in (raw.get("aliases") or [])
                        if str(a).strip()][:8],
            "gender": _pick(raw.get("gender"), GENDERS, "unknown"),
            "age": _pick(raw.get("age"), AGES, "adult"),
            "temperament": str(raw.get("temperament") or "")[:80],
            "accent": _pick(raw.get("accent"), ACCENTS, "british"),
            "description": str(raw.get("description") or "")[:300],
            "importance": max(0, importance)}


def sanitize_narrator(raw: Any) -> dict:
    raw = raw if isinstance(raw, dict) else {}
    desc = str(raw.get("description") or DEFAULT_NARRATOR["description"])[:300]
    return {"description": desc, "accent": _pick(raw.get("accent"), ACCENTS, "british")}


def merge_characters(existing: list[dict], new: list[dict]) -> list[dict]:
    """Fold window characters into the roster, merging by name/alias."""
    index: dict[str, dict] = {}
    for char in existing:
        index[norm_name(char["name"])] = char
        for alias in char.get("aliases", []):
            index.setdefault(norm_name(alias), char)
    for char in new:
        keys = {norm_name(char["name"])} | {norm_name(a) for a in char.get("aliases", [])}
        target = next((index[k] for k in keys if k in index), None)
        if target is None:
            existing.append(char)
            for k in keys:
                index.setdefault(k, char)
        else:
            known = {norm_name(target["name"])} | {norm_name(a) for a in target["aliases"]}
            for alias in [char["name"]] + char.get("aliases", []):
                if norm_name(alias) not in known and len(target["aliases"]) < 8:
                    target["aliases"].append(alias)
                    known.add(norm_name(alias))
            for k in keys:
                index.setdefault(k, target)
            target["importance"] = max(target["importance"], char["importance"])
            if len(char["description"]) > len(target["description"]):
                target["description"] = char["description"]
            for field in ("gender", "age", "accent"):
                if target[field] == ("unknown" if field == "gender" else
                                     "adult" if field == "age" else "british"):
                    target[field] = char[field]
            if not target["temperament"]:
                target["temperament"] = char["temperament"]
    return existing


def assign_ids(characters: list[dict]) -> list[dict]:
    """Stable char_NNN ids, most important first; fills thin descriptions."""
    ordered = sorted(characters, key=lambda c: (-c["importance"], c["name"].lower()))
    out = []
    for i, char in enumerate(ordered, 1):
        char = dict(char)
        char["id"] = f"char_{i:03d}"
        if not char["description"]:
            char["description"] = (f"Natural {char['age']} {char['gender']} voice for "
                                   f"{char['name']}, steady pace, {char['accent']} accent.")
        out.append(char)
    return out


# --- chunking ---

def make_windows(segs: list[Seg], size: int = WINDOW_WORDS,
                 overlap: int = WINDOW_OVERLAP) -> list[list[Seg]]:
    """Seg groups of ~size words with ~overlap words shared between neighbours."""
    windows, current, counts, total = [], [], [], 0
    for seg in segs:
        words = max(1, word_count(seg["text"]))
        current.append(seg)
        counts.append(words)
        total += words
        if total >= size:
            windows.append(current)
            keep, kept = [], 0  # rewind to the overlap tail
            for seg2, words2 in reversed(list(zip(current, counts))):
                keep.append(seg2)
                kept += words2
                if kept >= overlap:
                    break
            current, counts = list(reversed(keep)), [max(1, word_count(s["text"])) for s in reversed(keep)]
            total = sum(counts)
    if current and (not windows or current != windows[-1]):
        windows.append(current)
    return windows


def make_chunks(segs: list[Seg], target: int = CHUNK_WORDS) -> list[list[Seg]]:
    """Contiguous seg groups of ~target words (quotes are never split)."""
    chunks, current, total, quotes = [], [], 0, 0
    for seg in segs:
        words = max(1, word_count(seg["text"]))
        is_quote = seg.get("kind") == "quote"
        if current and (total + words > target or (is_quote and quotes >= MAX_QUOTES_PER_CHUNK)):
            chunks.append(current)
            current, total, quotes = [], 0, 0
        current.append(seg)
        total += words
        quotes += is_quote
    if current:
        chunks.append(current)
    return chunks


class ChunkCache:
    """Atomic per-chunk JSON cache beside the output; safe to kill mid-run."""

    def __init__(self, directory: str) -> None:
        self.dir = directory
        os.makedirs(directory, exist_ok=True)

    def _path(self, key: str) -> str:
        return os.path.join(self.dir, key + ".json")

    def get(self, key: str) -> Any:
        try:
            with open(self._path(key), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def put(self, key: str, obj: Any) -> None:
        tmp = self._path(key) + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.replace(tmp, self._path(key))


def _hash(text: str) -> str:
    return hashlib.sha1(text.encode()).hexdigest()[:16]


# --- roster pass ---

def build_roster_user(window_text: str) -> str:
    return ("Identify the narrator and every speaking character in this excerpt "
            "(novel prose; \"...\" marks dialogue):\n\n" + window_text)


def roster_pass(windows: list[list[Seg]], backend: LLMBackend | None,
                cache: ChunkCache) -> tuple[dict, list[dict]]:
    """One merged roster over all windows (cached); regex-only when backend=None."""
    full_text = "\n".join(s["text"] for w in windows for s in w)
    if backend is None:
        return DEFAULT_NARRATOR, _regex_roster(full_text)
    hint = '{"narrator": {}, "characters": []}'
    # Backends without a native generate_text_batch gain nothing from grouping
    # (generate_many would just loop), so keep them at width 1: that preserves
    # the old per-window failure isolation exactly (a window whose call raises
    # is skipped without consuming/losing its neighbours' replies).
    batch_n = (_batch_size() if callable(getattr(backend, "generate_text_batch", None))
               else 1)
    texts = ["\n".join(s["text"] for s in window) for window in windows]
    keys = [f"roster_{i:03d}_{_hash(text)}" for i, text in enumerate(texts)]
    uncached = [(i, texts[i], keys[i]) for i in range(len(windows))
                if cache.get(keys[i]) is None]
    for b in range(0, len(uncached), batch_n):
        batch = uncached[b:b + batch_n]
        users = [build_roster_user(text) for _, text, _ in batch]
        hinted = [u + f"\nReply with exactly one JSON object matching: {hint}"
                  for u in users]
        try:
            replies = generate_many(backend, ROSTER_SYSTEM, hinted)
        except (ValueError, RuntimeError, OSError) as e:
            log.warning("roster batch failed (%s), retrying per window", e)
            for idx, _, key in batch:
                try:
                    obj = backend.generate_json(
                        ROSTER_SYSTEM, build_roster_user(texts[idx]), hint)
                except (ValueError, RuntimeError, OSError) as e2:
                    log.warning("roster window %d failed (%s), skipping", idx, e2)
                    continue
                cache.put(key, obj)
            continue
        if replies is None:
            replies = []
        # Batch reply shorter than the batch (should not happen): retry the
        # tail sequentially so no window is silently dropped.
        if len(replies) < len(batch):
            for idx, _, key in batch[len(replies):]:
                try:
                    obj = backend.generate_json(
                        ROSTER_SYSTEM, build_roster_user(texts[idx]), hint)
                except (ValueError, RuntimeError, OSError) as e:
                    log.warning("roster window %d failed (%s), skipping", idx, e)
                    continue
                cache.put(key, obj)
        for (idx, _, key), user, reply in zip(batch, users, list(replies)):
            try:
                obj = reply if isinstance(reply, dict) else extract_json(reply)
            except ValueError:
                try:
                    obj = backend.generate_json(ROSTER_SYSTEM, user, hint)
                except (ValueError, RuntimeError, OSError) as e:
                    log.warning("roster window %d failed (%s), skipping", idx, e)
                    continue
            cache.put(key, obj)
    narrator, roster = dict(DEFAULT_NARRATOR), []
    for i in range(len(windows)):
        cached = cache.get(keys[i])
        if cached is None:
            continue
        try:
            obj = cached if isinstance(cached, dict) else extract_json(str(cached))
        except ValueError:
            continue
        narrator = sanitize_narrator(obj.get("narrator")) if i == 0 else narrator
        roster = merge_characters(roster, [c for c in
                                           (sanitize_character(c) for c in obj.get("characters", []))
                                           if c])
    if not roster:  # total LLM failure: still return something usable
        return narrator, _regex_roster(full_text)
    return narrator, assign_ids(roster)


def _regex_roster(full_text: str) -> list[dict]:
    counts: dict[str, int] = {}
    for m in _QUOTE_FALLBACK.finditer(full_text):
        name = regex_speaker(full_text, m.start(), m.end())
        if name:
            counts[name] = counts.get(name, 0) + 1
    roster = [{"name": name, "aliases": [], "gender": "unknown", "age": "adult",
               "temperament": "", "accent": "british", "description": "",
               "importance": n} for name, n in counts.items()]
    return assign_ids(roster)


# --- attribution pass ---

def chunk_quotes(chunk: list[Seg]) -> tuple[str, list[tuple[int, Seg, str, str]]]:
    """Chunk text + [(number, quote seg, prev 200 chars, next 200 chars)]."""
    text = "".join(s["text"] for s in chunk)
    items, cursor = [], 0
    for seg in chunk:
        if seg["kind"] != "quote":
            continue
        pos = text.find(seg["text"], cursor)
        pos = pos if pos >= 0 else cursor
        items.append((len(items), seg,
                      text[max(0, pos - CONTEXT_CHARS):pos],
                      text[pos + len(seg["text"]):pos + len(seg["text"]) + CONTEXT_CHARS]))
        cursor = pos + len(seg["text"])
    return text, items


def _one_line(text: str, limit: int = 400) -> str:
    """Collapse whitespace so context fits the prompt without losing words."""
    collapsed = re.sub(r"\s+", " ", text or "").strip()
    return collapsed if len(collapsed) <= limit else collapsed[:limit] + "…"


def build_attribution_user(chunk_no: int, items: list[tuple[int, Seg, str, str]],
                           roster_lines: list[str], recent: list[str]) -> str:
    lines = [f"Chunk {chunk_no}. Attribute EVERY numbered quote.",
             "Roster: " + ("; ".join(roster_lines) if roster_lines else "none (all narration)"),
             "Recent speakers: " + (", ".join(recent) if recent else "none"),
             "Quotes:"]
    for num, seg, before, after in items:
        lines.append(f"[{num}] (page {seg['page']}) {_one_line(seg['text'], 300)}")
        lines.append(f"    before: {_one_line(before, 90)}")
        lines.append(f"    after: {_one_line(after, 90)}")
    return "\n".join(lines)


def sanitize_rows(rows: Any, n: int, valid_ids: set[str]) -> list[tuple[int, str, str, str]] | None:
    """Validate LLM rows; None when the shape is unusable (retry/fallback)."""
    if not isinstance(rows, list) or len(rows) != n:
        return None
    out = []
    for row in rows:
        if not isinstance(row, (list, tuple)) or len(row) != 4:
            return None
        num, speaker, emotion, delivery = row
        if not isinstance(num, int) or not 0 <= num < n:
            return None
        speaker = str(speaker or NARRATOR_ID)
        speaker = speaker if speaker in valid_ids else NARRATOR_ID
        emotion = str(emotion or "neutral").strip().lower()
        emotion = emotion if emotion in EMOTIONS else "neutral"
        out.append((num, speaker, emotion, str(delivery or "").strip()[:60]))
    return sorted(out, key=lambda r: r[0])


def parse_attribution(text: str, n: int, valid_ids: set[str]) -> list | None:
    """Dict-wrapper or bare-array reply -> sanitized rows, else None."""
    try:
        return sanitize_rows(extract_json(text).get("utterances"), n, valid_ids)
    except ValueError:
        pass
    try:
        return sanitize_rows(extract_json_array(text), n, valid_ids)
    except ValueError:
        return None


def attribution_pass(chunks: list[list[Seg]], characters: list[dict],
                     backend: LLMBackend | None, cache: ChunkCache,
                     full_text_by_page: dict[int, str] | None = None) -> dict[tuple[int, int], tuple[str, str, str]]:
    """{(page, idx): (speaker_id, emotion, delivery)} for every quote seg.

    Batched for throughput: chunks are grouped in batches of _batch_size()
    and share one generate_many call. NOTE the tradeoff this implies: the
    'recent speakers' carry-over baked into each chunk's cache key and prompt
    is snapshotted once per batch (recent[-3:] at batch start) for ALL chunks
    in that batch, instead of evolving chunk-by-chunk as in the sequential
    path. Per-chunk disk caching, the json-repair retry, and the regex
    fallbacks all stay per item, so an interrupted run still resumes and one
    bad reply never loses the rest of its batch.
    """
    valid_ids = {c["id"] for c in characters} | {NARRATOR_ID}
    roster_lines = ([f"{c['id']} = {c['name']} ({c['gender']}, {c['age']})" for c in characters]
                    + [f"{NARRATOR_ID} = third-person narrator"])
    name_to_id = {norm_name(c["name"]): c["id"] for c in characters}
    for c in characters:
        for alias in c.get("aliases", []):
            name_to_id.setdefault(norm_name(alias), c["id"])
    result: dict[tuple[int, int], tuple[str, str, str]] = {}
    recent: list[str] = []
    # Width 1 for backends without generate_text_batch (see roster_pass): solo
    # batches reduce exactly to the old sequential semantics, including the
    # per-chunk cache keys (recent evolves chunk-by-chunk again).
    batch_n = (_batch_size() if callable(getattr(backend, "generate_text_batch", None))
               else 1)
    repair_suffix = ("\nYour previous reply was unusable (wrong shape or missing quotes). "
                     "Reply again with exactly {\"utterances\": [[n, speaker, emotion, delivery], ...]}.")
    i = 0
    while i < len(chunks):
        batch_idx = list(range(i, min(i + batch_n, len(chunks))))
        snap = list(recent[-3:])
        # Per-chunk items + keys under the batch-frozen recent snapshot.
        infos: list[tuple[int, list[Seg], list, str | None,
                                   list | None]] = []
        for ci in batch_idx:
            chunk = chunks[ci]
            _, items = chunk_quotes(chunk)
            if not items:
                infos.append((ci, chunk, items, None, []))
                continue
            key = f"chunk_{ci:04d}_" + _hash("".join(s["text"] for _, s, _, _ in items)
                                            + "".join(sorted(valid_ids)) + "".join(snap))
            rows = None
            cached = cache.get(key)
            if cached is not None:
                rows = sanitize_rows(cached, len(items), valid_ids)
            infos.append((ci, chunk, items, key, rows))
        need = [info for info in infos if info[2] and info[4] is None]
        batch_replies: dict[int, str | None] = {}
        if need and backend is not None:
            users = [build_attribution_user(ci, items, roster_lines, snap)
                     for ci, _, items, _, _ in need]
            try:
                texts = generate_many(backend, ATTRIBUTION_SYSTEM, users)
            except (ValueError, RuntimeError, OSError) as e:
                log.warning("attribution batch failed (%s), retrying per chunk", e)
                texts = None
            if texts is not None:
                for (ci, _, _, _, _), reply in zip(need, list(texts)):
                    batch_replies[ci] = reply
                # Short reply list: missing tail chunks fall through to the
                # per-item sequential path below (batch_replies.get -> None).
            for ci, _, items, _, _ in need:
                if ci in batch_replies:
                    continue
                try:
                    batch_replies[ci] = backend.generate_text(
                        ATTRIBUTION_SYSTEM,
                        build_attribution_user(ci, items, roster_lines, snap))
                except (ValueError, RuntimeError, OSError) as e:
                    log.warning("attribution chunk %d failed (%s), using regex fallback", ci, e)
                    batch_replies[ci] = None
        # Per item in original chunk order: parse, one repair retry, fallback.
        decided: dict[int, list] = {}
        for ci, chunk, items, key, cached_rows in infos:
            if not items:
                continue
            rows = cached_rows
            if rows is None and backend is not None:
                reply = batch_replies.get(ci)
                try:
                    rows = (parse_attribution(reply, len(items), valid_ids)
                            if reply is not None else None)
                except (ValueError, RuntimeError, OSError) as e:
                    log.warning("attribution chunk %d failed (%s), using regex fallback", ci, e)
                    rows = None
                if rows is None and reply is not None:
                    # One repair retry with the failure named (sequential).
                    try:
                        repair_user = (build_attribution_user(ci, items, roster_lines, snap)
                                       + repair_suffix)
                        rows = parse_attribution(
                            backend.generate_text(ATTRIBUTION_SYSTEM, repair_user),
                            len(items), valid_ids)
                    except (ValueError, RuntimeError, OSError) as e:
                        log.warning("attribution chunk %d failed (%s), using regex fallback", ci, e)
                        rows = None
            if rows is None:  # deterministic fallback: regex tag -> roster id, else narrator
                rows = _fallback_rows(chunk, items, name_to_id, full_text_by_page)
            if key is not None:
                cache.put(key, [[n, sp, em, dl] for n, sp, em, dl in rows])
            decided[ci] = rows
        # Update result + recent AFTER the whole batch, in chunk order.
        for ci, chunk, items, key, _ in infos:
            if not items:
                continue
            rows = decided[ci]
            for (_, seg, _, _), (_, speaker, emotion, delivery) in zip(items, rows):
                result[(seg["page"], seg["idx"])] = (speaker, emotion, delivery)
            recent.extend(speaker for _, speaker, _, _ in rows)
            recent = recent[-3:]
        i += batch_n
    return result


def _fallback_rows(chunk: list[Seg], items: list[tuple[int, Seg, str, str]],
                   name_to_id: dict[str, str],
                   full_text_by_page: dict[int, str] | None) -> list[tuple[int, str, str, str]]:
    page_texts: dict[int, str] = {}
    if full_text_by_page is None:
        for seg in chunk:  # rebuild per-page text from segs when not given
            page_texts.setdefault(seg["page"], "")
            page_texts[seg["page"]] += seg["text"]
    else:
        page_texts = full_text_by_page
    rows = []
    for num, seg, _, _ in items:
        text = page_texts.get(seg["page"], seg["text"])
        pos = text.find(seg["text"])
        name = regex_speaker(text, pos, pos + len(seg["text"])) if pos >= 0 else None
        speaker = name_to_id.get(norm_name(name), NARRATOR_ID) if name else NARRATOR_ID
        rows.append((num, speaker, "neutral", ""))
    return rows


# --- entry point ---

def cast_book(raw_pages_path: str, out_path: str, backend: LLMBackend | None,
              meta: dict | None = None, cache_dir: str | None = None) -> dict:
    """Full casting run: raw_pages.json -> cast.json (resumable via cache_dir)."""
    with open(raw_pages_path, encoding="utf-8") as f:
        raw = json.load(f)
    meta = meta or {}
    pages = sorted(raw.get("pages", []), key=lambda p: p.get("page_idx", 0))
    segs = segment_pages(pages)
    if cache_dir is None:
        cache_dir = os.path.join(os.path.dirname(os.path.abspath(out_path)), ".cast_cache")
    cache = ChunkCache(cache_dir)
    narrator, characters = roster_pass(make_windows(segs), backend, cache)
    full_texts = {p.get("page_idx", 0): page_text(p) for p in pages}
    attrib = attribution_pass(make_chunks(segs), characters, backend, cache, full_texts)
    utterances = [{"page": s["page"], "idx": s["idx"],
                   "speaker": attrib.get((s["page"], s["idx"]), (NARRATOR_ID, "neutral", ""))[0],
                   "emotion": attrib.get((s["page"], s["idx"]), (NARRATOR_ID, "neutral", ""))[1],
                   "delivery": attrib.get((s["page"], s["idx"]), (NARRATOR_ID, "neutral", ""))[2]}
                  for s in segs if s["kind"] == "quote"]
    page_mood: dict[str, dict] = {}
    for s in segs:
        if s["kind"] != "quote" or (s["page"], s["idx"]) not in attrib:
            continue
        emotion = attrib[(s["page"], s["idx"])][1]
        mood = page_mood.setdefault(str(s["page"]), {"emotion": "neutral", "delivery": "", "_n": 0})
        if emotion != "neutral" and mood["_n"] == 0:
            mood.update(emotion=emotion, _n=1)
    for mood in page_mood.values():
        mood.pop("_n", None)
    cast = {"book_id": meta.get("book_id", raw.get("book_id", "")),
            "title": meta.get("title", raw.get("title", "")),
            "author": meta.get("author", raw.get("author", "")),
            "llm": {"backend": getattr(backend, "name", "regex-only") if backend else "regex-only",
                    "model": getattr(backend, "model", getattr(backend, "model_id", "")) if backend else ""},
            "narrator": narrator, "characters": characters,
            "utterances": utterances, "page_mood": page_mood}
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cast, f, ensure_ascii=False, indent=2)
    os.replace(tmp, out_path)
    return cast
