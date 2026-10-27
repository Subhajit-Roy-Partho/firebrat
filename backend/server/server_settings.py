"""Device-controlled server settings for the cast scheduler and queue.

Persisted as <data>/server_settings.json (same dir as the jobs DB), written
atomically (tmp file + os.replace) and audit-logged. Invalid files fall back
to defaults() with a logged warning, so a hand-edited typo can never wedge the
server. Every model choice is validated against firebrat_cast.catalog, the
single model catalog shared with the scheduler (INTEGRATION2 decision 4).

The cast scheduler hot-reloads by calling read_server_settings() before
every phase (no restart needed); `paused` takes effect on its next check.
"""

import json
import logging
import os
import re
import tempfile

from firebrat_cast import catalog
from server import config

log = logging.getLogger("firebrat.server.settings")

_HHMM = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


def defaults() -> dict:
    """Decision 3 defaults. Call-time so the upload limit follows
    FIREBRAT_MAX_UPLOAD_MB when the admin never changed it."""
    return {
        "llm": {"model": catalog.DEFAULT_LLM_ID, "quantization": "fp8"},
        "tts": {"engine": catalog.DEFAULT_TTS_ID},
        "run_pattern": {
            "phase_mode": "batched",
            "max_books_per_llm_phase": 4,
            "audio_order": "shortest_first",
            "paused": False,
            "quiet_hours": None,  # window with NO new GPU phase (wraps midnight)
        },
        "limits": {"max_upload_mb": max(1, min(4096, int(config.MAX_UPLOAD_MB))),
                   "max_cast_chars": 200000},
    }


DEFAULTS = defaults()  # import-time snapshot, for reference only


def SETTINGS_PATH() -> str:
    """Call-time (never frozen) so tests can relocate the data dir."""
    return os.path.join(os.path.dirname(config.JOBS_DB_PATH), "server_settings.json")


def _hf_cache_root() -> str:
    return catalog.hf_home()


def build_options() -> dict:
    """Selectable catalog for the admin UI. Every entry carries id, name,
    vram_gb, description and available (weights present in $HF_HOME/hub).
    Never free text: validate_values only accepts these ids."""
    opts = catalog.all_options()
    return {
        "llm": {"models": opts["llm"], "quantizations": ["fp8"]},
        "tts": {"engines": opts["tts"]},
        "run_pattern": {
            "phase_modes": ["batched", "sequential"],
            "audio_orders": ["shortest_first", "fifo"],
            "max_books_range": [1, 20],
        },
        "limits": {
            "max_upload_mb_range": [1, 4096],
            "max_cast_chars_range": [1000, 50000000],
        },
    }


