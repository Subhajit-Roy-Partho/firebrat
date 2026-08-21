"""PyMuPDF helpers — no marker dependency here."""
import os
from typing import List


def get_page_count(pdf_path: str) -> int:
    import pymupdf
    doc = pymupdf.open(pdf_path)
    n = len(doc)
    doc.close()
    return n


def render_page_png(pdf_path: str, page_idx: int, out_path: str, dpi: int = 160) -> str:
    import pymupdf
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    doc = pymupdf.open(pdf_path)
    try:
        pix = doc[page_idx].get_pixmap(dpi=dpi)
        pix.save(out_path)
    finally:
        doc.close()
    return out_path


def crop_to_png(pdf_path: str, page_idx: int, bbox, out_path: str, dpi: int = 300) -> str:
    """bbox = (x0, y0, x1, y1) in PDF points. Crops then rasterizes."""
    import pymupdf
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    doc = pymupdf.open(pdf_path)
    try:
        rect = pymupdf.Rect(*bbox)
        pix = doc[page_idx].get_pixmap(dpi=dpi, clip=rect)
        pix.save(out_path)
    finally:
        doc.close()
    return out_path


def extract_text_blocks(pdf_path: str, page_idx: int) -> List[dict]:
    """Raw text blocks with bbox — fallback when marker text is insufficient."""
    import pymupdf
    doc = pymupdf.open(pdf_path)
    try:
        page = doc[page_idx]
        blocks = page.get_text("blocks")  # (x0,y0,x1,y1, text, block_no, block_type)
        return [
            {"bbox": [b[0], b[1], b[2], b[3]], "text": b[4], "block_no": b[5], "block_type": b[6]}
            for b in blocks
        ]
    finally:
        doc.close()
