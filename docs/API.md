# Backend API

FastAPI app at `backend/server/main.py`. No auth. CORS is wide open (`allow_origins=["*"]`) since this is meant to be reached from an app on the local network, not the public internet.

Two halves: a read-only layer over `backend/output/<book_id>/` package directories (`/books/*`, unchanged since the pipeline first shipped), and an upload/conversion job queue (`/books/upload`, `/jobs/*`) that runs `convert.py` as a subprocess per upload and tracks it in a small SQLite table (`backend/server/jobs.py`) plus a `status.json` the pipeline itself writes into each package directory as it runs (`backend/firebrat/pipeline/status.py`). See `backend/server/job_runner.py` for the queue itself — one worker by default (`FIREBRAT_MAX_CONCURRENT_JOBS`), because conversion is memory/GPU heavy (AGENTS.md).

Run it with:
```bash
/path/to/envs/firebrat-serve/bin/python -m uvicorn server.main:app --host 0.0.0.0 --port 8000
```
(from the `backend/` directory, or with `backend/` on `PYTHONPATH`).

## `GET /health`

Liveness check.

```json
{"status": "ok"}
```

## `GET /books`

Lists every book package under `OUTPUT_DIR` that has a valid `manifest.json` **and** is actually finished converting — a book mid-conversion has a manifest (the pipeline writes an early one before Stage 3 so section ids are stable) but won't appear here until its `status.json` says `"status": "done"`. Watch it convert via `GET /jobs` instead.

```json
[
  {
    "book_id": "arm-fundamentals-soc",
    "title": "Fundamentals of System-on-Chip Design on Arm Cortex-M Microcontrollers",
    "author": "",
    "total_duration_ms": 26496000,
    "section_count": 242,
    "size_bytes": 451331000,
    "updated_at": "2026-08-22T04:51:00Z"
  }
]
```

## `GET /books/{book_id}/manifest`

Returns the book's full `manifest.json` verbatim. 404 if `book_id` doesn't exist. See `docs/DATA_SCHEMA.md` for the shape.

## `GET /books/{book_id}/download`

Streams a zip of the entire package (manifest + all section audio + all assets). The zip is built on first request and cached in a temp file, keyed off the manifest's mtime — a re-conversion of the same book automatically invalidates the cache. 404 if the book doesn't exist.

This is the only endpoint the Flutter app calls beyond `/books` and this download — once extracted locally, the reader never talks to the server again.

## `GET /books/{book_id}/checksum`

`{"book_id", "size_bytes", "sha256"}` for the exact bytes `/download` currently serves (same mtime-keyed cache, so both always agree). The app fetches this before downloading — a partial `.part` file resumes via `Range` against the right total — and verifies the completed file's sha256 before extracting, redownloading from scratch on mismatch. 404 if the book doesn't exist.

## `GET /books/{book_id}/assets/{path}`

Serves one file from inside the package by its relative path (e.g. `assets/figures/fig_0001.png`, or `sections/sec_0001/audio.m4a`). Guards against path traversal — a `path` that resolves outside the book's directory 404s rather than serving anything. Exists for partial/lazy fetch of individual assets; the app's main flow uses the bulk `/download` zip instead.

## `DELETE /books/{book_id}`

Permanently deletes a converted book's package (audio, assets, manifest — everything) to free server space. Irreversible — the caller should confirm with the user first. `{"deleted": "book_id"}` on success, 404 if `book_id` doesn't exist.

## `POST /books/upload`

Upload a PDF — or a `.zip` containing one or more PDFs (e.g. per-chapter files), which the server merges in sorted archive order into a single source PDF before converting. `multipart/form-data`: `file` (required, `.pdf`/`.zip` only, capped at `FIREBRAT_MAX_UPLOAD_MB` — default 500), `title` (optional, defaults to a title-cased version of the filename), `provider` (`nanogpt`|`local`, empty = server default from `/settings`), `chunk_pages` (0 = server default; smaller fits endpoints that kill long generations). Requires sign-in. Returns the newly-created job immediately (state `queued`); conversion runs in the background — several jobs may convert at once, up to `FIREBRAT_MAX_CONCURRENT_JOBS` workers. A zip with no PDFs inside is rejected with 400; retry/resume work identically for zip-sourced jobs since the merge happens once at upload time.

