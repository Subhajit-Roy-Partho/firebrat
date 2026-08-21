"""Response models for the API (lightweight view of manifest)."""
from typing import Optional
from pydantic import BaseModel

class BookSummary(BaseModel):
    book_id: str
    title: str
    author: str = ""
    total_duration_ms: int = 0
    section_count: int = 0
    size_bytes: int = 0
    updated_at: str = ""  # isoformat from manifest generated_at

class HealthResponse(BaseModel):
    status: str = "ok"
