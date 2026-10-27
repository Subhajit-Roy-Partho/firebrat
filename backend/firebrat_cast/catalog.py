"""Server-defined model catalog: the only models an administrator can select.

Settings never carry free-text model names. Each choice is a key into the
tables below; the scheduler resolves keys to HuggingFace repos / served names
here, and the admin API reports `vram_gb`, `description` and `available`
(weights already present in the local HF cache) for every entry.
"""
from __future__ import annotations

import glob
import os

LLM_MODELS: dict[str, dict] = {
    "qwen3.5-9b": {
        "name": "Qwen3.5 9B", "repo": "Qwen/Qwen3.5-9B", "served_name": "qwen3.5-9b",
        "vram_gb": 11, "description": "Best casting quality; needs about 11 GB of VRAM with fp8.",
    },
    "qwen3.5-4b": {
        "name": "Qwen3.5 4B", "repo": "Qwen/Qwen3.5-4B", "served_name": "qwen3.5-4b",
        "vram_gb": 6, "description": "Faster and lighter (about 6 GB); slightly weaker character attribution.",
    },
}

# tts engines: `scheduler_tts` is the engine family the stage process loads
# ('qwen' | 'chatterbox'); `repos` are the checkpoints that must be cached;
# `env` is passed to the stage subprocess to pick the Qwen checkpoints.
TTS_ENGINES: dict[str, dict] = {
    "qwen3-tts-1.7b": {
        "name": "Qwen3-TTS 1.7B", "scheduler_tts": "qwen", "vram_gb": 6,
        "repos": ["Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign", "Qwen/Qwen3-TTS-12Hz-1.7B-Base"],
        "env": {"FIREBRAT_QWEN_TTS_DESIGN_MODEL": "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign",
                "FIREBRAT_QWEN_TTS_BASE_MODEL": "Qwen/Qwen3-TTS-12Hz-1.7B-Base"},
        "description": "Most expressive multi-voice engine (voice design plus cloning).",
    },
    "qwen3-tts-0.6b": {
        "name": "Qwen3-TTS 0.6B", "scheduler_tts": "qwen", "vram_gb": 3,
        "repos": ["Qwen/Qwen3-TTS-12Hz-0.6B-Base"],
        "env": {"FIREBRAT_QWEN_TTS_BASE_MODEL": "Qwen/Qwen3-TTS-12Hz-0.6B-Base"},
        "description": "Smaller and faster Qwen3-TTS; less nuance in emotion.",
    },
    "chatterbox": {
        "name": "Chatterbox", "scheduler_tts": "chatterbox", "vram_gb": 5,
        "repos": ["ResembleAI/chatterbox"], "env": {},
        "description": "Resemble AI Chatterbox with emotion control.",
    },
}


def hf_home() -> str:
    return os.environ.get("HF_HOME") or os.path.join(os.path.expanduser("~"), ".cache", "huggingface")


def repo_cached(repo: str, home: str | None = None) -> bool:
    """True when <home or $HF_HOME>/hub/models--<org>--<name>/snapshots/* has a snapshot."""
    org, _, name = repo.partition("/")
    base = os.path.join(home or hf_home(), "hub", f"models--{org}--{name}", "snapshots")
    return bool(glob.glob(os.path.join(glob.escape(base), "*")))


def llm_available(key: str, home: str | None = None) -> bool:
    return key in LLM_MODELS and repo_cached(LLM_MODELS[key]["repo"], home)


def tts_available(key: str, home: str | None = None) -> bool:
    entry = TTS_ENGINES.get(key)
    return bool(entry) and all(repo_cached(r, home) for r in entry["repos"])


def available(kind: str, key: str) -> bool:
    return llm_available(key) if kind == "llm" else tts_available(key)


def model_available(repo: str, home: str | None = None) -> bool:
    return repo_cached(repo, home)


def options() -> dict:
    """Catalog as the admin API returns it (no internal env/repo plumbing leaked beyond repo ids)."""
    return {
        "llm_model": [{"id": k, "name": v["name"], "vram_gb": v["vram_gb"],
                       "description": v["description"], "repo": v["repo"]}
                      for k, v in LLM_MODELS.items()],
        "tts_engine": [{"id": k, "name": v["name"], "vram_gb": v["vram_gb"],
                        "description": v["description"], "repos": list(v["repos"])}
                       for k, v in TTS_ENGINES.items()],
        "quantization": ["fp8"],
        "phase_mode": ["batched", "sequential"],
        "audio_order": ["shortest_first", "fifo"],
    }


def availability(home: str | None = None) -> dict:
    return {"llm": {k: llm_available(k, home) for k in LLM_MODELS},
            "tts": {k: tts_available(k, home) for k in TTS_ENGINES}}


def all_options(home: str | None = None) -> dict:
    """Flat lists of {id,name,vram_gb,description,available} per kind."""
    return {"llm": [{"id": k, "name": v["name"], "vram_gb": v["vram_gb"],
                     "description": v["description"], "available": llm_available(k, home)}
                    for k, v in LLM_MODELS.items()],
            "tts": [{"id": k, "name": v["name"], "vram_gb": v["vram_gb"],
                     "description": v["description"], "available": tts_available(k, home)}
                    for k, v in TTS_ENGINES.items()]}


def get_tts(key: str) -> dict | None:
    e = TTS_ENGINES.get(key)
    return None if e is None else {**e, "id": key}


# ── compatibility surface used by the scheduler / server_settings workers ──
DEFAULT_LLM_ID = "qwen3.5-9b"
DEFAULT_TTS_ID = "qwen3-tts-1.7b"


def get_llm(key: str) -> dict | None:
    """Catalog entry with `hf_repo`/`served_name`, or None for unknown ids."""
    e = LLM_MODELS.get(key)
    return None if e is None else {**e, "id": key, "hf_repo": e["repo"]}


def tts_kind(key: str) -> str | None:
    """Scheduler engine family ('qwen' | 'chatterbox') for a tts id, else None."""
    e = TTS_ENGINES.get(key)
    return None if e is None else e["scheduler_tts"]


def _settings_catalog() -> dict:
    return {
        "llm_models": [{"id": k, "name": v["name"], "vram_gb": v["vram_gb"],
                        "description": v["description"], "available": llm_available(k)}
                       for k, v in LLM_MODELS.items()],
        "tts_engines": [{"id": k, "name": v["name"], "vram_gb": v["vram_gb"],
                         "description": v["description"], "available": tts_available(k)}
                        for k, v in TTS_ENGINES.items()],
    }


class _LazyCatalog(dict):
    """SERVER_SETTINGS_CATALOG recomputed on access so `available` tracks the HF cache."""
    def __getitem__(self, k): return _settings_catalog()[k]
    def __contains__(self, k): return k in ("llm_models", "tts_engines")


SERVER_SETTINGS_CATALOG = _LazyCatalog()
