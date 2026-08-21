"""Stage 1: hybrid marker + PyMuPDF extraction → raw_pages.json + assets."""
import json
import logging
import os
import re
import shutil

from firebrat.utils.ids import (
    make_figure_id, make_formula_id, make_table_id, sanitize_book_id,
)
from firebrat.utils.pdf_utils import render_page_png, get_page_count

log = logging.getLogger(__name__)

FIGURE_RE = re.compile(r"!\[.*?\]\(.*?\)")
LATEX_INLINE_RE = re.compile(r"\$(.+?)\$")


def _try_marker(pdf_path: str):
    """Run marker's PdfConverter and return (markdown_text, images_dict, json_blocks) or None."""
    try:
        from marker.converters.pdf import PdfConverter
        from marker.models import create_model_dict
        converter = PdfConverter(artifact_dict=create_model_dict())
        rendered = converter(pdf_path)
        # Newer marker: rendered has .markdown and .images
        # Older: converter returns rendered object with text_from_rendered helper
        try:
            from marker.output import text_from_rendered
            md, id_map, images = text_from_rendered(rendered)
        except ImportError:
            md = getattr(rendered, "markdown", "") or str(rendered)
            images = getattr(rendered, "images", {}) or {}
            id_map = {}
        # Try JSON tree mode for structured blocks
        blocks = None
        try:
            # marker's JSON output gives structured blocks
            json_str = rendered.json if hasattr(rendered, "json") else None
            if json_str:
                blocks = json.loads(json_str) if isinstance(json_str, str) else json_str
        except Exception as e:
            log.debug("marker JSON blocks unavailable: %s", e)
        log.info("Marker succeeded: %d chars markdown, %d images", len(md or ""), len(images or {}))
        return md or "", images or {}, blocks
    except Exception as e:
        log.warning("Marker failed, falling back to PyMuPDF: %s", e, exc_info=True)
        return None


