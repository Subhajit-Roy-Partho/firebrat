"""Pydantic schemas shared across extraction → LLM → TTS → manifest → API."""
from __future__ import annotations
from typing import Literal, Optional
from pydantic import BaseModel, Field, field_validator
import re

SegmentType = Literal["heading", "prose", "figure_callout", "formula_callout", "table_callout"]

_ID_RE = re.compile(r"^(fig|formula|tbl)_\d{4}$")

# ── Stage 1 raw assets ────────────────────────────────────────────
class RawFigure(BaseModel):
    figure_id: str
    page: int  # 0-based
    caption: str = ""
    image_path: str = ""  # relative to book package root
    bbox: list[float] | None = None
    width: int | None = None
    height: int | None = None

class RawTable(BaseModel):
    table_id: str
    page: int
    caption: str = ""
    image_path: str = ""
    bbox: list[float] | None = None

class RawFormula(BaseModel):
    formula_id: str
    page: int
    latex: str
    image_path: str = ""
    spoken_text: str = ""       # filled later (LLM or fallback)
    visually_essential: bool = False

class RawPage(BaseModel):
    page_idx: int
    text: str = ""
    markdown: str = ""
    figures: list[RawFigure] = Field(default_factory=list)
    tables: list[RawTable] = Field(default_factory=list)
    formulas: list[RawFormula] = Field(default_factory=list)

class RawPagesFile(BaseModel):
    book_id: str
    source_pdf: str
    page_count: int
    pages: list[RawPage]

# ── Stage 2 LLM compilation output (pre-timestamps) ───────────────
class LLMSegment(BaseModel):
    type: SegmentType
    text: str = Field(min_length=1)
    ref: str | None = None
    latex: str | None = None  # LLM-authored LaTeX for formula_callout; our code mints the formula_id
    visually_essential: bool = False

    @field_validator("ref")
    @classmethod
    def ref_must_be_known_id_or_null(cls, v):
        if v is None:
            return v
        if not _ID_RE.match(v):
            raise ValueError(f"ref must match fig/formula/tbl_NNNN, got {v!r}")
        return v

class LLMSection(BaseModel):
    title: str = Field(min_length=1)
    source_pages: list[int] = Field(default_factory=list)
    segments: list[LLMSegment] = Field(min_length=1)

class LLMOutput(BaseModel):
    sections: list[LLMSection] = Field(min_length=1)

    def validate_refs(self, known_ids: set[str]) -> list[str]:
        """Return list of error strings for refs that don't resolve."""
        errs = []
        for si, sec in enumerate(self.sections):
            for j, seg in enumerate(sec.segments):
                if seg.ref is not None and seg.ref not in known_ids:
                    errs.append(f"sections[{si}].segments[{j}].ref={seg.ref!r} not in known ids")
        return errs

# ── Stage 3 timed segments ────────────────────────────────────────
class TimedSegment(BaseModel):
    segment_id: str
    index: int
    type: SegmentType
    text: str
    ref: str | None = None
    start_ms: int = Field(ge=0)
    end_ms: int = Field(ge=0)
    visually_essential: bool = False

    @field_validator("end_ms")
    @classmethod
    def end_after_start(cls, v, info):
        if "start_ms" in info.data and v < info.data["start_ms"]:
            raise ValueError("end_ms must be >= start_ms")
        return v

class SegmentsFile(BaseModel):
    section_id: str
    sample_rate: int = 24000
    pause_ms_between_segments: int = 220
    segments: list[TimedSegment]

# ── Manifest ──────────────────────────────────────────────────────
class ManifestNarratorVoice(BaseModel):
    engine: str = "chatterbox-tts"
    model_class: str = "ChatterboxTTS"
    reference_clip: str | None = None
    exaggeration: float = 0.4
    cfg_weight: float = 0.5
    sample_rate: int = 24000

class ManifestAudioFormat(BaseModel):
    codec: str = "aac"
    container: str = "m4a"
    sample_rate: int = 24000
    channels: int = 1
    fallback_codec: str = "mp3"

class ManifestFigure(BaseModel):
    figure_id: str
    caption: str = ""
    image_path: str
    page: int
    width: int | None = None
    height: int | None = None

class ManifestFormula(BaseModel):
    formula_id: str
    latex: str
    image_path: str
    spoken_text: str = ""
    visually_essential: bool = False
    page: int

class ManifestTable(BaseModel):
    table_id: str
    caption: str = ""
    image_path: str
    page: int

class ManifestSection(BaseModel):
    section_id: str
    chapter: int | None = None
    order: int
    title: str
    audio_path: str
    segments_path: str
    duration_ms: int
    figure_refs: list[str] = Field(default_factory=list)
    formula_refs: list[str] = Field(default_factory=list)
    table_refs: list[str] = Field(default_factory=list)
    needs_review: bool = False
    # 0-based PDF page indices behind this section (from compiled.json's
    # source_pages). Optional/additive — old packages simply have [].
    source_pages: list[int] = Field(default_factory=list)

class Manifest(BaseModel):
    schema_version: str = "1.0"
    book_id: str
    title: str
    author: str = ""
    source_pdf: str
    # Package-relative path to the embedded source PDF (e.g. "source.pdf"),
    # or None when the package predates source-PDF embedding. Optional/
    # additive — old packages omit it and keep working.
    source_pdf_path: str | None = None
    generated_at: str  # ISO8601
    pipeline_version: str = "0.1.0"
    narrator_voice: ManifestNarratorVoice = Field(default_factory=ManifestNarratorVoice)
    audio_format: ManifestAudioFormat = Field(default_factory=ManifestAudioFormat)
    total_duration_ms: int = 0
    sections: list[ManifestSection] = Field(default_factory=list)
    figures: list[ManifestFigure] = Field(default_factory=list)
    formulas: list[ManifestFormula] = Field(default_factory=list)
    tables: list[ManifestTable] = Field(default_factory=list)