```json
{
  "job_id": "3f9a1c2b7e8d4a10",
  "book_id": "my-book",
  "filename": "My Book.pdf",
  "title": "My Book",
  "state": "queued",
  "stage": null,
  "detail": null,
  "progress": null,
  "needs_review_count": 0,
  "error": null,
  "retry_count": 0,
  "created_at": "2026-08-23T00:00:00Z",
  "updated_at": "2026-08-23T00:00:00Z"
}
```

A repeat upload of a filename that already has a package on disk gets a disambiguated `book_id` (`my-book-2`, `my-book-3`, ...) rather than colliding with or overwriting the earlier conversion.

## `GET /jobs`

Every job, most recent first — queued, running, done, and failed, so this is the one call a "conversions" UI needs to render everything. Each entry has the same shape as the upload response above; `stage` is one of `extracting`, `compiling`, `rendering_formulas`, `synthesizing`, `packaging`, `done`, and `progress` is a 0.0-1.0 fraction *within* that stage (null when not yet meaningful, e.g. still queued).

## `GET /jobs/{job_id}`

One job, same shape. 404 if unknown.

## `POST /jobs/{job_id}/retry`

Re-runs a `failed` job, or re-attempts the `needs_review` chunks/sections of a `done` one (e.g. after pointing `FIREBRAT_SPARK_MODEL` at a stronger tier). Always cheap, never starts over from scratch: it inspects how far the previous attempt got (via `status.json`'s `stage`) and skips extraction if raw pages already exist, then runs `convert.py --retry-failed` — Stage 2 only redoes chunks flagged `needs_review`, and Stage 3 only re-synthesizes sections that were never fully assembled (segment-by-segment, so a crash partway through TTS doesn't cost you the sections that already finished). 409 if the job is currently `queued`/`running`; 410 if the original upload was deleted from disk (re-upload instead).

## `POST /jobs/{job_id}/resume`

Puts a stuck `queued`/`running` job back on the work queue, unchanged (no `--retry-failed` — this only continues from checkpoint, it doesn't redo flagged content, unlike retry). The server already does this **automatically at startup** for every job left `queued`/`running` — the common cause is the server process restarting mid-conversion, which used to silently strand a job forever; now it just resumes. This endpoint exists for the rarer case a job looks stuck for some other reason and you want to nudge it by hand. 409 if the job isn't currently `queued`/`running`; 410 if the original upload was deleted from disk.

## `GET /jobs/{job_id}/log?tail_lines=200`

## `GET /settings` · `POST /settings`

Server defaults + capabilities for external users. GET returns
`default_provider`, `default_chunk_pages`, `local_model_preset` (+ its
entry), the full `presets` table (repo + VRAM notes), `gpu` presence,
`max_concurrent_jobs`, and the auth model. POST (sign-in required) saves
`default_provider` / `default_chunk_pages` / `local_model_preset`
(validated, unknown values fall back); the preset applies when the LLM
shim (re)starts — restart the container or `llm_server.py` for new
weights. Uploads that omit provider/chunk inherit these defaults.

## `GET /firebase-config`

Public Firebase web config (`apiKey`, `authDomain`, `projectId`) for the
browser UI's Google sign-in. Public by design.

## `GET /` (web control room)

Dependency-free static UI (`backend/server/static/`): server health/GPU/
workers, settings form, multi-PDF upload with per-book provider + chunk
options, live job table with retry/resume, book shelf with download +
delete. Same-origin fetch, Firebase compat SDK for sign-in; reads work
anonymous, mutations send the ID token.
The last N lines of that job's raw `convert.py` stdout/stderr, for debugging a failure beyond what `error` summarizes. `{"lines": ["...", "..."]}`.

## Error shape

Standard FastAPI/Starlette JSON error body on 404s:
```json
{"detail": "book not found"}
```