def run_extraction(pdf_path: str, output_dir: str, book_id: str | None = None) -> dict:
    """Run Stage 1. Returns stats dict and writes raw_pages.json + assets.

    output_dir is the book package dir, e.g. backend/output/<book_id>/
    """
    book_id = book_id or sanitize_book_id(pdf_path)
    pkg_dir = os.path.join(output_dir, book_id) if os.path.basename(output_dir) != book_id else output_dir
    raw_dir = os.path.join(pkg_dir, "raw")
    assets_dir = os.path.join(pkg_dir, "assets")
    pages_img_dir = os.path.join(assets_dir, "pages")
    figures_dir = os.path.join(assets_dir, "figures")
    tables_dir = os.path.join(assets_dir, "tables")
    formulas_dir = os.path.join(assets_dir, "formulas")
    for d in (raw_dir, pages_img_dir, figures_dir, tables_dir, formulas_dir):
        os.makedirs(d, exist_ok=True)

    total_pages = get_page_count(pdf_path)
    log.info("Extracting %s (%d pages) -> %s", pdf_path, total_pages, pkg_dir)

    # Marker pass
    marker_result = _try_marker(pdf_path)
    marker_md: str = ""
    marker_images: dict = {}
    if marker_result is not None:
        marker_md, marker_images, _blocks = marker_result
        # Save marker markdown for inspection
        with open(os.path.join(raw_dir, "marker.md"), "w", encoding="utf-8") as f:
            f.write(marker_md)

    # Persist raw marker images (marker keys are like image filenames)
    # Also render every page as PNG for the reader fallback
    import pymupdf  # type: ignore
    doc = pymupdf.open(pdf_path)
    raw_pages: list[dict] = []
    fig_counter = 0
    tbl_counter = 0
    formula_counter = 0

    # If marker produced images, save them now keyed by any stable name
    saved_marker_images: dict[str, str] = {}
    for idx, (key, pil_img) in enumerate((marker_images or {}).items()):
        # marker image keys are often like "image_0.png" — map to fig_* where possible
        # Keep them all under assets/marker_images for now, referenced later
        try:
            from PIL import Image  # noqa: F401
            fname = f"marker_{idx:04d}.png"
            out = os.path.join(assets_dir, "marker_images", fname)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            if hasattr(pil_img, "save"):
                pil_img.save(out)
            else:
                # already bytes or path
                shutil.copy(str(pil_img), out)
            saved_marker_images[key] = os.path.join("assets/marker_images", fname)
        except Exception as e:
            log.debug("Failed to save marker image %s: %s", key, e)

    # Heuristic: scan marker markdown per page-ish chunk for LaTeX and figure refs
    # For now we rely on pymupdf for actual figure crops + page renders, and parse marker text for formulas.

    for page_idx in range(total_pages):
        page = doc[page_idx]
        # Full page render
        page_img_name = f"page_{page_idx+1:04d}.png"
        page_img_path = os.path.join(pages_img_dir, page_img_name)
        try:
            pix = page.get_pixmap(dpi=150)
            pix.save(page_img_path)
            pix = None  # free
        except Exception as e:
            log.warning("Failed to render page %d: %s", page_idx, e)

        # Raw text / markdown slice for this page from marker if available
        # Marker markdown is global — do a simple split by page separator if present,
        # otherwise assign proportionally. Use fallback to pymupdf text.
        page_text = page.get_text("text") or ""
        page_markdown = ""

        # Extract images on this page via pymupdf
        page_figures: list[dict] = []
        page_tables: list[dict] = []
        page_formulas: list[dict] = []

        # Figures: each embedded image
        try:
            for img_idx, img_info in enumerate(page.get_images(full=True)):
                xref = img_info[0]
                try:
                    pix2 = pymupdf.Pixmap(doc, xref)
                    # Skip tiny icons (< 80x80)
                    if pix2.w < 80 or pix2.h < 80:
                        pix2 = None
                        continue
                    # PNG only supports Gray/RGB (+alpha); convert anything else
                    # (CMYK n=4, indexed, etc.) to RGB first.
                    if pix2.colorspace is None or pix2.colorspace.n not in (1, 3):
                        pix2 = pymupdf.Pixmap(pymupdf.csRGB, pix2)
                    width, height = pix2.w, pix2.h
                    fid = make_figure_id(fig_counter + 1)
                    fname = f"{fid}.png"
                    out = os.path.join(figures_dir, fname)
                    pix2.save(out)
                    pix2 = None
                    fig_counter += 1
                    page_figures.append({
                        "figure_id": fid,
                        "page": page_idx,
                        "caption": "",
                        "image_path": os.path.join("assets/figures", fname),
                        "width": width, "height": height,
                    })
                except Exception as e:
                    log.warning("Figure extract failed page %d img %d: %s", page_idx, img_idx, e)
        except Exception as e:
            log.debug("get_images failed page %d: %s", page_idx, e)

        # Formulas: detect LaTeX fragments in marker markdown slice or page text
        # Heuristic: find $...$ and $$...$$ and \[...\] in marker markdown near this page
        # For now do a global pass after the loop; per-page formula detection is the fallback below.
        # Simple per-page heuristic: look for math-like lines in extracted text
        for m in LATEX_INLINE_RE.finditer(page_text):
            latex = m.group(1).strip()
            if len(latex) < 4 or len(latex) > 600:
                continue
            # need at least one math char to avoid false positives on money amounts
            if not any(c in latex for c in "\\^_{}="):
                continue
            formula_counter += 1
            fid2 = make_formula_id(formula_counter)
            page_formulas.append({
                "formula_id": fid2,
                "page": page_idx,
                "latex": latex,
                "image_path": os.path.join("assets/formulas", f"{fid2}.png"),
                "spoken_text": "",
                "visually_essential": False,
            })

        raw_pages.append({
            "page_idx": page_idx,
            "text": page_text,
            "markdown": page_markdown,
            "figures": page_figures,
            "tables": page_tables,
            "formulas": page_formulas,
        })

    doc.close()

    # Second pass: harvest LaTeX from marker markdown globally if available (better recall)
    if marker_md:
        # $$ display math $$
        for m in re.finditer(r"\$\$(.+?)\$\$", marker_md, re.DOTALL):
            latex = m.group(1).strip()
            if 4 <= len(latex) <= 800 and any(c in latex for c in "\\^_{}="):
                formula_counter += 1
                fid3 = make_formula_id(formula_counter)
                # assign to middle page as placeholder if no page mapping
                raw_pages[min(len(raw_pages)//2, len(raw_pages)-1)]["formulas"].append({
                    "formula_id": fid3,
                    "page": min(len(raw_pages)//2, len(raw_pages)-1),
                    "latex": latex,
                    "image_path": os.path.join("assets/formulas", f"{fid3}.png"),
                    "spoken_text": "",
                    "visually_essential": False,
                })

    raw_out = {
        "book_id": book_id,
        "source_pdf": os.path.basename(pdf_path),
        "page_count": total_pages,
        "pages": raw_pages,
    }
    # Validate shape before writing
    from firebrat.pipeline.schema import RawPagesFile
    RawPagesFile.model_validate(raw_out)

    out_json = os.path.join(raw_dir, "raw_pages.json")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(raw_out, f, ensure_ascii=False, indent=2)

    stats = {
        "book_id": book_id,
        "package_dir": pkg_dir,
        "raw_pages_json": out_json,
        "page_count": total_pages,
        "figure_count": fig_counter,
        "formula_count": formula_counter,
        "marker_chars": len(marker_md),
    }
    log.info("Extraction done: %s", stats)
    return stats
