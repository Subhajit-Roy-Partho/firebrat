"""Gutenberg fetch + clean: EPUB download, text extraction, boilerplate strip.

Ports and hardens ``~/community-books`` ``build_book.py``: retries the
download, validates the EPUB, strips Project Gutenberg header/footer, and
writes ``raw/raw_pages.json`` atomically. Pure helpers (strip/stats) take
plain page dicts so they are unit-testable without network or ebook parsing.
"""
from __future__ import annotations

import json
import logging
import os
import re
import time
import urllib.request

log = logging.getLogger(__name__)

EPUB_URL = "https://www.gutenberg.org/ebooks/{gid}.epub.noimages"
_EPUB_MAGIC = b"PK\x03\x04"

START = re.compile(r"\*\*\*\s*START OF (?:THE|THIS) PROJECT GUTENBERG EBOOK.*?\*\*\*", re.S | re.I)
END = re.compile(r"\*\*\*\s*END OF (?:THE|THIS) PROJECT GUTENBERG EBOOK.*", re.S | re.I)

# Catalog entries look like: slug, gutenberg, title, author, died, category,
# language, description, sourceUrl (all but slug/gutenberg optional). Entries
# with source_path (a local EPUB/MOBI/AZW or text PDF handed over by the
# server inbox) need no gutenberg id and skip the download/strip path.
REQUIRED_KEYS = ("slug", "gutenberg")


def validate_entry(entry: dict) -> dict:
    """Return a normalized catalog entry or raise ValueError."""
    if not isinstance(entry, dict):
        raise ValueError(f"Catalog entry must be an object, got {type(entry).__name__}")
    if not entry.get("slug"):
        raise ValueError(f"Catalog entry missing required key 'slug': {entry!r}")
    norm = dict(entry)
    if norm.get("source_path"):
        # Local-file entry from the server inbox: no Gutenberg id needed.
        norm.setdefault("title", norm["slug"].replace("-", " ").title())
        norm.setdefault("author", "")
        return norm
    for key in REQUIRED_KEYS:
        if not entry.get(key):
            raise ValueError(f"Catalog entry missing required key {key!r}: {entry!r}")
    try:
        gid = int(entry["gutenberg"])
    except (TypeError, ValueError):
        raise ValueError(f"Bad gutenberg id {entry.get('gutenberg')!r} for {entry.get('slug')!r}")
    if gid <= 0:
        raise ValueError(f"Bad gutenberg id {gid!r} for {entry.get('slug')!r}")
    norm["gutenberg"] = gid
    norm.setdefault("title", norm["slug"].replace("-", " ").title())
    norm.setdefault("author", "")
    return norm


