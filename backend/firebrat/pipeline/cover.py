"""Front cover for PDF books: page 1, when it looks like a cover.

A cover page has almost no running text (a title and maybe an author), whereas
a first page of body text or a table of contents has plenty. Only the former is
used, so a textbook that opens straight into chapter 1 keeps the generated cover.
The app shows cover.png/jpg/webp from the package root.
"""
import logging
import os

log = logging.getLogger(__name__)
MAX_COVER_TEXT_CHARS = 150
_COVER_HEIGHT_PX = 1000


def looks_like_cover(first_page_text):
    return len((first_page_text or "").strip()) < MAX_COVER_TEXT_CHARS


def render_pdf_cover(pdf_path, pkg_dir, first_page_text):
    """Writes <pkg_dir>/cover.png when page 1 looks like a cover. Returns the path or None.
    Never raises: a cover is cosmetic."""
    if not looks_like_cover(first_page_text):
        return None
    try:
        import pymupdf  # type: ignore
        doc = pymupdf.open(pdf_path)
        try:
            page = doc[0]
            scale = _COVER_HEIGHT_PX / max(page.rect.height, 1)
            pix = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), alpha=False)
            out = os.path.join(pkg_dir, "cover.png")
            pix.save(out)
            return out
        finally:
            doc.close()
    except Exception as exc:
        log.warning("Could not render a cover from %s: %s", pdf_path, exc)
        return None
