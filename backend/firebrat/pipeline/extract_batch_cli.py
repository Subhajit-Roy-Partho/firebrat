#!/usr/bin/env python3
"""Runs Stage-1 extraction for ONE page-range batch, as a standalone process.

Invoked as a subprocess per batch (see convert.py) so marker's per-call
memory usage never accumulates across the whole book — this session's SLURM
allocation caps total RAM at 6GB, and marker batch-processes every page of
whatever PDF it's given at once.

Usage:
  python extract_batch_cli.py <pdf_path> <pkg_dir> <start_page> <num_pages> \
      <fig_start> <tbl_start> <formula_start> <out_json>

Writes out_json = {"pages": [...], "next_fig": int, "next_tbl": int,
                    "next_formula": int, "marker_chars": int}
"""
import json
import logging
import os
import sys
import tempfile

_BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _BACKEND_DIR not in sys.path:
    sys.path.insert(0, _BACKEND_DIR)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("extract_batch")


def main():
    if len(sys.argv) != 9:
        print(__doc__)
        sys.exit(2)
    pdf_path, pkg_dir, start_page, num_pages, fig_start, tbl_start, formula_start, out_json = sys.argv[1:]
    start_page = int(start_page)
    num_pages = int(num_pages)
    fig_start = int(fig_start)
    tbl_start = int(tbl_start)
    formula_start = int(formula_start)

    import pymupdf
    from firebrat.pipeline.extract import extract_pages

    src = pymupdf.open(pdf_path)
    end_page = min(start_page + num_pages, len(src))
    tmp_pdf = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
    tmp_pdf.close()
    dst = pymupdf.open()
    dst.insert_pdf(src, from_page=start_page, to_page=end_page - 1)
    dst.save(tmp_pdf.name)
    dst.close()
    src.close()

    try:
        result = extract_pages(
            tmp_pdf.name, pkg_dir,
            page_offset=start_page,
            fig_start=fig_start, tbl_start=tbl_start, formula_start=formula_start,
        )
    finally:
        try:
            os.remove(tmp_pdf.name)
        except OSError:
            pass

    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)
    log.info("Batch [%d, %d) done: %d pages, next_fig=%d next_tbl=%d next_formula=%d",
              start_page, end_page, len(result["pages"]), result["next_fig"], result["next_tbl"], result["next_formula"])


if __name__ == "__main__":
    main()