def write_json_atomic(path: str, obj: object) -> None:
    """Write JSON via tmp file + os.replace so a kill never leaves it truncated."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def read_json(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def strip_boilerplate(pages: list[dict]) -> list[dict]:
    """Drop PG header (before START) and footer (from END on); drop empties.

    Pure: never mutates the input pages. Stops after the page bearing END so
    license appendices can't leak in. Pages without START/END pass through
    unchanged (already-clean text stays intact).
    """
    out: list[dict] = []
    started = any(START.search((p.get("text") or "") + "\n" + (p.get("markdown") or "")) for p in pages)
    for p in pages:
        page = dict(p)
        for key in ("text", "markdown"):
            t = page.get(key) or ""
            if not started:
                m = START.search(t)
                t = t[m.end():].lstrip() if m else ""
            m = END.search(t)
            if m:
                t = t[:m.start()].rstrip()
            page[key] = t
        if not started and (page.get("text") or "").strip():
            started = True
            out.append(page)
        elif started and (page.get("text") or "").strip():
            out.append(page)
        # else: pre-START filler or fully stripped page — drop it.
        if any(END.search(p.get(k) or "") for k in ("text", "markdown")):
            break
    return out


def cleaned_stats(pages: list[dict]) -> dict:
    """Character/word estimate of the cleaned text (words ~= chars/5)."""
    chars = sum(len(p.get("text") or "") for p in pages)
    return {"chars": chars, "words": round(chars / 5)}


def download_epub(gutenberg_id: int, dest_path: str, downloader=None, retries: int = 3) -> str:
    """Download the no-images EPUB; validate size + zip magic. Returns dest_path."""
    if os.path.isfile(dest_path) and os.path.getsize(dest_path) > 0:
        with open(dest_path, "rb") as f:
            if f.read(4) == _EPUB_MAGIC:
                log.info("EPUB %s already cached", dest_path)
                return dest_path
        log.warning("Cached EPUB %s is corrupt, re-downloading", dest_path)
    os.makedirs(os.path.dirname(os.path.abspath(dest_path)), exist_ok=True)
    url = EPUB_URL.format(gid=gutenberg_id)
    last: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            if downloader is not None:
                downloader(url, dest_path)
            else:
                urllib.request.urlretrieve(url, dest_path)
            if os.path.getsize(dest_path) == 0:
                raise IOError("downloaded file is empty")
            with open(dest_path, "rb") as f:
                if f.read(4) != _EPUB_MAGIC:
                    raise IOError("not a zip/EPUB file (bad magic) — wrong id or blocked download?")
            return dest_path
        except Exception as e:
            last = e
            log.warning("EPUB download attempt %d/%d failed for %s: %s", attempt, retries, url, e)
            try:
                if os.path.isfile(dest_path):
                    os.remove(dest_path)
            except OSError:
                pass
            time.sleep(2.0 * attempt)
    raise IOError(f"EPUB download failed after {retries} attempts: {url}: {last}")


def fetch_book(entry: dict, root: str, downloader=None, force: bool = False) -> dict:
    """Fetch+clean one catalog book. Idempotent: reuses raw_pages.json unless force.

    Entries with ``source_path`` (local EPUB/MOBI/AZW or text PDF) skip the
    Gutenberg download and boilerplate strip: ebooks go through
    ``run_ebook_extraction``, PDFs contribute one raw page per PDF page via
    pymupdf. Scanned PDFs fail loudly so the caller can redirect the user.

    Returns {slug, epub, work_dir, raw_path, stats, cached}.
    """
    entry = validate_entry(entry)
    slug = entry["slug"]
    work = os.path.join(root, "out", slug)
    raw_path = os.path.join(work, "raw", "raw_pages.json")
    if os.path.isfile(raw_path) and not force:
        raw = read_json(raw_path)
        stats = cleaned_stats(raw.get("pages", []))
        log.info("Fetch %s: cached (%d pages, ~%d words)", slug, len(raw.get("pages", [])), stats["words"])
        return {"slug": slug, "epub": entry.get("source_path") or os.path.join(root, "src", f"{entry['gutenberg']}.epub"),
                "work_dir": work, "raw_path": raw_path, "stats": stats, "cached": True}
    if entry.get("source_path"):
        return _fetch_local(entry, work, raw_path)
    epub = os.path.join(root, "src", f"{entry['gutenberg']}.epub")
    os.makedirs(os.path.join(root, "src"), exist_ok=True)
    os.makedirs(work, exist_ok=True)
    download_epub(entry["gutenberg"], epub, downloader=downloader)
    from firebrat.pipeline.ebook import run_ebook_extraction

    stats = run_ebook_extraction(epub, work, slug)
    raw = read_json(raw_path)
    raw["pages"] = strip_boilerplate(raw.get("pages", []))
    if not raw["pages"]:
        raise ValueError(f"EPUB {entry['gutenberg']} yielded no text after boilerplate strip")
    for i, p in enumerate(raw["pages"]):
        p["page_idx"] = i
    raw["page_count"] = len(raw["pages"])
    write_json_atomic(raw_path, raw)
    stats = {**stats, **cleaned_stats(raw["pages"])}
    log.info("Fetch %s: %d pages, ~%d words", slug, raw["page_count"], stats["words"])
    return {"slug": slug, "epub": epub, "work_dir": work, "raw_path": raw_path,
            "stats": stats, "cached": False}


def _fetch_local(entry: dict, work: str, raw_path: str) -> dict:
    """Fetch from a local file: ebook via run_ebook_extraction, PDF via pymupdf."""
    slug = entry["slug"]
    src = entry["source_path"]
    if not os.path.isfile(src):
        raise ValueError(f"source_path not found for {slug!r}: {src!r}")
    os.makedirs(work, exist_ok=True)
    lower = src.lower()
    if lower.endswith((".epub", ".mobi", ".azw", ".azw3")):
        from firebrat.pipeline.ebook import run_ebook_extraction

        stats = run_ebook_extraction(src, work, slug)
        raw = read_json(raw_path)
        stats = {**stats, **cleaned_stats(raw.get("pages", []))}
        log.info("Fetch %s: local ebook %d pages, ~%d words", slug, raw["page_count"], stats["words"])
        return {"slug": slug, "epub": src, "work_dir": work, "raw_path": raw_path,
                "stats": stats, "cached": False}
    if lower.endswith(".pdf"):
        try:
            import pymupdf
        except ImportError:
            raise ValueError("Reading text PDFs needs pymupdf, which is not installed on this server")
        pages: list[dict] = []
        with pymupdf.open(src) as doc:
            for i, page in enumerate(doc):
                pages.append({"page_idx": i, "text": page.get_text().strip(), "markdown": ""})
        if not any(p["text"] for p in pages):
            raise ValueError("This PDF has no embedded text; use Illustrated or Novel mode")
        raw = {"book_id": slug, "source_pdf": os.path.basename(src),
               "page_count": len(pages), "pages": pages}
        write_json_atomic(raw_path, raw)
        stats = cleaned_stats(pages)
        log.info("Fetch %s: local PDF %d pages, ~%d words", slug, len(pages), stats["words"])
        return {"slug": slug, "epub": src, "work_dir": work, "raw_path": raw_path,
                "stats": stats, "cached": False}
    raise ValueError(f"source_path for {slug!r} must be .epub/.mobi/.azw/.azw3 or .pdf, got {src!r}")
