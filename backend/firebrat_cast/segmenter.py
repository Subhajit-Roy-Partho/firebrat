"""Deterministic quote/narration segmentation shared by cast + compile.

Quote detection mirrors ``firebrat.pipeline.novel`` exactly (same regex) so
casting and the novel compiler agree on what counts as dialogue. Pure stdlib,
no models, no numpy.
"""
from __future__ import annotations

import re
from typing import TypedDict

# Same pattern as novel._QUOTE (curly-quoted or straight-quoted dialogue).
QUOTE_RE = re.compile("\u201c[^\u201d]+\u201d|\"[^\"\n]+\"")
MAX_LEN = 350
_SENT_END = re.compile(r"[.!?][\"'\"\u2019)\]\u2026]?\s+")
_WORD = re.compile(r"\S+")


class Seg(TypedDict):
    page: int
    idx: int
    kind: str  # 'quote' | 'narration'
    text: str


def page_text(page: dict) -> str:
    """Prose for one raw page (text wins, markdown falls back)."""
    return page.get("text") or page.get("markdown") or ""


def word_count(text: str) -> int:
    return len(_WORD.findall(text))


def _spans(text: str) -> list[tuple[str, str]]:
    """Alternate narration/quote spans; whitespace-only gaps join a neighbour."""
    parts: list[tuple[str, str]] = []
    cursor = 0
    for m in QUOTE_RE.finditer(text):
        if m.start() > cursor:
            parts.append(("narration", text[cursor:m.start()]))
        parts.append(("quote", m.group()))
        cursor = m.end()
    if cursor < len(text):
        parts.append(("narration", text[cursor:]))
    out: list[list[str]] = []
    pending = ""
    for kind, chunk in parts:
        if kind == "narration" and not chunk.strip():
            if out:
                out[-1][1] += chunk
            else:
                pending += chunk
            continue
        if pending:
            chunk = pending + chunk
            pending = ""
        out.append([kind, chunk])
    if pending and out:
        out[-1][1] += pending
    return [(k, c) for k, c in out if c]


def _bound(chunk: str, limit: int = MAX_LEN) -> list[str]:
    """Split to <= limit chars at sentence ends (else word gaps); lossless."""
    if len(chunk) <= limit:
        return [chunk]
    pieces: list[str] = []
    rest = chunk
    while len(rest) > limit:
        window = rest[:limit]
        cuts = [m.end() for m in _SENT_END.finditer(window)]
        cut = max(cuts) if cuts else 0
        if not cut:
            gap = window.rfind(" ")
            cut = gap + 1 if gap > 0 else limit  # single long token: hard cut
        pieces.append(rest[:cut])
        rest = rest[cut:]
    pieces.append(rest)
    return pieces


def segment_pages(pages: list[dict], limit: int = MAX_LEN) -> list[Seg]:
    """Split raw pages into Segs; (page, idx) is a stable per-page key."""
    segs: list[Seg] = []
    for page in sorted(pages, key=lambda p: p.get("page_idx", 0)):
        text = page_text(page)
        if not text.strip():
            continue
        idx = 0
        for kind, chunk in _spans(text):
            for piece in _bound(chunk, limit):
                segs.append({"page": page["page_idx"], "idx": idx,
                             "kind": kind, "text": piece})
                idx += 1
    return segs
