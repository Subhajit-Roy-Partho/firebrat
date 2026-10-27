# Integrating firebrat_cast ("expressive cast" mode) into the Firebrat server, PWA and Android app

New upload mode `content_mode=cast` ("Expressive voices"): the server casts characters with an LLM and narrates each character
with a distinct voice and emotion (Qwen3-TTS), producing the SAME package format every client already plays
(manifest.json, sections/<id>/audio.m4a + segments.json). Everything is ADDITIVE; existing modes/clients must keep working.

## Contract
- `POST /books/upload`: `content_mode` accepts `illustrated | novel | cast`. `cast` needs an ebook (.epub/.mobi/.azw/.azw3) or a
  text-based PDF (embedded text, no OCR). When the server has no cast capability, `cast` returns 400 `{"detail": "Expressive voices are not enabled on this server"}`;
  invalid modes still 422. Stored in the jobs table like the other modes (jobs.py allow-list; sqlite column is TEXT so no migration).
- `GET /settings` gains `"cast_available": bool` (true only when env `FIREBRAT_CAST_ENABLED=1` and the scheduler launcher can start).
  Clients show the option only when true (missing key = false).
- Job lifecycle for `cast`: job_runner does NOT run convert.py. It writes `<cast_root>/inbox/<book_id>.json`
  (`{slug: book_id, title, author:"", source_path:<uploaded file>, category:"fiction", language:"en", description:""}`; slug must match `[a-z0-9][a-z0-9-]{2,99}`)
  and mirrors scheduler progress into the job: queued -> running with `status.json` stage text
  `queued`, `preparing text`, `casting characters`, `recording voices`, `packaging`, then `done` / `failed`
  (read `<cast_root>/jobs/<slug>/state.json` + `<cast_root>/scheduler_status.json`; both written by firebrat_cast.scheduler).
  Retry/resume/delete/cancel must work (delete removes the inbox entry if still queued).
- Output directory: the scheduler writes the package to `<cast_root>/out/<slug>/`; the server sets `<cast_root>/out` to be FIREBRAT_OUTPUT_DIR
  (config key `CAST_ROOT`, env `FIREBRAT_CAST_ROOT`, default `<FIREBRAT_OUTPUT_DIR>/../cast`; create `out` as a symlink to FIREBRAT_OUTPUT_DIR) so `/books` lists it.
- The server starts (and supervises, restarting at most 3 times) `python -m firebrat_cast.scheduler run --root <cast_root> ...` as a child process at startup
  when `FIREBRAT_CAST_ENABLED=1` (interpreters from env `FIREBRAT_CAST_LLM_PY` / `FIREBRAT_CAST_TTS_PY` / `FIREBRAT_CAST_VLLM_BIN`); terminates it on shutdown.
- `firebrat_cast/fetch.py`: `fetch_book(entry, root)` also accepts `entry["source_path"]` (local EPUB/MOBI/AZW via firebrat.pipeline.ebook.run_ebook_extraction,
  or PDF text via pymupdf `page.get_text()`, one raw page per PDF page; clear error text for scanned PDFs: "This PDF has no embedded text; use Illustrated or Novel mode"), no Gutenberg download, no boilerplate stripping.
- Manifest: additive `cast` key (`{engine, characters:[{id,name,gender,age,voice_description}]}`) and `narrator_voice.engine = "qwen3-tts"`. Clients ignore unknown keys; verify the Pydantic models and Dart manifest parsing tolerate it.
- PWA: when `/settings.cast_available`, the "Book type" select gains `Expressive voices (multi-voice, GPU server)` (value `cast`) with a one-line explanation
  (slower; characters get their own voices; EPUB/MOBI or text PDF). Sends `content_mode=cast`. Job list shows the stage text. Unknown stages must render fine.
- Android: same option in the server-conversion upload UI; `ApiClient.upload(... contentMode: 'cast')`; hide it when `cast_available` is false; show a clear error on the 400.
  Do NOT touch on-device conversion.
- Tests: backend pytest (job creation, 422/400 paths, settings flag, job_runner cast path with a fake scheduler dir and state files, supervisor start/stop with a fake command, fetch source_path for a tiny generated EPUB and a tiny text PDF);
  PWA `npm test`; Flutter `flutter analyze` + `flutter test` for touched code. Never break existing tests.
