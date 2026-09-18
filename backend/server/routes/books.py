import os
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse, JSONResponse

from server import auth
from server.storage import (
    list_book_ids, read_manifest, resolve_asset,
    book_summary, get_or_build_zip, get_zip_info, delete_book,
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

@router.get("/books/{book_id}/checksum")
def get_checksum(book_id: str):
    """Size + sha256 of the exact bytes `/download` serves for this book.

    The app fetches this BEFORE downloading (so a partial `.part` file can
    resume against the right total) and AFTER (to verify the completed file
    before extracting). Building the zip the first time takes a while for
    big books — that cost is paid once and cached by manifest mtime.
    """
    info = get_zip_info(book_id)
    if info is None:
        raise HTTPException(status_code=404, detail="book not found or not packaged yet")
    return JSONResponse(content=info)

@router.delete("/books/{book_id}")
def remove_book(book_id: str, _user: dict = Depends(auth.require_user)):
    """Permanently deletes a converted book's package (audio, assets,
    manifest — everything) to free space on the server. Irreversible —
    the app should confirm with the user before calling this.
    """
    if not delete_book(book_id):
        raise HTTPException(status_code=404, detail="book not found")
    return {"deleted": book_id}

@router.get("/books/{book_id}/assets/{asset_path:path}")
def get_asset(book_id: str, asset_path: str):
    full = resolve_asset(book_id, asset_path)
    if full is None:
        raise HTTPException(status_code=404, detail="asset not found")
    # Guess media type from extension
    import mimetypes
    mt, _ = mimetypes.guess_type(full)
    return FileResponse(full, media_type=mt or "application/octet-stream")
