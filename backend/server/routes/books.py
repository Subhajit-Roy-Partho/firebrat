import os
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse, JSONResponse

from server.storage import (
    list_book_ids, read_manifest, resolve_asset,
    book_summary, get_or_build_zip,
)

router = APIRouter()

@router.get("/books")
def list_books():
    ids = list_book_ids()
    out = []
    for bid in ids:
        s = book_summary(bid)
        if s:
            out.append(s)
    return out

@router.get("/books/{book_id}/manifest")
def get_manifest(book_id: str):
    m = read_manifest(book_id)
    if m is None:
        raise HTTPException(status_code=404, detail="book not found")
    return JSONResponse(content=m)

@router.get("/books/{book_id}/download")
def download_book(book_id: str):
    zpath = get_or_build_zip(book_id)
    if zpath is None or not os.path.isfile(zpath):
        raise HTTPException(status_code=404, detail="book not found or not packaged yet")
    return FileResponse(zpath, media_type="application/zip",
                        filename=f"{book_id}.zip")

@router.get("/books/{book_id}/assets/{asset_path:path}")
def get_asset(book_id: str, asset_path: str):
    full = resolve_asset(book_id, asset_path)
    if full is None:
        raise HTTPException(status_code=404, detail="asset not found")
    # Guess media type from extension
    import mimetypes
    mt, _ = mimetypes.guess_type(full)
    return FileResponse(full, media_type=mt or "application/octet-stream")
