"""firebrat_cast — expressive multi-voice audiobook pipeline.

Novels read like a human reader/cast: one narrator plus a unique voice per
character, with per-line emotion/delivery. Runs on a single GPU box where
only ONE large model is resident at a time (LLM for casting -> unload ->
TTS for synthesis).

Pipeline stages per book: ``fetch -> segment -> cast -> synth -> package``.
See SPEC.md (same directory) for the full contracts. Sibling stage modules
(segmenter, cast, compile_cast, tts_*) are owned by other workers; the
modules here import them lazily so unit tests run with fakes and no GPU.
"""

__version__ = "0.1.0"

__all__ = ["fetch", "gpu", "packager", "queue_runner", "synth"]
