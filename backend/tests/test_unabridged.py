"""Regression tests for the unabridged-narration fix.

Stage-2 narration used to read like a SUMMARY (prompt asked for "1-3
logical sections" with no requirement to cover all source text, so any LLM
condensed ~10 pages into a few paragraphs). The prompt must now demand
complete coverage and forbid summarising. The JSON schema itself is
unchanged — these tests pin both halves of that contract.
"""
import os
import re

from firebrat.pipeline.compile_llm import SYSTEM_PROMPT
from firebrat.pipeline.schema import LLMOutput

_MOBILE_PROMPT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "mobile-Backend", "lib", "src", "compilation", "prompt.dart",
)


def _mobile_prompt() -> str:
    with open(_MOBILE_PROMPT_PATH, "r", encoding="utf-8") as f:
        return f.read()


def test_prompt_demands_complete_coverage():
    p = SYSTEM_PROMPT.lower()
    assert "complete" in p
    assert "unabridged" in p
    assert "cover every" in p  # every concept/example/derivation/caveat
    assert "document order" in p


def test_prompt_forbids_summarizing():
    p = SYSTEM_PROMPT.lower()
    assert "forbidden" in p
    assert "summariz" in p
    assert "condens" in p
    # Must name the specific condensing behaviours, not just wave at them.
    assert "minor" in p
    assert "merging distinct ideas" in p


def test_prompt_section_cap_removed():
    assert "1-3 logical sections" not in SYSTEM_PROMPT
    # Raised allowance for a ~10-page chunk (was capped at 3).
    assert re.search(r"up to ~?8 sections", SYSTEM_PROMPT) is not None
    assert "no 1-3 section cap" in SYSTEM_PROMPT


def test_prompt_has_coverage_self_check():
    p = SYSTEM_PROMPT.lower()
    assert "coverage self-check" in p
    assert "do not advance to the next section" in p
    assert "source_pages" in SYSTEM_PROMPT  # self-check is keyed to source_pages
    assert "every numbered point" in p


def test_prompt_keeps_schema_and_existing_rules():
    # JSON schema block identical — downstream validators must keep working.
    for token in ("\"sections\"", "\"source_pages\"", "\"segments\"",
                  "figure_callout", "formula_callout", "table_callout",
                  "\"latex\"", "visually_essential"):
        assert token in SYSTEM_PROMPT, f"schema token lost from prompt: {token}"
    # Pre-existing rules preserved.
    assert "ONE sentence/utterance" in SYSTEM_PROMPT
    assert "no markdown, no LaTeX syntax" in SYSTEM_PROMPT
    assert "author real LaTeX" in SYSTEM_PROMPT
    assert "bibliography" in SYSTEM_PROMPT.lower()


def test_mobile_prompt_matches():
    dart = _mobile_prompt()
    assert "buildSystemPrompt" in dart
    low = dart.lower()
    for token in ("complete", "unabridged", "cover every", "forbidden",
                  "summariz", "condens", "coverage self-check",
                  "do not advance to the next section"):
        assert token in low, f"mobile prompt missing: {token}"
    assert "1-3 logical sections" not in dart
    assert re.search(r"up to ~?8 sections", dart) is not None


def test_unabridged_sample_validates_against_unchanged_schema():
    """A hand-written sample of the NEW expected shape — 4 sections for one
    chunk (over the old 1-3 cap), every concept/example/equation its own
    segment — must pass the unchanged pydantic schema, proving the schema
    still accepts unabridged output."""
    raw = {
        "sections": [
            {"title": "Clock Sources", "source_pages": [40, 41],
             "segments": [
                 {"type": "heading", "text": "Clock Sources",
                  "ref": None, "latex": None, "visually_essential": False},
                 {"type": "prose",
                  "text": "The microcontroller can run from an internal RC oscillator for low cost designs.",
                  "ref": None, "latex": None, "visually_essential": False},
                 {"type": "prose",
                  "text": "An external crystal gives tighter frequency tolerance when timing accuracy matters.",
                  "ref": None, "latex": None, "visually_essential": False},
             ]},
            {"title": "Clock Period Derivation", "source_pages": [42, 43],
             "segments": [
                 {"type": "prose",
                  "text": "With a one hundred megahertz system clock the period is ten nanoseconds.",
                  "ref": None, "latex": None, "visually_essential": False},
                 {"type": "formula_callout",
                  "text": "The clock period capital T equals one over the frequency f.",
                  "ref": None, "latex": "T = \\frac{1}{f}", "visually_essential": False},
             ]},
            {"title": "Worked Example", "source_pages": [44, 45],
             "segments": [
                 {"type": "prose",
                  "text": "Consider a peripheral divider of four applied to the system clock.",
                  "ref": None, "latex": None, "visually_essential": False},
                 {"type": "formula_callout",
                  "text": "The peripheral clock equals the system clock divided by four.",
                  "ref": None, "latex": "f_{p} = \\frac{f_{sys}}{4}",
                  "visually_essential": False},
             ]},
            {"title": "Caveats", "source_pages": [46, 47, 48, 49],
             "segments": [
                 {"type": "prose",
                  "text": "Switching clock sources at runtime requires waiting for the new source to stabilise.",
                  "ref": None, "latex": None, "visually_essential": False},
                 {"type": "prose",
                  "text": "Brownout during the switch can leave the core clocked from an unknown source.",
                  "ref": None, "latex": None, "visually_essential": True},
             ]},
        ]
    }
    out = LLMOutput.model_validate(raw)
    assert len(out.sections) == 4  # over the old 1-3 cap — must still validate
    assert out.validate_refs(set()) == []
    total_segments = sum(len(s.segments) for s in out.sections)
    assert total_segments == 9
    assert sum(1 for s in out.sections for g in s.segments
               if g.type == "formula_callout") == 2
