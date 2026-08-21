"""Stable id helpers."""
import hashlib
import os
import re

def sanitize_book_id(pdf_path: str) -> str:
    stem = os.path.splitext(os.path.basename(pdf_path))[0]
    stem = re.sub(r"[^a-zA-Z0-9_-]+", "-", stem).strip("-").lower()
    return stem or "book"

def make_figure_id(n: int) -> str:
    return f"fig_{n:04d}"

def make_formula_id(n: int) -> str:
    return f"formula_{n:04d}"

def make_table_id(n: int) -> str:
    return f"tbl_{n:04d}"

def make_section_id(n: int) -> str:
    return f"sec_{n:04d}"

def make_segment_id(section_id: str, idx: int) -> str:
    # 1-based human ids
    return f"{section_id}_seg_{idx+1:03d}"

def short_hash(text: str, length: int = 8) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:length]
