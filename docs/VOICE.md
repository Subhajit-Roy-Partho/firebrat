# Narrator Voice Setup

## Current state: default voice, no cloning

`backend/voice/` is empty. Every conversion so far — including the verified small-scale runs described in `TASK.md` — used Chatterbox's built-in default voice by passing `audio_prompt_path=None` (`FirebratTTS(voice_ref=None)` in `firebrat/pipeline/tts.py`). It produces clear, natural narration out of the box; there was no need to reach for voice cloning to get acceptable quality.

## Reference clip (`backend/voice/narrator_ref.wav`) — for later, if a specific voice is wanted

If you want a specific, consistent narrator voice instead of Chatterbox's default:

1. Record or source a **clean, single-speaker** WAV, roughly 10-20 seconds, minimal background noise, neutral reading-aloud pace. Longer isn't better here — Chatterbox uses this as a style/timbre reference, not a training set.
2. Save it as `backend/voice/narrator_ref.wav`.
3. Pass `--voice-ref backend/voice/narrator_ref.wav` to `convert.py`, or set `voice_ref=` when constructing `FirebratTTS` directly.
4. The chosen path gets recorded in the output `manifest.json`'s `narrator_voice.reference_clip` field, so a book package is self-documenting about which voice narrated it.

Only license-cleared or self-recorded audio should go here — this repo is AGPL-3.0 licensed and public; don't commit a reference clip you don't have the rights to redistribute.

## Chatterbox parameters used, and why

`firebrat/config.py`: `TTS_EXAGGERATION = 0.4`, `TTS_CFG_WEIGHT = 0.5` — Chatterbox's own defaults. These weren't tuned further because the default output was already good; `exaggeration` pushes toward more expressive/dramatic delivery (higher values), `cfg_weight` trades off adherence to the reference voice vs. naturalness of the generated speech. If narration for a different book sounds off, these are the two knobs to try first, in small increments (they're sensitive).

## Pacing notes — Chatterbox has no direct speed knob

Chatterbox's `generate()` API doesn't expose a "speaking rate" parameter — pacing comes out of the model's own prosody model given the text, `exaggeration`, and `cfg_weight`. Two consequences that shaped this pipeline's design:

- Stage 2's LLM prompt explicitly asks for short segments (15-30 words), which keeps individual synthesis calls fast and gives natural sentence-boundary pauses "for free" via the per-segment silence padding in `audio_assemble.py`, rather than needing the model to pace a long paragraph well on its own.
- If narration ever sounds rushed or has awkward pauses, treat it as a text-shaping problem first (adjust the Stage 2 prompt's sentence-length guidance, or add punctuation) before assuming there's a synthesis parameter to fix it — there isn't one.
- The app-side playback speed control (`0.75x`-`2x`, in the reader's transport bar) is the actual user-facing pacing control — it's a straightforward audio speed adjustment on the already-synthesized track, unrelated to Chatterbox's generation parameters.
