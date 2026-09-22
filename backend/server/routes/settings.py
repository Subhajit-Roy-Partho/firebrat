"""Server settings: global defaults + local-model preset.

Persisted as settings.json next to the jobs DB (survives restarts, works
the same bare-metal and in Docker). The upload form defaults provider /
chunk size from here when the caller omits them; the Docker entrypoint
reads the local preset at boot to download + serve the right weights.
Switching the preset while the shim runs does NOT hot-swap the model —
restart the shim (or container) afterwards; this endpoint says so.
"""
import json
import os

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from server import auth, config
from server.models import LOCAL_MODEL_PRESETS, preset_or_default

router = APIRouter()


def _path() -> str:
    return os.path.join(os.path.dirname(config.JOBS_DB_PATH), "settings.json")


def read_settings() -> dict:
    defaults = {
        "default_provider": "nanogpt",
        "default_chunk_pages": 0,
        "local_model_preset": config.LOCAL_MODEL_PRESET,
    }
    try:
        if os.path.isfile(_path()):
            with open(_path(), "r", encoding="utf-8") as f:
                stored = json.load(f)
            if isinstance(stored, dict):
                defaults.update({k: stored[k] for k in defaults if k in stored})
    except (OSError, ValueError):
        pass
    return defaults


def write_settings(patch: dict) -> dict:
    current = read_settings()
    for key in ("default_provider", "default_chunk_pages", "local_model_preset"):
        if key in patch:
            current[key] = patch[key]
    if current.get("default_provider") not in ("nanogpt", "local"):
        current["default_provider"] = "nanogpt"
    key, _ = preset_or_default(str(current.get("local_model_preset", "")))
    current["local_model_preset"] = key
    os.makedirs(os.path.dirname(_path()), exist_ok=True)
    with open(_path(), "w", encoding="utf-8") as f:
        json.dump(current, f, indent=2)
    return current


def _gpu_info() -> dict:
    try:
        import subprocess
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.total",
             "--format=csv,noheader"],
            capture_output=True, text=True, timeout=10,
        )
        if out.returncode == 0 and out.stdout.strip():
            return {"present": True, "gpus": out.stdout.strip().splitlines()}
    except Exception:
        pass
    return {"present": False, "gpus": []}


@router.get("/firebase-config")
def firebase_config():
    """Public Firebase web config for the browser UI's Google sign-in.

    These values are public by design (they ship in every Firebase web
    app). The apiKey defaults to FIREBASE_WEB_API_KEY, falling back to
    the Android key from google-services.json — if Google sign-in fails
    in the browser with api-key errors, create an unrestricted Browser
    key in console (Project settings → General → Web API Key is fine to
    reuse too) and set FIREBASE_WEB_API_KEY to it.
    """
    api_key = os.environ.get("FIREBASE_WEB_API_KEY", "")
    if not api_key:
        try:
            gs = os.path.join(os.path.dirname(os.path.dirname(
                os.path.dirname(os.path.abspath(__file__)))),
                "..", "frontend", "firebrat_app", "android", "app",
                "google-services.json")
            gs = os.path.normpath(gs)
            if os.path.isfile(gs):
                with open(gs, "r", encoding="utf-8") as f:
                    clients = json.load(f).get("client", [])
                if clients:
                    keys = clients[0].get("api_key", [])
                    if keys:
                        api_key = keys[0].get("current_key", "")
        except (OSError, ValueError, KeyError, IndexError):
            pass
    return {
        "apiKey": api_key,
        "authDomain": "firebrat-8c597.firebaseapp.com",
        "projectId": "firebrat-8c597",
    }


@router.get("/settings")
def get_settings():
    s = read_settings()
    key, entry = preset_or_default(s["local_model_preset"])
    return {
        "default_provider": s["default_provider"],
        "default_chunk_pages": s["default_chunk_pages"],
        "local_model_preset": key,
        "local_model": entry,
        "presets": LOCAL_MODEL_PRESETS,
        "gpu": _gpu_info(),
        "max_concurrent_jobs": config.MAX_CONCURRENT_JOBS,
        "auth": "firebase (mutations need a user; reads are open)",
    }


@router.post("/settings")
def update_settings(patch: dict, _user: dict = Depends(auth.require_user)):
    s = write_settings(patch if isinstance(patch, dict) else {})
    return JSONResponse(content={
        **s,
        "note": "local_model_preset applies when the LLM shim (re)starts — "
                "restart the container or llm_server.py to load new weights.",
    })
