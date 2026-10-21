"""Unpack a user-uploaded .zip of PDFs and merge them into one source PDF.

A zip upload is just a transport for one or more PDFs (e.g. per-chapter
files). The conversion pipeline itself only ever sees a single PDF, so
this helper normalizes a zip into exactly that: every `*.pdf` entry,
sorted by archive path for deterministic chapter order, concatenated
page-by-page into `dest_pdf_path`.

Security: entries with absolute paths or `..` segments are rejected
(zip-slip), and non-PDF entries are ignored (a zip with no PDFs at all
is a 400, reported by the caller).
"""
import os
import zipfile


def list_pdfs_in_zip(zip_path: str) -> list[str]:
    """PDF entry names inside the zip, sorted for deterministic order."""
    with zipfile.ZipFile(zip_path, "r") as z:
        names = [n for n in z.namelist()
                 if n.lower().endswith(".pdf") and not n.endswith("/")]
    names.sort()
    return names


def merge_zip_pdfs_to_pdf(zip_path: str, dest_pdf_path: str) -> tuple[str, int]:
    """Merge all PDFs in `zip_path` into `dest_pdf_path`.

    Returns (merged_from_description, page_count). Raises ValueError on a
    bad zip / no PDFs / unsafe entries, RuntimeError when no PDF backend
    is importable.
    """
    if not zipfile.is_zipfile(zip_path):
        raise ValueError("uploaded file is not a valid .zip archive")
    with zipfile.ZipFile(zip_path, "r") as z:
        for info in z.infolist():
            # Zip-slip guard: nothing may escape the extraction temp dir.
            if info.filename.startswith(("/", "\\")) or ".." in info.filename.split("/"):
                raise ValueError(f"unsafe entry in zip: {info.filename!r}")
        pdf_names = [n for n in z.namelist()
                     if n.lower().endswith(".pdf") and not n.endswith("/")]
        pdf_names.sort()
        if not pdf_names:
            raise ValueError("zip contains no .pdf files — add at least one PDF")
        # Single-PDF zips are the common "I zipped my book" case: extract
        # directly with stdlib only, no PDF backend needed.
        if len(pdf_names) == 1:
            with open(dest_pdf_path, "wb") as out:
                out.write(z.read(pdf_names[0]))
            from_name = pdf_names[0]
        else:
            import tempfile
            tmpdir = tempfile.mkdtemp(prefix="firebrat_zip_")
            extracted: list[str] = []
            try:
                for n in pdf_names:
                    target = os.path.join(tmpdir, os.path.basename(n) or "chapter.pdf")
                    # Same basename twice (ch1/ch.pdf, ch2/ch.pdf) — disambiguate.
                    base, k = target, 2
                    while os.path.exists(target):
                        stem, ext = os.path.splitext(base)
                        target = f"{stem}-{k}{ext}"
                        k += 1
                    with open(target, "wb") as out:
                        out.write(z.read(n))
                    extracted.append(target)
                _concat_pdfs(extracted, dest_pdf_path)
            finally:
                for p in extracted:
                    try:
                        os.remove(p)
                    except OSError:
                        pass
                try:
                    os.rmdir(tmpdir)
                except OSError:
                    pass
            from_name = f"{len(pdf_names)} PDFs"
    return from_name, len(pdf_names)


def _concat_pdfs(src_paths: list[str], dest_path: str) -> None:
    """Concatenate PDFs in order. pypdf first, PyMuPDF as fallback."""
    try:
        from pypdf import PdfReader, PdfWriter
    except ImportError:
        try:
            import fitz  # PyMuPDF (extract env)
        except ImportError as e:
            raise RuntimeError(
                "merging a multi-PDF zip needs pypdf (serve env) or pymupdf — "
                "install one and retry") from e
        else:
            merged = fitz.open()
            for p in src_paths:
                with fitz.open(p) as doc:
                    merged.insert_pdf(doc)
            merged.save(dest_path)
            merged.close()
            return
    writer = PdfWriter()
    for p in src_paths:
        reader = PdfReader(p)
        for page in reader.pages:
            writer.add_page(page)
    with open(dest_path, "wb") as out:
        writer.write(out)
