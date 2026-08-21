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


FALLBACK_SECTION = {
    "title": "Unprocessed chunk",
    "source_pages": [],
    "segments": [
        {"type": "prose", "text": "This section's content is being prepared. Please check back after reprocessing.", "ref": None, "visually_essential": False}
    ],
}


def run_compilation(raw_pages_path: str, output_dir: str, book_id: str | None = None) -> dict:
    """Run Stage 2.

    Reads raw_pages.json, calls LLM per chunk, writes compiled.json (LLMOutput shape).
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

    all_sections: list[dict] = []
    all_formulas: list[dict] = []
    needs_review_chunks: list[int] = []
    formula_counter = 0
    from firebrat.utils.ids import make_formula_id

    for chunk in chunks:
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
            # Normalize: LLM should return {"sections": [...]} but tolerate wrapper variations
            if "sections" not in parsed and "section" in parsed:
                parsed = {"sections": parsed["section"] if isinstance(parsed["section"], list) else [parsed["section"]]}
            output = LLMOutput.model_validate(parsed)
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
        except Exception as e:
            log.exception("Chunk %d compilation failed: %s", chunk["chunk_idx"], e)
            needs_review_chunks.append(chunk["chunk_idx"])
            all_sections.append({
                **FALLBACK_SECTION,
                "source_pages": [p["page_idx"] for p in chunk["pages"]],
                "title": f"Section {len(all_sections)+1} — needs review",
            })

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
