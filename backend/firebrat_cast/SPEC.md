# firebrat_cast — expressive multi-voice audiobook pipeline (spec; master: Claude, implementers: opencode)

Additive package next to `firebrat/` (do NOT edit files under `backend/firebrat/` or `backend/convert.py`; import from them).
Goal: novels read like a human reader/cast: unique voice per character, emotional delivery, one narrator.
Runs on a single RTX 4080 (16 GB, ARM64 Linux host). **Only ONE large model is resident on the GPU at a time**:
LLM stage (casting) -> unload -> TTS stage. Python 3.12. venv `~/community-books/venv-qwen` has torch 2.11+cu128,
transformers, `qwen_tts` (0.1.1), bitsandbytes, accelerate, soundfile. Unit tests must run WITHOUT a GPU or models
(fake/mocked backends) with `python -m pytest backend/firebrat_cast/tests`.

## Models (decided)
- LLM (casting): `Qwen/Qwen3.5-9B` (Apache-2.0). Load FP8 (transformers FineGrainedFP8Config) or bnb 8-bit/4-bit — pick whichever
  loads and fits <=13 GB; log choice. Pluggable `LLMBackend` (`generate_json(system, user, schema_hint, max_tokens)->dict`):
  `LocalHFBackend` (in-process, `unload()` frees VRAM: `del model; gc.collect(); torch.cuda.empty_cache()`),
  `OpenAICompatBackend` (base_url+key from env `CAST_LLM_URL`/`CAST_LLM_KEY`, optional external). Disable thinking mode / strip `<think>`.
- TTS: `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign` (voice from a text description + emotion instruct) and
  `Qwen/Qwen3-TTS-12Hz-1.7B-Base` (zero-shot clone from a reference clip) — read the model cards / the installed
  `qwen_tts` package source for the real API; do not guess. Strategy: for each character, VoiceDesign generates a ~8-12 s anchor
  clip from the character description (cached as `voices/<char_id>.wav` + `.json`); lines are then synthesized with the anchor so the
  timbre stays consistent, with per-line emotion/delivery instruct if the API allows it (otherwise via VoiceDesign per line with the
  fixed description + emotion). A/B on a sample and pick the more consistent+expressive path; document in `tts_qwen.py` docstring.
- Fallback engine: existing Chatterbox via `firebrat.pipeline.tts.FirebratTTS` (reference clips = anchors).

## Data contracts
`segmenter.py` (deterministic, shared): `segment_pages(pages)->list[Seg]`; `Seg = {page:int, idx:int, kind:'quote'|'narration', text:str}`.
Quotes use the same `_QUOTE` regex as `firebrat/pipeline/novel.py`; (page, idx) is a stable key. Long text split at sentence boundaries to <=350 chars
(never cut mid-word; keep all text; join rules so no text lost). Input pages = `raw/raw_pages.json["pages"]` (`page_idx`, `text`).

`cast.json` (output of `cast.py`):
```
{"book_id","title","author","llm":{"backend","model"},
 "narrator":{"description":"warm mature storyteller...","accent":"british|american"},
 "characters":[{"id":"char_001","name","aliases":[],"gender":"male|female|unknown","age":"child|young|adult|elder",
   "temperament":"free short","accent":"british|american|other","description":"<=300 chars voice-design prompt","importance":int}],
 "utterances":[{"page":int,"idx":int,"speaker":"char_001"|"narrator","emotion":"neutral|joy|sadness|anger|fear|surprise|tenderness|sarcasm|disgust|awe|suspense","delivery":"<=60 chars e.g. 'whispered, trembling'"}],
 "page_mood":{"<page>":{"emotion","delivery"}}}   # narration delivery per page
```
Casting algorithm: (1) roster pass over whole book in overlapping windows (merge by name/alias; LLM resolves aliases like "Lizzy"="Elizabeth Bennet");
(2) attribution+emotion pass over chunks (~2500 words) listing numbered quotes with +-200 chars context and the roster; LLM returns compact JSON
`[[idx, speaker_id, emotion, delivery],...]`; validate against schema, retry with repair prompt, fall back to regex `_speaker` tags from novel.py,
else 'narrator'. Include a short 'recent speakers' carry-over for alternating dialogue. Cache per chunk on disk (resumable). Provide
`cast_book(raw_pages_path, out_path, backend, meta)`.

`compile_cast.py`: raw pages + cast.json -> `compiled.json` compatible with existing format (`sections[{section_id,title,source_pages,segments[{type:'prose',text,ref:None,
speaker_id,voice_style:{voice_id,emotion,delivery}}]}]`, `character_roster`), same section/page structure as `novel.compile_novel`.

`tts_engine.py`: `class VoiceEngine(Protocol): load(); unload(); anchor(char)->Path; speak(text, speaker_id, emotion, delivery)->(np.ndarray float32, sr)`.
Implementations in `tts_qwen.py` (primary), `tts_chatterbox.py` (fallback). Smart synthesis: strip/normalize text (numbers, roman numerals, abbreviations for natural reading),
no clipped endings, trim leading/trailing silence, normalize loudness per segment, 120-350 ms natural pauses (longer at paragraph ends), retry on empty/garbled output
(duration sanity: >= 0.04 s per char and <= 0.25 s per char), per-line seed fixed for reproducibility.

`synth.py`: `synthesize_book(compiled_path, pkg_dir, engine)`: per section -> wavs -> reuse `firebrat.pipeline.audio_assemble.assemble_section(...)` (read how
`backend/convert.py` Stage 3/4 calls it and builds the manifest with `firebrat.pipeline.manifest`) so the output is the standard Firebrat package
(manifest.json, sections/<id>/audio.m4a + segments.json) with AAC >= 96 kbps. Resumable per section (skip finished). Record narrator/character voices
+ model names in manifest `narrator_voice` and a new `cast` key. 

`queue_runner.py` (CLI `python -m firebrat_cast.queue_runner --catalog catalog.json --root ~/community-books`): per-book state `jobs/<slug>/state.json`
(`fetch -> segment -> cast -> synth -> package`), atomic writes, resumable, safe to kill any time. Scheduler works in WAVES to minimise model swaps:
wave = next N (default 2) pending books, shortest first: load LLM once -> cast all wave books -> unload (verify free VRAM) -> load TTS once -> synthesize
them one at a time -> unload -> package zips -> next wave. If backend is external (`OpenAICompatBackend`), cast for wave k+1 runs in a thread while wave k synthesizes.
GPU lease: `gpu.py` with `free_vram_gb()`, `wait_for_vram(min_gb)`, a file lock so only one GPU stage runs at once, and `ensure_free(min_gb)` that
raises a clear error naming the process holding VRAM (never kills processes). Stage logs to `jobs/<slug>/log.txt`; progress JSON `progress.json`
(stage, percent, eta). Gutenberg fetch/clean (EPUB download, `firebrat.pipeline.ebook.run_ebook_extraction`, strip PG header/footer — see `~/community-books/build_book.py`
for the working version) lives in `fetch.py`.

## Quality bar (must be verified, not asserted)
Casting: on a sample chapter of Pride and Prejudice-style text, attribution of explicit-tag quotes must match regex baseline (>=95%) and recover implicit speakers.
TTS: each character audibly different (distinct anchors), consistent across a book, emotion varies with `emotion`, no truncated sentences, no long silences.
Tests mock the models. Real-model validation is done by the lead on the server.
