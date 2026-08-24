"""Stage 1: hybrid marker + PyMuPDF extraction → raw_pages.json + assets.

This runs under a tight (~6GB) memory budget (a shared SLURM allocation),
and marker's layout/OCR models batch-process every page of whatever PDF
they're given at once — so for a large book this module is always invoked
per small page-range batch (see extract_batch_cli.py), each batch run as
its own subprocess so memory is fully released before the next batch starts.
run_extraction() still supports whole-file single-shot use for small PDFs
(e.g. the --pages testing flag in convert.py).

Figures and tables come from marker's own layout-detected blocks (Figure/
Picture/Table, each cropped via that block's own get_image(), with sibling
Caption blocks for real caption text) — NOT from a naive PyMuPDF
page.get_images() scrape. That distinction matters a lot in practice: a
raw-image scrape only finds embedded raster images and misses anything
vector-drawn (circuit diagrams, logic gates, waveforms — most of a typical
technical book's figures), and it has no concept of tables at all. An
earlier version of this module did exactly that naive scrape, with an
always-empty page_tables list nothing ever populated — confirmed against
two real converted books (arm-fundamentals-soc, digital-design-and-
computer-architecture) both showing zero tables and a suspiciously low
figure count in raw_pages.json. See TASK.md for the fix writeup.
"""
import json
import logging
import os
import re

from firebrat.utils.ids import (
    make_figure_id, make_formula_id, make_table_id, sanitize_book_id,
)
from firebrat.utils.pdf_utils import get_page_count

log = logging.getLogger(__name__)

LATEX_INLINE_RE = re.compile(r"\$(.+?)\$")

# Block types that wrap a content block + its caption as siblings, and the
# content block type each wrapper actually holds.
_GROUP_CONTENT_TYPE = {
    "FigureGroup": "Figure",
    "PictureGroup": "Picture",
    "TableGroup": "Table",
}
_CONTENT_BLOCK_TYPES = {"Figure", "Picture", "Table"}
# Never worth descending into — leaves or already-consumed-by-parent structure.
_SKIP_BLOCK_TYPES = {"Line", "Span", "TableCell"}


def _build_marker_document(pdf_path: str):
    """Runs marker's full layout+OCR+table-recognition pipeline and returns
    its Document object (real structured blocks), or None if marker itself
    fails — in which case the caller gets no figures/tables for this batch
    rather than a silently degraded partial result.
    """
    try:
        from marker.converters.pdf import PdfConverter
        from marker.models import create_model_dict
        converter = PdfConverter(artifact_dict=create_model_dict())
        document = converter.build_document(pdf_path)
        log.info("Marker succeeded: %d pages", len(document.pages))
        return document
    except Exception as e:
        log.warning("Marker failed, figures/tables will be empty for this batch: %s", e, exc_info=True)
        return None


def _block_children(block, document):
    """A block's children, resolved from `.structure` (a list of block ids)
    if `.children` isn't already populated — marker's raw Document blocks
    use `.structure`; only the render-time BlockOutput tree (which this
    module doesn't use) populates `.children` directly."""
    children = getattr(block, "children", None)
    if children:
        return children
    structure = getattr(block, "structure", None)
    if not structure:
        return []
    resolved = []
    for block_id in structure:
        child = document.get_block(block_id)
        if child is not None:
            resolved.append(child)
    return resolved


def _find_visuals_on_page(page, document):
    """Walks one marker page's block tree, returning
    [(content_block, caption_block_or_None), ...] for every Figure/
    Picture/Table found — pairing each with its sibling Caption when the
    content is wrapped in a *Group block (the normal case for figures;
    tables are sometimes bare, with their title as the first line of their
    own text instead of a separate Caption block).

    Deduplicates by block id: marker's tree can reach the same content
    block via more than one structural path (seen in practice — a Table
    inside a TableGroup that's itself reachable as a bare top-level Table
    too), and without a guard the same figure/table gets emitted, saved,
    and cataloged twice. When two occurrences of the same id disagree on
    whether a caption was found, the captioned one wins — a plain "first
    occurrence wins" guard was observed dropping a real caption whenever
    the uncaptioned path happened to be visited first.
    """
    by_id: dict = {}

    def consider(content, caption):
        existing = by_id.get(content.id)
        if existing is None or (existing[1] is None and caption is not None):
            by_id[content.id] = (content, caption)

    def visit(block):
        block_type = str(block.block_type)
        if block_type in _GROUP_CONTENT_TYPE:
            children = _block_children(block, document)
            content = next((c for c in children if str(c.block_type) == _GROUP_CONTENT_TYPE[block_type]), None)
            caption = next((c for c in children if str(c.block_type) == "Caption"), None)
            if content is not None:
                consider(content, caption)
            return
        if block_type in _CONTENT_BLOCK_TYPES:
            consider(block, None)
            return
        if block_type in _SKIP_BLOCK_TYPES:
            return
        for child in _block_children(block, document):
            visit(child)

    for top in _block_children(page, document):
        visit(top)
    return list(by_id.values())


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

    document = _build_marker_document(pdf_path)
    marker_pages_by_idx = {p.page_id: p for p in document.pages} if document is not None else {}
    marker_chars = 0

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

        marker_page = marker_pages_by_idx.get(local_idx)
        if marker_page is not None:
            for content_block, caption_block in _find_visuals_on_page(marker_page, document):
                block_type = str(content_block.block_type)
                try:
                    caption_text = caption_block.raw_text(document).strip() if caption_block is not None else ""
                    if block_type == "Table":
                        # Tables rarely have a separate Caption sibling — their
                        # own text (title + cell contents) carries the real
                        # content, which matters far more here than for a
                        # figure: this is what lets the compilation LLM
                        # actually narrate what's in the table instead of
                        # just gesturing at "a table" with no data.
                        table_text = content_block.raw_text(document).strip()
                        caption_text = (caption_text + "\n" + table_text).strip() if caption_text else table_text

                    image = content_block.get_image(document, highres=True)
                    if image is None:
                        continue
                    width, height = image.size
                    if width < 40 or height < 40:
                        continue  # near-empty crop, not worth keeping

                    if block_type == "Table":
                        tbl_counter += 1
                        tid = make_table_id(tbl_counter)
                        fname = f"{tid}.png"
                        image.save(os.path.join(tables_dir, fname))
                        page_tables.append({
                            "table_id": tid,
                            "page": page_idx,
                            "caption": caption_text[:2000],  # keep the LLM prompt from ballooning on a giant table
                            "image_path": os.path.join("assets/tables", fname),
                        })
                    else:
                        fig_counter += 1
                        fid = make_figure_id(fig_counter)
                        fname = f"{fid}.png"
                        image.save(os.path.join(figures_dir, fname))
                        page_figures.append({
                            "figure_id": fid,
                            "page": page_idx,
                            "caption": caption_text,
                            "image_path": os.path.join("assets/figures", fname),
                            "width": width, "height": height,
                        })
                except Exception as e:
                    log.warning("Visual block extract failed page %d (%s): %s", page_idx, block_type, e)

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
        "marker_chars": marker_chars,
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
