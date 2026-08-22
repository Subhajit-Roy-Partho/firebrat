"""Stage 2: chunk raw_pages → LLM → per-section narration segments."""
import json
import logging
import os
import re

from firebrat.config import CHUNK_PAGES, SPARK_MODEL, DEEPSEEK_MODEL
from firebrat.llm_client import chat_json
from firebrat.pipeline.notify import send_telegram
from firebrat.pipeline.schema import LLMOutput

log = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are a technical audiobook narrator for a textbook on Arm Cortex-M microcontrollers and SoC design.
You convert raw extracted pages into a spoken narration script that is accurate, natural, and easy to follow by ear.

Your input for each chunk is:
- The raw text/markdown for ~{chunk_pages} pages.
- A catalog of figures/tables detected on those pages (each with id, page, caption). You MUST NOT invent figure/table ids; only use ids that appear in the catalog. If a concept needs no visual reference, set ref to null.
- Formulas are NOT pre-extracted (this book typesets math as plain inline text, e.g. "tCK = 1/f = 10 ns") — YOU must recognize mathematical relationships in the page text yourself and author real LaTeX for them.

Output JSON schema (strict):
{{
  "sections": [
    {{
      "title": "Section title (concise, human)",
      "source_pages": [page_idx, ...],   // 0-based page indices from this chunk
      "segments": [
        {{"type": "heading|prose|figure_callout|formula_callout|table_callout", "text": "spoken sentence — clean, narration-ready prose", "ref": "fig_0001 | tbl_0001 | null", "latex": "T = 1/f | null", "visually_essential": false}}
      ]
    }}
  ]
}}

