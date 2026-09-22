"""Local LLM model presets for machines with different VRAM.

Keys are the LOCAL_MODEL_PRESET values (env / web UI / run.sh). Each entry
is the Hugging Face snapshot to download plus the honest VRAM math, so a
user on a laptop GPU can pick something that fits instead of OOMing:
weights (fp16) + KV cache at 16k context + headroom.
"""
LOCAL_MODEL_PRESETS = {
    "qwen3-1.7b": {
        "repo": "Qwen/Qwen3-1.7B",
        "display": "Qwen3 1.7B — laptops / 6GB VRAM",
        "approx_gb": 4,
        "note": "Fastest, smallest quality margin. Fine for simple books.",
    },
    "qwen3-4b": {
        "repo": "Qwen/Qwen3-4B-Instruct-2507",
        "display": "Qwen3 4B Instruct — 12GB+ VRAM (verified on V100 16GB)",
        "approx_gb": 11,
        "note": "The default. Verified 0.77 coverage vs 0.79 cloud on real chunks.",
    },
    "qwen3-8b": {
        "repo": "Qwen/Qwen3-8B",
        "display": "Qwen3 8B — 20GB+ VRAM",
        "approx_gb": 20,
        "note": "Best local quality. Needs a big card (A100 40GB comfortable).",
    },
}


def preset_or_default(name: str) -> tuple[str, dict]:
    """(preset_key, entry), falling back to qwen3-4b for unknown names."""
    if name not in LOCAL_MODEL_PRESETS:
        name = "qwen3-4b"
    return name, LOCAL_MODEL_PRESETS[name]
