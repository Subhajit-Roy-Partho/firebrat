# firebrat_cast — expressive multi-voice audiobooks

Turns a novel into an audiobook with a **distinct voice per character**, emotional delivery and a human-sounding narrator.
Design and data contracts: `SPEC.md`. Tests (no GPU/models needed): `python -m pytest backend/firebrat_cast/tests`.

## How it works
1. `fetch` — Project Gutenberg EPUB -> clean text (boilerplate stripped) -> `raw_pages.json`.
2. `segment` — deterministic quote/narration split with stable `(page, idx)` keys.
3. `cast` (LLM stage) — Qwen3.5-9B builds the roster (gender, age, temperament, accent, voice description), attributes every
   quote to a speaker and tags emotion/delivery; resumable per chunk. Output `cast.json`.
4. `synth` (TTS stage) — Qwen3-TTS 1.7B: VoiceDesign makes a per-character anchor voice, lines are spoken with that voice and
   emotion; text normalised, silence trimmed, loudness matched. Output is a standard Firebrat package.
5. `package` — zip (audio stored) ready for the Internet Archive.

Only one large model sits on the GPU at a time. Stages run as separate processes in their own venvs so VRAM is fully freed
between them (Qwen3.5 needs transformers>=5; qwen-tts wants its own). The scheduler works in waves (default 2 books: cast both,
then synthesize both) to minimise model reloads, does all CPU work (downloads) up front, and waits for the GPU instead of failing
when another job holds it. State is per book in `jobs/<slug>/state.json`; kill and rerun any time.

## Run
```sh
export PYTHONPATH=backend
python -m firebrat_cast.queue_runner --catalog catalog.json --root ~/community-books \
  --wave-size 2 --llm-python /path/cast-llm/bin/python --tts-python /path/cast-tts/bin/python
```
`catalog.json`: list of `{slug, gutenberg, title, author, died, category, language, description, sourceUrl}`.
Use `--dry-run` to see the plan, `--only <slug>` for one book, `--llm-backend external` (+ `CAST_LLM_URL`/`CAST_LLM_KEY`) for an API model.

## Lessons verified on an RTX 4080 (16 GB)
- Qwen3.5-9B: load with bitsandbytes 8-bit and **skip the `visual` and `lm_head` modules**. FP8 on-the-fly conversion corrupted the
  vision tower (hallucinated descriptions); bf16 does not fit.
- The GPU stage must queue behind other jobs rather than fail; never kill processes that hold VRAM.

## Docker
`backend/docker/Dockerfile` builds the two extra venvs (`/opt/venvs/cast-llm`, `/opt/venvs/cast-tts`) when `--build-arg WITH_CAST=1`
(on in the GPU CI variant). Weights download at first use into `HF_HOME`. Not built or tested locally.

Related tool: `backend/scripts/relink_figures.py` re-links orphaned figures/tables of a finished package by matching real captions
from the source PDF (optionally confirmed by the vision model).
