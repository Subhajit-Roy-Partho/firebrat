"""Stage 1: hybrid marker + PyMuPDF extraction → raw_pages.json + assets.

This runs under a tight (~6GB) memory budget (a shared SLURM allocation),
and marker's layout/OCR models batch-process every page of whatever PDF
they're given at once — so for a large book this module is always invoked
per small page-range batch (see extract_batch_cli.py), each batch run as
its own subprocess so memory is fully released before the next batch starts.
run_extraction() still supports whole-file single-shot use for small PDFs
(e.g. the --pages testing flag in convert.py).
"""
import json
import logging
import os
import re
import shutil

from firebrat.utils.ids import (
    make_figure_id, make_formula_id, make_table_id, sanitize_book_id,
)
from firebrat.utils.pdf_utils import get_page_count

log = logging.getLogger(__name__)

LATEX_INLINE_RE = re.compile(r"\$(.+?)\$")


def _try_marker(pdf_path: str):
    """Run marker's PdfConverter and return (markdown_text, images_dict, json_blocks) or None."""
    try:
        from marker.converters.pdf import PdfConverter
        from marker.models import create_model_dict
        converter = PdfConverter(artifact_dict=create_model_dict())
        rendered = converter(pdf_path)
        try:
            from marker.output import text_from_rendered
            md, id_map, images = text_from_rendered(rendered)
        except ImportError:
            md = getattr(rendered, "markdown", "") or str(rendered)
            images = getattr(rendered, "images", {}) or {}
            id_map = {}
        blocks = None
        try:
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


def extract_pages(
    pdf_path: str,
    pkg_dir: str,
    page_offset: int = 0,
    fig_start: int = 1,
    tbl_start: int = 1,
    formula_start: int = 1,
) -> dict:
    """Extract every page of pdf_path (a full book or an already-trimmed batch),
    writing assets into pkg_dir/assets/*, with global page indices and id
    counters offset by the given starting values (for batched, multi-subprocess
    extraction of a larger book).

    Returns {"pages": [...], "next_fig": int, "next_tbl": int, "next_formula": int,
             "marker_chars": int}. Does NOT write raw_pages.json — caller merges
    batches and writes the combined file.
    """
    assets_dir = os.path.join(pkg_dir, "assets")
    pages_img_dir = os.path.join(assets_dir, "pages")
    figures_dir = os.path.join(assets_dir, "figures")
    tables_dir = os.path.join(assets_dir, "tables")
    formulas_dir = os.path.join(assets_dir, "formulas")
    for d in (pages_img_dir, figures_dir, tables_dir, formulas_dir):
        os.makedirs(d, exist_ok=True)

    local_page_count = get_page_count(pdf_path)
    log.info("Extracting %s (%d local pages, global offset %d)", pdf_path, local_page_count, page_offset)

    marker_result = _try_marker(pdf_path)
    marker_md: str = ""
    marker_images: dict = {}
    if marker_result is not None:
        marker_md, marker_images, _blocks = marker_result
        raw_dir = os.path.join(pkg_dir, "raw")
        os.makedirs(raw_dir, exist_ok=True)
        with open(os.path.join(raw_dir, "marker.md"), "a", encoding="utf-8") as f:
            f.write(marker_md + "\n\n")

    for idx, (key, pil_img) in enumerate((marker_images or {}).items()):
        try:
            fname = f"marker_{page_offset:04d}_{idx:04d}.png"
            out = os.path.join(assets_dir, "marker_images", fname)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            if hasattr(pil_img, "save"):
                pil_img.save(out)
            else:
                shutil.copy(str(pil_img), out)
        except Exception as e:
            log.debug("Failed to save marker image %s: %s", key, e)

    import pymupdf  # type: ignore
    doc = pymupdf.open(pdf_path)
    raw_pages: list[dict] = []
    fig_counter = fig_start - 1
    tbl_counter = tbl_start - 1
    formula_counter = formula_start - 1

    for local_idx in range(local_page_count):
        page_idx = page_offset + local_idx
        page = doc[local_idx]
        page_img_name = f"page_{page_idx+1:04d}.png"
        page_img_path = os.path.join(pages_img_dir, page_img_name)
        try:
            pix = page.get_pixmap(dpi=150)
            pix.save(page_img_path)
            pix = None
        except Exception as e:
            log.warning("Failed to render page %d: %s", page_idx, e)

        page_text = page.get_text("text") or ""
        page_figures: list[dict] = []
        page_tables: list[dict] = []
        page_formulas: list[dict] = []

        try:
            for img_idx, img_info in enumerate(page.get_images(full=True)):
                xref = img_info[0]
                try:
                    pix2 = pymupdf.Pixmap(doc, xref)
                    if pix2.w < 80 or pix2.h < 80:
                        pix2 = None
                        continue
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

        for m in LATEX_INLINE_RE.finditer(page_text):
            latex = m.group(1).strip()
            if len(latex) < 4 or len(latex) > 600:
                continue
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
            "markdown": "",
            "figures": page_figures,
            "tables": page_tables,
            "formulas": page_formulas,
        })

    doc.close()

    return {
        "pages": raw_pages,
        "next_fig": fig_counter + 1,
        "next_tbl": tbl_counter + 1,
        "next_formula": formula_counter + 1,
        "marker_chars": len(marker_md),
    }


def run_extraction(pdf_path: str, output_dir: str, book_id: str | None = None) -> dict:
    """Single-shot extraction of an entire (small) PDF — writes raw_pages.json
    directly. Used for --pages testing and any book small enough to fit the
    memory budget in one marker call. Large books use the batched path in
    convert.py instead (extract_pages() + extract_batch_cli.py per range).
    """
    book_id = book_id or sanitize_book_id(pdf_path)
    pkg_dir = os.path.join(output_dir, book_id) if os.path.basename(output_dir) != book_id else output_dir
    raw_dir = os.path.join(pkg_dir, "raw")
    os.makedirs(raw_dir, exist_ok=True)

    result = extract_pages(pdf_path, pkg_dir)
    raw_pages = result["pages"]

    raw_out = {
        "book_id": book_id,
        "source_pdf": os.path.basename(pdf_path),
        "page_count": len(raw_pages),
        "pages": raw_pages,
    }
    from firebrat.pipeline.schema import RawPagesFile
    RawPagesFile.model_validate(raw_out)

    out_json = os.path.join(raw_dir, "raw_pages.json")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(raw_out, f, ensure_ascii=False, indent=2)

    stats = {
        "book_id": book_id,
        "package_dir": pkg_dir,
        "raw_pages_json": out_json,
        "page_count": len(raw_pages),
        "figure_count": result["next_fig"] - 1,
        "formula_count": result["next_formula"] - 1,
        "marker_chars": result["marker_chars"],
    }
    log.info("Extraction done: %s", stats)
    return stats
