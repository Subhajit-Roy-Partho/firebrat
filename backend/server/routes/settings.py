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
import tempfile

from fastapi import APIRouter, Depends, HTTPException
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
    if "default_chunk_pages" in patch:
        v = patch["default_chunk_pages"]
        if isinstance(v, bool) or not isinstance(v, int) or not 0 <= v <= 10000:
            raise ValueError("default_chunk_pages must be an int 0..10000")
    for key in ("default_provider", "default_chunk_pages", "local_model_preset"):
        if key in patch:
            current[key] = patch[key]
    if current.get("default_provider") not in ("nanogpt", "local"):
        current["default_provider"] = "nanogpt"
    key, _ = preset_or_default(str(current.get("local_model_preset", "")))
    current["local_model_preset"] = key
    os.makedirs(os.path.dirname(_path()), exist_ok=True)
    # Atomic: write a temp file next to the target, fsync, then replace, so a
    # crash or concurrent reader never sees a torn settings.json.
    fd, tmp = tempfile.mkstemp(prefix="settings.", suffix=".tmp",
                               dir=os.path.dirname(_path()))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(current, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, _path())
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
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


# Free-tier cloud fallback chain (nano-gpt OpenAI-compatible ids). First
# entry is the default pick; the rest are tried by the caller in order.
FREE_MODEL_FALLBACKS = [
    "nvidia/nemotron-3-super-120b-a12b:free",
    "google/gemma-4-31b-it:free",
    "dots-studio/dots-3-note-preview:free",
]


def _cloud_models() -> tuple[str, str, list[str]]:
    """(spark_default, deepseek_default, ordered_deduped_list).

    Reads env at call time (not import) so tests and runtime overrides
    work — firebrat.config freezes these at first import, which is wrong
    for a long-lived server process. Env default preserved when unset.
    """
    spark = os.environ.get("FIREBRAT_SPARK_MODEL", "") or "z-ai/glm-5.3-flash"
    deep = os.environ.get("FIREBRAT_DEEPSEEK_MODEL", "") or "z-ai/glm-5.3-flash"
    ordered: list[str] = []
    for m in [spark, deep, *FREE_MODEL_FALLBACKS]:
        m = (m or "").strip()
        if m and m not in ordered:
            ordered.append(m)
    return spark, deep, ordered


def _live_models(base_url: str, api_key: str) -> tuple[list[str], bool]:
    """Proxy an OpenAI-compatible GET {base}/models with an 8s timeout.

    Returns (model_ids, ok). Never raises — on any failure the caller
    falls back to the env list, so a dead endpoint degrades the picker
    instead of 500ing it.
    """
    try:
        import json as _json
        import urllib.request
        url = base_url.rstrip("/") + "/models"
        req = urllib.request.Request(url, method="GET")
        if api_key:
            req.add_header("Authorization", f"Bearer {api_key}")
        with urllib.request.urlopen(req, timeout=8) as resp:
            payload = _json.load(resp)
        data = payload.get("data") if isinstance(payload, dict) else None
        if isinstance(data, list):
            ids = [d.get("id") for d in data
                   if isinstance(d, dict) and d.get("id")]
            if ids:
                return [str(i) for i in ids], True
    except Exception:
        pass
    return [], False


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
    api_key = os.environ.get("FIREBASE_WEB_API_KEY", "AIzaSyDnvh3rtp4f2GtU9vOAIoDIcWLnXpTp38E")
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
        "appId": "1:657440934081:web:c94b0a6fd08fdb7f1bac40",
    }


@router.get("/settings")
def get_settings():
    s = read_settings()
    key, entry = preset_or_default(s["local_model_preset"])
    spark, deep, cloud = _cloud_models()
    return {
        "default_provider": s["default_provider"],
        "default_chunk_pages": s["default_chunk_pages"],
        "local_model_preset": key,
        "local_model": entry,
        "presets": LOCAL_MODEL_PRESETS,
        "cloud_models": cloud,
        "cloud_model_default": spark,
        "cloud_strong_model_default": deep,
        "gpu": _gpu_info(),
        "max_concurrent_jobs": config.MAX_CONCURRENT_JOBS,
        "auth": "firebase (mutations need a user; reads are open)",
        "conversion_capabilities": {
            "ebooks": config.CONVERTER_SUPPORTS_EBOOKS,
            "character_traits": config.CONVERTER_SUPPORTS_CHARACTER_TRAITS,
        },
        # Clients show the Expressive-voices option only when true
        # (missing key = false on old servers).
        "cast_available": config.cast_available(),
        # Clients show the server-administration UI only when true.
        "iam_enabled": config.iam_enabled(),
    }


@router.get("/models")
def list_models(provider: str = "nanogpt",
                _user: dict = Depends(auth.require_role("admin", "user", "viewer"))):
    """Authenticated provider/model picker backing for the app.

    providers: the two job providers. cloud_models: env defaults plus
    the free fallback chain. live_models: proxied OpenAI-compatible
    GET {base}/models (8s timeout) when reachable, else the env list —
    this endpoint never 500s on a list failure (live_ok=False then).
    """
    s = read_settings()
    key, _entry = preset_or_default(s["local_model_preset"])
    spark, deep, cloud = _cloud_models()
    prov = (provider or "nanogpt").strip() or "nanogpt"
    if prov not in ("nanogpt", "local"):
        prov = "nanogpt"
    if prov == "local":
        base = os.environ.get("FIREBRAT_LOCAL_LLM_URL",
                              config.LOCAL_LLM_URL)
        live, ok = _live_models(base, "")
    else:
        base = os.environ.get("NANO_API_URL",
                              "https://nano-gpt.com/api/v1")
        api_key = (os.environ.get("NANO_API_KEY")
                   or os.environ.get("MODEL_API_KEY", ""))
        live, ok = _live_models(base, api_key)
    return {
        "providers": ["nanogpt", "local"],
        "default_provider": s["default_provider"],
        "provider": prov,
        "cloud_models": cloud,
        "cloud_model_default": spark,
        "cloud_strong_model_default": deep,
        "free_fallbacks": FREE_MODEL_FALLBACKS,
        "local_model_preset": key,
        "presets": LOCAL_MODEL_PRESETS,
        "local_presets": LOCAL_MODEL_PRESETS,
        "gpu": _gpu_info(),
        "live_models": live if ok else cloud,
        "live_ok": ok,
    }


@router.post("/settings")
def update_settings(patch: dict, _user: dict = Depends(auth.require_role("admin"))):
    try:
        s = write_settings(patch if isinstance(patch, dict) else {})
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    if config.iam_enabled():
        from server import iam as _iam
        _iam.safe_audit(_user["uid"], "settings.update", "settings",
                        json.dumps({k: s.get(k) for k in (
                            "default_provider", "default_chunk_pages",
                            "local_model_preset")}, sort_keys=True))
    return JSONResponse(content={
        **s,
        "note": "local_model_preset applies when the LLM shim (re)starts — "
                "restart the container or llm_server.py to load new weights.",
    })