def validate_values(values: dict) -> dict:
    """Validate a full settings dict, returning a cleaned copy.

    Raises ValueError naming the offending field; unknown sections or keys
    are rejected (never silently ignored) so typos surface as 422.
    """
    if not isinstance(values, dict):
        raise ValueError("settings must be an object")
    unknown = set(values) - set(defaults())
    if unknown:
        raise ValueError(f"unknown settings section: {sorted(unknown)[0]}")
    llm_ids = set(catalog.LLM_MODELS)
    tts_ids = set(catalog.TTS_ENGINES)
    out: dict = {}

    llm = values.get("llm", {})
    if not isinstance(llm, dict) or set(llm) - {"model", "quantization"}:
        raise ValueError("llm needs exactly {model, quantization}")
    if llm.get("model") not in llm_ids:
        raise ValueError(f"llm.model must be one of {sorted(llm_ids)}")
    if llm.get("quantization") != "fp8":
        raise ValueError("llm.quantization must be 'fp8'")
    out["llm"] = {"model": llm["model"], "quantization": "fp8"}

    tts = values.get("tts", {})
    if not isinstance(tts, dict) or set(tts) - {"engine"}:
        raise ValueError("tts needs exactly {engine}")
    if tts.get("engine") not in tts_ids:
        raise ValueError(f"tts.engine must be one of {sorted(tts_ids)}")
    out["tts"] = {"engine": tts["engine"]}

    rp = values.get("run_pattern", {})
    if not isinstance(rp, dict) or set(rp) - {
            "phase_mode", "max_books_per_llm_phase", "audio_order",
            "paused", "quiet_hours"}:
        raise ValueError("run_pattern has unknown or missing keys")
    if rp.get("phase_mode") not in ("batched", "sequential"):
        raise ValueError("run_pattern.phase_mode must be 'batched' or 'sequential'")
    n = rp.get("max_books_per_llm_phase")
    if isinstance(n, bool) or not isinstance(n, int) or not 1 <= n <= 20:
        raise ValueError("run_pattern.max_books_per_llm_phase must be an int 1..20")
    if rp.get("audio_order") not in ("shortest_first", "fifo"):
        raise ValueError("run_pattern.audio_order must be 'shortest_first' or 'fifo'")
    if not isinstance(rp.get("paused"), bool):
        raise ValueError("run_pattern.paused must be a bool")
    qh = rp.get("quiet_hours")
    if qh is not None:
        if (not isinstance(qh, dict) or set(qh) != {"start", "end"}
                or not _HHMM.match(str(qh.get("start", "")))
                or not _HHMM.match(str(qh.get("end", "")))):
            raise ValueError("run_pattern.quiet_hours must be null or {start,end} HH:MM")
        qh = {"start": qh["start"], "end": qh["end"]}
    out["run_pattern"] = {
        "phase_mode": rp["phase_mode"],
        "max_books_per_llm_phase": n,
        "audio_order": rp["audio_order"],
        "paused": rp["paused"],
        "quiet_hours": qh,
    }

    lim = values.get("limits", {})
    if not isinstance(lim, dict) or set(lim) - {"max_upload_mb", "max_cast_chars"}:
        raise ValueError("limits needs exactly {max_upload_mb, max_cast_chars}")
    for key, lo, hi in (("max_upload_mb", 1, 4096), ("max_cast_chars", 1000, 50000000)):
        v = lim.get(key)
        if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
            raise ValueError(f"limits.{key} must be an int {lo}..{hi}")
    out["limits"] = {"max_upload_mb": lim["max_upload_mb"],
                     "max_cast_chars": lim["max_cast_chars"]}
    return out


def read_server_settings() -> dict:
    """Current values (the scheduler's hot-reload hook calls this before
    every phase). Invalid files fall back to defaults with a logged warning."""
    values = defaults()
    try:
        if os.path.isfile(SETTINGS_PATH()):
            with open(SETTINGS_PATH(), "r", encoding="utf-8") as f:
                stored = json.load(f)
            values = validate_values(stored)
    except (OSError, ValueError) as e:
        log.warning("server_settings.json invalid (%s), using defaults", e)
        values = defaults()
    return values


def write_server_settings(patch: dict, actor_uid: str = "") -> dict:
    """Merge a (possibly partial) patch over current values, validate the
    whole, persist atomically, audit-log, and return the new values."""
    if not isinstance(patch, dict):
        raise ValueError("settings patch must be an object")
    merged = read_server_settings()
    for section, part in patch.items():
        if section not in merged:
            raise ValueError(f"unknown settings section: {section}")
        if not isinstance(part, dict):
            raise ValueError(f"{section} must be an object")
        merged[section] = {**merged.get(section, {}), **part}
    values = validate_values(merged)
    path = SETTINGS_PATH()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="server_settings.", suffix=".tmp",
                               dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(values, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)  # atomic: the scheduler never sees a torn file
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    if actor_uid:
        from server import iam as _iam
        _iam.audit(actor_uid, "settings_update", "server_settings",
                   json.dumps(values, sort_keys=True))
    return values


def settings_view() -> dict:
    """GET /admin/settings payload: values + selectable options (with VRAM
    hints and weight availability) + cache provenance + human notes."""
    return {
        "values": read_server_settings(),
        "options": build_options(),
        "availability": catalog.availability(),
        "notes": ("Quantization is fixed to fp8. The scheduler re-reads these "
                  "values before every phase; paused stops GPU work without a "
                  "restart. Restart the shim/container only when changing the "
                  "local LLM preset under /settings."),
    }
