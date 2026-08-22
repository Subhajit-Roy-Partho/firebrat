# Backend API

FastAPI app at `backend/server/main.py`. No auth, no database — it's a thin read-only layer over `backend/output/<book_id>/` directories. CORS is wide open (`allow_origins=["*"]`) since this is meant to be reached from an app on the local network, not the public internet.

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

Lists every book package under `OUTPUT_DIR` that has a valid `manifest.json`.

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

## `GET /books/{book_id}/assets/{path}`

Serves one file from inside the package by its relative path (e.g. `assets/figures/fig_0001.png`, or `sections/sec_0001/audio.m4a`). Guards against path traversal — a `path` that resolves outside the book's directory 404s rather than serving anything. Exists for partial/lazy fetch of individual assets; the app's main flow uses the bulk `/download` zip instead.

## Error shape

Standard FastAPI/Starlette JSON error body on 404s:
```json
{"detail": "book not found"}
```
