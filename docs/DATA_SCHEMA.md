# Data Schemas

Source of truth: `backend/firebrat/pipeline/schema.py` (pydantic models). This doc mirrors it in prose + examples — if they ever disagree, the code is right and this file is stale.

## id conventions

| id | pattern | minted by |
|---|---|---|
| figure | `fig_NNNN` (4-digit, 1-based) | Stage 1 extraction (`utils/ids.py`) |
| table | `tbl_NNNN` | Stage 1 extraction |
| formula | `formula_NNNN` | Stage 2 compilation, from LLM-authored LaTeX (see `docs/ARCHITECTURE.md`) |
| section | `sec_NNNN` | Stage 2 compilation |
| segment | `{section_id}_seg_NNN` (3-digit, 1-based within its section) | Stage 2/3 |

**The LLM never assigns any of these ids.** For figures/tables it must reference an id from a catalog it's given. For formulas it supplies LaTeX text and our code mints the id afterward. This is deliberate — it removes an entire class of hallucination/mismatch bugs where the model invents a plausible-looking id that doesn't correspond to any real asset.

## `manifest.json` (one per book, at the package root)

```json
{
  "schema_version": "1.0",
  "book_id": "arm-fundamentals-soc",
  "title": "Fundamentals of System-on-Chip Design on Arm Cortex-M Microcontrollers",
  "author": "",
  "source_pdf": "arm-fundamentals-soc.pdf",
  "generated_at": "2026-08-21T02:15:00Z",
  "pipeline_version": "0.1.0",
  "narrator_voice": {
    "engine": "chatterbox-tts",
    "model_class": "ChatterboxTTS",
    "reference_clip": "backend/voice/narrator_ref.wav",
    "exaggeration": 0.28,
    "cfg_weight": 0.45,
    "sample_rate": 24000
  },
  "audio_format": {
    "codec": "aac", "container": "m4a",
    "sample_rate": 24000, "channels": 1, "fallback_codec": "mp3"
  },
  "total_duration_ms": 26496000,
  "source_pdf_path": "source.pdf",
  "sections": [
    {
      "section_id": "sec_0001",
      "chapter": null,
      "order": 1,
      "title": "Synchronous DRAM (SDRAM)",
      "audio_path": "sections/sec_0001/audio.m4a",
      "segments_path": "sections/sec_0001/segments.json",
      "duration_ms": 87200,
      "figure_refs": ["fig_0001"],
      "formula_refs": ["formula_0001"],
      "table_refs": [],
      "needs_review": false,
      "source_pages": [45, 46]
    }
  ],
  "figures": [
    {"figure_id": "fig_0001", "caption": "", "image_path": "assets/figures/fig_0001.png", "page": 45, "width": 1600, "height": 900}
  ],
  "formulas": [
    {
      "formula_id": "formula_0001",
      "latex": "t_{CK} = \\frac{1}{f} = 10\\,\\text{ns}",
      "image_path": "assets/formulas/formula_0001.png",
      "spoken_text": "The clock period tCK equals one over the frequency f, which is 10 nanoseconds.",
      "visually_essential": false,
      "page": 5
    }
  ],
  "tables": [
    {"table_id": "tbl_0001", "caption": "", "image_path": "assets/tables/tbl_0001.png", "page": 30}
  ]
}
```

All `*_path` fields are relative to the package root, and directly usable as `GET /books/{id}/assets/{path}` suffixes or as local file paths once the package is downloaded and extracted on-device.

## Source PDF (`source_pdf_path` + `source_pages`)

`schema_version` stays `1.0` — these fields are purely additive, and old
packages without them still parse everywhere (backend pydantic models default
them; the Flutter/mobile readers treat them as nullable/with-defaults):

- Manifest-level `source_pdf_path: "source.pdf" | null` — relative path of
  the original input PDF shipped at the package root (copied there by
  `build_manifest` during conversion, or by
  `backend/scripts/backfill_source_pdf.py` for older packages). `null` (or
  absent) means the package predates this feature. No new route was needed:
  `source.pdf` is served by the existing `GET /books/{id}/assets/source.pdf`
  and included in the existing `GET /books/{id}/download` zip, both of which
  operate over the whole package dir.
- Per-section `source_pages: list[int]` (default `[]`) — 0-based PDF page
  indices the section was narrated from, copied verbatim from Stage 2's
  `compiled.json`. The reader opens the local `source.pdf` at
  `source_pages[0] + 1` (the viewer is 1-based) and hides the "Source page"
  button when the path is null, the file is missing locally, or the list is
  empty.

## `sections/{id}/segments.json`

```json
{
  "section_id": "sec_0003",
  "sample_rate": 24000,
  "pause_ms_between_segments": 260,
  "segments": [
    {
      "segment_id": "sec_0003_seg_001",
      "index": 0,
      "type": "heading",
      "text": "Synchronous DRAM (SDRAM)",
      "ref": null,
      "start_ms": 0,
      "end_ms": 2200,
      "visually_essential": false
    },
    {
      "segment_id": "sec_0003_seg_003",
      "index": 2,
      "type": "formula_callout",
      "text": "The clock period tCK equals one over the frequency f, which is 10 nanoseconds.",
      "ref": "formula_0001",
      "start_ms": 18500,
      "end_ms": 25460,
      "visually_essential": true
    }
  ]
}
```

`type` is one of `heading | prose | figure_callout | formula_callout | table_callout`. `ref`, when non-null, is an id already present in `manifest.json`'s `figures`/`formulas`/`tables` arrays. `start_ms`/`end_ms` are sample-accurate — derived from each segment's actual synthesized audio duration during Stage 3's concatenation pass, not estimated — and index directly into `sections/{id}/audio.m4a`. This is the file the reader's highlight sync reads at runtime.

## Stage 2 LLM output (pre-Stage-3, internal — `compiled.json`)

What the LLM actually returns per chunk, before timestamps exist:

```json
{
  "sections": [
    {
      "title": "Synchronous DRAM (SDRAM)",
      "source_pages": [520, 521, 522],
      "segments": [
        {"type": "prose", "text": "SDRAM uses a synchronous interface...", "ref": null, "latex": null, "visually_essential": false},
        {"type": "formula_callout", "text": "The clock period tCK equals...", "ref": null, "latex": "t_{CK} = \\frac{1}{f} = 10\\,\\text{ns}", "visually_essential": false}
      ]
    }
  ]
}
```

Note `formula_callout` segments carry `latex` (LLM-authored) and leave `ref: null` — Stage 2's post-processing mints the real `formula_NNNN` id from that LaTeX and rewrites `ref` before this becomes the final `compiled.json`. `figure_callout`/`table_callout` segments do the reverse: `ref` is set directly (from the catalog the LLM was given) and `latex` stays null.