Rules:
- Group content into 1-3 logical sections per chunk (e.g. "Clock Tree", "NVIC Priority Grouping").
- Each segment is ONE sentence/utterance (15-30 words ideal). Break long paragraphs into multiple prose segments.
- For formula_callout segments: rewrite the relationship into spoken English in "text" (e.g. "the clock period T equals one over the frequency f"), AND put real LaTeX in "latex" (e.g. "T = \\frac{{1}}{{f}}"). Leave ref null — a formula id is assigned automatically from your latex. Only emit formula_callout when the source text actually states a mathematical relationship (an equation, not just a numeric spec like "100 MHz").
- For figures/tables: one callout segment that says "As shown in Figure X, ..." with ref set from the catalog. Don't repeat the same figure more than once per section. Never set latex on these.
- Heading segments: short title, ref and latex null.
- Set visually_essential true only when audio alone is insufficient (diagram topology, register maps, dense equations).
- Text must be ready for TTS — no markdown, no LaTeX syntax in the "text" field (LaTeX only goes in "latex").
- If the chunk is mostly bibliography/references or pure front matter, you may produce an empty title with a single prose segment summarizing it, and should produce zero formula_callout segments.
""".strip()


_EQUATION_HINT_RE = re.compile(r"[A-Za-z]{1,6}\s*=\s*[A-Za-z0-9]")

def _needs_strong_model(chunk: dict) -> bool:
    figs_tables = sum(len(p.get("figures", [])) + len(p.get("tables", [])) for p in chunk["pages"])
    equation_hints = sum(len(_EQUATION_HINT_RE.findall(p.get("text", ""))) for p in chunk["pages"])
    return equation_hints >= 1 or figs_tables >= 2


def _chunk_raw_pages(raw: dict, chunk_pages: int = CHUNK_PAGES) -> list[dict]:
    pages = raw["pages"]
    chunks: list[dict] = []
    for start in range(0, len(pages), chunk_pages):
        chunk_pages_list = pages[start:start + chunk_pages]
        catalog = {"figures": [], "tables": []}
        for p in chunk_pages_list:
            for f in p.get("figures", []):
                catalog["figures"].append({"id": f["figure_id"], "page": p["page_idx"], "caption": f.get("caption", "")})
            for t in p.get("tables", []):
                catalog["tables"].append({"id": t["table_id"], "page": p["page_idx"], "caption": t.get("caption", "")})
        chunks.append({
            "chunk_idx": len(chunks),
            "pages": chunk_pages_list,
            "page_range": [chunk_pages_list[0]["page_idx"], chunk_pages_list[-1]["page_idx"]] if chunk_pages_list else [0, 0],
            "catalog": catalog,
        })
    return chunks


def _build_user_message(chunk: dict) -> str:
    header = f"Chunk {chunk['chunk_idx']} — pages {chunk['page_range'][0]+1} to {chunk['page_range'][1]+1} (0-based indices {chunk['page_range']})"
    catalog_str = json.dumps(chunk["catalog"], ensure_ascii=False, indent=2)
    pages_text_parts = []
    for p in chunk["pages"]:
        txt = (p.get("text") or "")[:3500]  # cap per page to keep prompt sane
        md = (p.get("markdown") or "")[:1500]
        blob = f"--- Page {p['page_idx']+1} (idx {p['page_idx']}) ---\n"
        if txt.strip():
            blob += txt.strip() + "\n"
        if md.strip():
            blob += "[markdown slice]\n" + md.strip() + "\n"
        if not txt.strip() and not md.strip():
            blob += "[no extractable text on this page]\n"
        pages_text_parts.append(blob)
    pages_text = "\n".join(pages_text_parts)[:15000]
    return (
        header + "\n\n"
        + "CATALOG of available ids (only these may appear as ref):\n" + catalog_str + "\n\n"
        + "PAGE TEXTS:\n" + pages_text
    )


_REF_PATTERN_RE = re.compile(r"^(fig|formula|tbl)_\d{4}$")
_WRAPPER_KEYS = ("data", "result", "response", "output", "content")


def _normalize_wrapper(parsed: dict) -> dict:
    """LLMs given a JSON-schema-shaped prompt sometimes echo a schema-style
    envelope instead of the content directly — observed in practice from
    deepseek-v4-pro:thinking: {"type": "object", "data": {"sections": [...]}}
    instead of just {"sections": [...]}. Unwrap any of a few common envelope
    key names, and the older singular-"section" variant, before validation.
    """
    if not isinstance(parsed, dict):
        return parsed
    if "sections" in parsed:
        return parsed
    if "section" in parsed:
        return {"sections": parsed["section"] if isinstance(parsed["section"], list) else [parsed["section"]]}
    for key in _WRAPPER_KEYS:
        inner = parsed.get(key)
        if isinstance(inner, dict) and "sections" in inner:
            return inner
        if isinstance(inner, dict) and "section" in inner:
            return {"sections": inner["section"] if isinstance(inner["section"], list) else [inner["section"]]}
    return parsed


def _fill_blank_titles(parsed: dict) -> dict:
    """The prompt explicitly permits an empty title for front-matter/bibliography
    chunks ("you may produce an empty title..."), but the schema requires a
    non-empty title (a blank section title would look broken in the reader UI).
    That contradiction made every such chunk fail validation in production —
    substitute a page-range-derived title instead of rejecting the whole chunk.
    """
    for sec in parsed.get("sections", []) if isinstance(parsed, dict) else []:
        if not isinstance(sec, dict):
            continue
        title = sec.get("title")
        if not title or not str(title).strip():
            pages = sec.get("source_pages") or []
            if pages:
                sec["title"] = f"Pages {min(pages) + 1}–{max(pages) + 1}"
            else:
                sec["title"] = "Untitled section"
    return parsed


def _sanitize_refs(parsed: dict) -> dict:
    """Null out any 'ref' that doesn't match fig/formula/tbl_NNNN before strict
    pydantic validation, so one malformed ref (e.g. the LLM writing 'fig_1.15'
    instead of 'fig_0001') doesn't discard an otherwise-good chunk's content.
    Unknown-but-well-formed ids are still caught later by validate_refs().
    """
    for sec in parsed.get("sections", []) if isinstance(parsed, dict) else []:
        if not isinstance(sec, dict):
            continue
        for seg in sec.get("segments", []):
            if not isinstance(seg, dict):
                continue
            ref = seg.get("ref")
            if ref is not None and not _REF_PATTERN_RE.match(str(ref)):
                seg["ref"] = None
    return parsed


FALLBACK_SECTION = {
    "title": "Unprocessed chunk",
    "source_pages": [],
    "segments": [
        {"type": "prose", "text": "This section's content is being prepared. Please check back after reprocessing.", "ref": None, "visually_essential": False}
    ],
}


def _load_checkpoint(checkpoint_path: str) -> tuple[list[dict], list[dict], int, set[int]]:
    """Load existing checkpoint if present. Returns (sections, formulas, formula_counter, needs_review_set)."""
    if not os.path.isfile(checkpoint_path):
        return [], [], 0, set()
    try:
        with open(checkpoint_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        sections = data.get("sections", []) if isinstance(data, dict) else []
        formulas = data.get("formulas", []) if isinstance(data, dict) else []
        # formula_counter is max minted id
        fc = len(formulas)
        # also try to parse explicit counter if present (forward compat)
        if isinstance(data, dict) and "formula_counter" in data:
            try:
                fc = int(data["formula_counter"])
            except Exception:
                pass
        needs = set(data.get("needs_review_chunks", [])) if isinstance(data, dict) else set()
        # infer needs_review from placeholder titles if field missing (backward compat)
        if not needs:
            for sec in sections:
                title = sec.get("title", "") if isinstance(sec, dict) else ""
                if "needs review" in title.lower():
                    pages = sec.get("source_pages", [])
                    # find chunk that owns these pages (first page)
                    if pages:
                        needs.add(min(pages) // CHUNK_PAGES)
        return sections, formulas, fc, needs
    except Exception as e:
        log.warning("Checkpoint load failed for %s: %s — starting fresh", checkpoint_path, e)
        return [], [], 0, set()


def _pages_covered_by_checkpoint(sections: list[dict]) -> set[int]:
    covered: set[int] = set()
    for sec in sections:
        if isinstance(sec, dict):
            for p in sec.get("source_pages", []) or []:
                try:
                    covered.add(int(p))
                except Exception:
                    pass
    return covered


def run_compilation(raw_pages_path: str, output_dir: str, book_id: str | None = None, resume: bool = True, retry_failed: bool = False) -> dict:
    """Run Stage 2.

    Reads raw_pages.json, calls LLM per chunk, writes compiled.json (LLMOutput shape).
    If resume is True and a checkpoint exists, already-covered page ranges are skipped.
    Returns summary stats.
    """
    with open(raw_pages_path, "r", encoding="utf-8") as f:
        raw = json.load(f)
    book_id = book_id or raw.get("book_id", "book")
    chunks = _chunk_raw_pages(raw)
    log.info("Compilation: %d chunks for %s", len(chunks), book_id)

    # Collect all known ids for validation after each chunk
    known_ids: set[str] = set()
    for p in raw["pages"]:
        for f in p.get("figures", []):
            known_ids.add(f["figure_id"])
        for t in p.get("tables", []):
            known_ids.add(t["table_id"])
        for fo in p.get("formulas", []):
            known_ids.add(fo["formula_id"])

    checkpoint_path = os.path.join(os.path.dirname(raw_pages_path), "compiled.json")
    if resume and os.path.isfile(checkpoint_path):
        all_sections, all_formulas, formula_counter, _prev_needs = _load_checkpoint(checkpoint_path)
        needs_review_chunks: list[int] = sorted(_prev_needs)
        covered = _pages_covered_by_checkpoint(all_sections)
        log.info("Resuming from checkpoint: %d sections, %d formulas, %d pages already covered, %d prior failures",
                 len(all_sections), len(all_formulas), len(covered), len(needs_review_chunks))
    else:
        all_sections: list[dict] = []
        all_formulas: list[dict] = []
        needs_review_chunks: list[int] = []
        formula_counter = 0
        covered = set()
    from firebrat.utils.ids import make_formula_id

    for chunk in chunks:
        # Resume: skip chunks whose pages are already fully covered by checkpoint
        if resume:
            chunk_pages_set = {p["page_idx"] for p in chunk["pages"]}
            # If all pages already covered, skip unless retry_failed and this chunk was a placeholder
            if chunk_pages_set and chunk_pages_set.issubset(covered):
                if not retry_failed or chunk["chunk_idx"] not in needs_review_chunks:
                    log.info("Chunk %d/%d pages=%s already in checkpoint — skipping", chunk["chunk_idx"]+1, len(chunks), chunk["page_range"])
                    continue
                else:
                    # retrying a failed chunk: remove its placeholder sections first
                    log.info("Retrying previously failed chunk %d pages=%s", chunk["chunk_idx"], chunk["page_range"])
                    # drop placeholder sections that belong to this chunk
                    all_sections = [s for s in all_sections if not (set(s.get("source_pages", []) or []) & chunk_pages_set and "needs review" in s.get("title","").lower())]
                    if chunk["chunk_idx"] in needs_review_chunks:
                        needs_review_chunks.remove(chunk["chunk_idx"])
                    # recompute covered after removal
                    covered = _pages_covered_by_checkpoint(all_sections)

        model = DEEPSEEK_MODEL if _needs_strong_model(chunk) else SPARK_MODEL
        fallback = DEEPSEEK_MODEL if model == SPARK_MODEL else None
        system = SYSTEM_PROMPT.replace("{chunk_pages}", str(CHUNK_PAGES))
        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": _build_user_message(chunk)},
        ]
        log.info("Chunk %d/%d model=%s pages=%s", chunk["chunk_idx"]+1, len(chunks), model, chunk["page_range"])
        try:
            parsed, used_model = chat_json(messages, model, temperature=0.2, max_tokens=7000,
                                           retries_parse=3, fallback_model=fallback)
            parsed = _normalize_wrapper(parsed)
            parsed = _sanitize_refs(parsed)
            parsed = _fill_blank_titles(parsed)
            # Detect schema-hallucination where LLM returns a JSON Schema instead of instance
            # e.g. {"type":"object","properties":{"sections":{"type":"array"}},"required":["sections"]}
            if isinstance(parsed, dict) and "properties" in parsed and "sections" not in parsed:
                raise ValueError(f"LLM returned JSON Schema hallucination instead of instance: keys={list(parsed.keys())}")
            try:
                output = LLMOutput.model_validate(parsed)
            except Exception as ve:
                # Validation failure (e.g. blank title edge case missed, or schema envelope)
                # retry once with fallback stronger model before giving up
                if fallback and model != fallback:
                    log.warning("Chunk %d validation failed with %s (%s), retrying with fallback %s", chunk["chunk_idx"], model, ve, fallback)
                    parsed2, _ = chat_json(messages, fallback, temperature=0.2, max_tokens=7000, retries_parse=3, fallback_model=None)
                    parsed2 = _normalize_wrapper(parsed2)
                    parsed2 = _sanitize_refs(parsed2)
                    parsed2 = _fill_blank_titles(parsed2)
                    output = LLMOutput.model_validate(parsed2)
                else:
                    raise
            errs = output.validate_refs(known_ids)
            if errs:
                log.warning("Chunk %d had invalid refs: %s — demoting bad refs to null", chunk["chunk_idx"], errs)
                # Harmless repair: null out bad refs and re-validate
                for sec in output.sections:
                    for seg in sec.segments:
                        if seg.ref is not None and seg.ref not in known_ids:
                            seg.ref = None
            # Assign fallback source_pages if LLM left them empty
            for sec in output.sections:
                if not sec.source_pages:
                    sec.source_pages = [p["page_idx"] for p in chunk["pages"]]

            # Mint formula ids for LLM-authored LaTeX (our code assigns ids, not the LLM)
            for sec in output.sections:
                sec_page = sec.source_pages[0] if sec.source_pages else chunk["page_range"][0]
                for seg in sec.segments:
                    if seg.type == "formula_callout" and seg.latex and seg.latex.strip():
                        formula_counter += 1
                        fid = make_formula_id(formula_counter)
                        all_formulas.append({
                            "formula_id": fid,
                            "page": sec_page,
                            "latex": seg.latex.strip(),
                            "spoken_text": seg.text,
                            "visually_essential": seg.visually_essential,
                        })
                        seg.ref = fid
                    elif seg.type == "formula_callout" and not (seg.latex and seg.latex.strip()):
                        # Model produced a formula_callout with no LaTeX — demote to prose
                        seg.type = "prose"

            all_sections.extend([s.model_dump() for s in output.sections])
            # update covered set with newly compiled pages
            for sec in output.sections:
                for p in sec.source_pages:
                    covered.add(p)
        except Exception as e:
            log.exception("Chunk %d compilation failed: %s", chunk["chunk_idx"], e)
            needs_review_chunks.append(chunk["chunk_idx"])
            all_sections.append({
                **FALLBACK_SECTION,
                "source_pages": [p["page_idx"] for p in chunk["pages"]],
                "title": f"Section {len(all_sections)+1} — needs review",
            })
            for p in chunk["pages"]:
                covered.add(p["page_idx"])

        # Checkpoint after every chunk — nano-gpt latency has been variable
        # enough in practice (routine 120s+ responses) that losing an hour
        # of already-compiled sections to an interrupted run is a real cost,
        # not a theoretical one. This write is cheap relative to the LLM call
        # that precedes it.
        _checkpoint = {"book_id": book_id, "sections": all_sections, "formulas": all_formulas,
                       "formula_counter": formula_counter, "needs_review_chunks": needs_review_chunks}
        _checkpoint_path = os.path.join(os.path.dirname(raw_pages_path), "compiled.json")
        with open(_checkpoint_path, "w", encoding="utf-8") as f:
            json.dump(_checkpoint, f, ensure_ascii=False, indent=2)

        if (chunk["chunk_idx"] + 1) % 5 == 0:
            send_telegram(f"Firebrat compilation: {chunk['chunk_idx']+1}/{len(chunks)} chunks done for {book_id}")

    compiled = {"book_id": book_id, "sections": all_sections, "formulas": all_formulas}
    compiled_path = os.path.join(os.path.dirname(raw_pages_path), "compiled.json")
    # If output_dir is the package dir different from raw_dir, also write there
    # raw_pages_path is .../raw/raw_pages.json, compiled lives alongside it
    with open(compiled_path, "w", encoding="utf-8") as f:
        json.dump(compiled, f, ensure_ascii=False, indent=2)

    # Also copy to output_dir for manifest stage convenience when they differ
    alt_compiled = os.path.join(output_dir, "compiled.json")
    if os.path.abspath(alt_compiled) != os.path.abspath(compiled_path):
        with open(alt_compiled, "w", encoding="utf-8") as f:
            json.dump(compiled, f, ensure_ascii=False, indent=2)

    stats = {
        "book_id": book_id,
        "compiled_path": compiled_path,
        "chunk_count": len(chunks),
        "section_count": len(all_sections),
        "formula_count": len(all_formulas),
        "known_ids": len(known_ids),
        "needs_review_chunks": needs_review_chunks,
    }
    log.info("Compilation done: %s", stats)
    if needs_review_chunks:
        send_telegram(f"⚠️ Firebrat compilation: {len(needs_review_chunks)} chunks need review for {book_id}")
    return stats
