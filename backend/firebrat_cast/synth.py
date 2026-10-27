"""Book synthesis: compiled.json + VoiceEngine -> standard Firebrat package.

``synthesize_book(compiled_path, pkg_dir, engine)`` renders every segment to
wav with the voice engine, then reuses
``firebrat.pipeline.audio_assemble.assemble_section`` (the same call
``convert.py`` Stage 3 makes) so output is the standard package:
``manifest.json`` + ``sections/<id>/audio.m4a`` + ``segments.json`` with
AAC >= 96 kbps. Resumable per section: a section whose ``segments.json``
already matches the compiled text/speakers/styles is skipped.

VoiceEngine protocol (see tts_engine.py, owned by another worker)::
    load(); unload(); anchor(char)->Path
    speak(text, speaker_id, emotion, delivery)->(np.ndarray float32, sr)

This module duck-types the engine (never imports it) so fakes work offline.
"""
from __future__ import annotations

import hashlib
import inspect
import logging
import os
import re
import struct
import wave

log = logging.getLogger(__name__)

MIN_S_PER_CHAR = 0.04  # duration sanity bounds for catching clipped/garbled output
MAX_S_PER_CHAR = 0.25
PEAK_TARGET = 0.89
SPEAK_ATTEMPTS = 3

_ABBREV = {"mr": "mister", "mrs": "missus", "ms": "miss", "dr": "doctor",
           "st": "saint", "no": "number", "lt": "lieutenant", "col": "colonel",
           "gen": "general", "rep": "representative", "sen": "senator",
           "prof": "professor", "rev": "reverend", "hon": "honorable"}
_ABBREV_RE = re.compile(r"\b(" + "|".join(sorted(_ABBREV)) + r")\.\s*", re.I)
_ROMAN_RE = re.compile(r"\b(?=[MDCLXVI]+\b)M{0,4}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})\b")
_ROMAN_VAL = dict(zip("MDCLXVI", (1000, 500, 100, 50, 10, 5, 1)))


def _roman_to_int(s: str) -> int:
    total, prev = 0, 0
    for ch in reversed(s.upper()):
        v = _ROMAN_VAL[ch]
        total, prev = (total - v, v) if v < prev else (total + v, v)
    return total


def normalize_text(text: str) -> str:
    """Make text read naturally: expand abbreviations/roman numerals/symbols."""
    t = (text or "").strip()
    if not t:
        return t
    t = re.sub(r"\s+", " ", t)
    t = _ABBREV_RE.sub(lambda m: _ABBREV[m.group(1).lower()] + " ", t)
    t = _ROMAN_RE.sub(lambda m: str(_roman_to_int(m.group(0))), t)
    t = t.replace("&", " and ").replace("%", " percent ").replace("$", " dollars ")
    t = re.sub(r"\s+", " ", t).strip()
    return t


def _as_list(audio) -> list[float]:
    """Accept numpy arrays or plain sequences; return a float list."""
    try:
        import numpy as np  # noqa

        if hasattr(audio, "tolist"):
            audio = audio.tolist()
    except ImportError:
        pass
    if isinstance(audio, (bytes, bytearray)):
        n = len(audio) // 2
        return [v / 32768.0 for v in struct.unpack(f"<{n}h", bytes(audio[: 2 * n]))]
    flat: list = []
    for v in audio:
        if isinstance(v, (list, tuple)):
            flat.extend(float(x) for x in v)  # flatten (channels, samples)
        else:
            flat.append(float(v))
    return flat


def trim_silence(samples: list[float], sr: int, thresh: float = 0.01, margin_ms: int = 30) -> list[float]:
    """Cut leading/trailing near-silence, keeping a short margin."""
    margin = int(sr * margin_ms / 1000)
    start, end = 0, len(samples)
    while start < end and abs(samples[start]) < thresh:
        start += 1
    while end > start and abs(samples[end - 1]) < thresh:
        end -= 1
    start = max(0, start - margin)
    end = min(len(samples), end + margin)
    return samples[start:end] if end > start else samples


def normalize_loudness(samples: list[float], target: float = PEAK_TARGET) -> list[float]:
    """Peak-normalize to target so voices sit at a consistent level."""
    peak = max((abs(s) for s in samples), default=0.0)
    if peak <= 1e-6:
        return samples
    gain = min(target / peak, 10.0)
    return [max(-1.0, min(1.0, s * gain)) for s in samples]


def write_wav(path: str, samples: list[float], sr: int) -> None:
    """Write mono 16-bit PCM wav with the stdlib (no numpy/scipy needed)."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    pcm = struct.pack(f"<{len(samples)}h",
                      *(max(-32768, min(32767, int(round(s * 32767)))) for s in samples))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm)


def seed_for(speaker_id: str, text: str) -> int:
    """Deterministic per-line seed so re-runs reproduce the same voice."""
    return int(hashlib.sha256(f"{speaker_id}\0{text}".encode()).hexdigest()[:8], 16)


def _speak(engine, text: str, speaker_id: str, emotion: str, delivery: str):
    """Call speak(), passing seed only if the engine accepts it."""
    try:
        params = inspect.signature(engine.speak).parameters
        if "seed" in params:
            return engine.speak(text, speaker_id, emotion, delivery, seed=seed_for(speaker_id, text))
    except (TypeError, ValueError):
        pass
    return engine.speak(text, speaker_id, emotion, delivery)


def _duration_ok(n: int, sr: int, text: str) -> bool:
    if not sr or n == 0:
        return False
    s_per_char = (n / sr) / max(1, len(text))
    return MIN_S_PER_CHAR <= s_per_char <= MAX_S_PER_CHAR


def _section_done(pkg_dir: str, section: dict, segments: list[dict]) -> bool:
    """True when segments.json exists, audio exists, and text/voices match."""
    seg_path = os.path.join(pkg_dir, "sections", section["section_id"], "segments.json")
    if not os.path.isfile(seg_path):
        return False
    audio = os.path.join(pkg_dir, "sections", section["section_id"], "audio.m4a")
    if not os.path.isfile(audio):
        audio = os.path.join(pkg_dir, "sections", section["section_id"], "audio.mp3")
        if not os.path.isfile(audio):
            return False
    try:
        from firebrat_cast.fetch import read_json

        existing = read_json(seg_path)
    except (OSError, ValueError):
        return False
    want = [(s.get("text"), s.get("speaker_id", "narrator"), s.get("voice_style", {})) for s in segments]
    got = [(s.get("text"), s.get("speaker_id", "narrator"), s.get("voice_style", {}))
           for s in existing.get("segments", [])]
    return want == got and bool(want)


def _engine_info(engine) -> dict:
    for attr in ("model_name", "model_id", "model", "name"):
        val = getattr(engine, attr, None)
        if isinstance(val, str) and val:
            return {"engine": type(engine).__name__, "model": val}
    return {"engine": type(engine).__name__, "model": type(engine).__name__}


def synthesize_book(compiled_path: str, pkg_dir: str, engine, pause_ms: int | None = None,
                    on_progress=None, assembler=None) -> dict:
    """Render the whole book. Returns {sections, skipped, segments, sample_rate}."""
    from firebrat_cast.fetch import read_json, write_json_atomic

    if assembler is None:
        from firebrat.pipeline.audio_assemble import assemble_section as assembler
    if pause_ms is None:
        try:
            from firebrat.config import PAUSE_MS as pause_ms  # type: ignore
        except ImportError:
            pause_ms = 260
    compiled = read_json(compiled_path)
    sections = compiled.get("sections", [])
    if not sections:
        raise ValueError(f"No sections in {compiled_path}")
    # Compiled must live next to the manifest so refreshes agree (same rule as convert.py).
    pkg_compiled = os.path.join(pkg_dir, "compiled.json")
    if os.path.abspath(compiled_path) != os.path.abspath(pkg_compiled):
        write_json_atomic(pkg_compiled, compiled)

    engine.load()
    try:
        wav_dir = os.path.join(pkg_dir, "_segment_wavs")
        os.makedirs(wav_dir, exist_ok=True)
        done, skipped, seg_total, sr = 0, 0, 0, 24000
        total = len(sections)
        for idx, sec in enumerate(sections):
            for si, s in enumerate(sec.get("segments", [])):
                s.setdefault("segment_id", f"{sec['section_id']}_seg_{si:04d}")
            if _section_done(pkg_dir, sec, sec["segments"]):
                log.info("Synth %s already assembled, skipping", sec["section_id"])
                skipped += 1
                continue
            wav_paths: dict[str, str] = {}
            for seg in sec["segments"]:
                text = normalize_text(seg.get("text", ""))
                if not text:
                    continue
                last_err: Exception | None = None
                for _ in range(SPEAK_ATTEMPTS):
                    audio, rate = _speak(engine, text, seg.get("speaker_id", "narrator"),
                                         (seg.get("voice_style") or {}).get("emotion", "neutral"),
                                         (seg.get("voice_style") or {}).get("delivery", ""))
                    samples = normalize_loudness(trim_silence(_as_list(audio), int(rate)))
                    sr = int(rate)
                    if samples and _duration_ok(len(samples), sr, text):
                        last_err = None
                        break
                    last_err = ValueError(
                        f"suspicious output ({len(samples) / sr:.2f}s for {len(text)} chars)")
                if last_err is not None:
                    raise RuntimeError(f"TTS failed for {seg['segment_id']} after "
                                       f"{SPEAK_ATTEMPTS} attempts: {last_err}")
                wav_path = os.path.join(wav_dir, f"{seg['segment_id']}.wav")
                write_wav(wav_path, samples, sr)
                wav_paths[seg["segment_id"]] = wav_path
                seg_total += 1
            assembler(sec, sec["segments"], wav_paths, pkg_dir, pause_ms)
            done += 1
            if on_progress is not None:
                on_progress((idx + 1) / total, sec.get("section_id", ""))
        _record_manifest(pkg_dir, compiled, engine, sr)
        return {"sections": done, "skipped": skipped, "segments": seg_total, "sample_rate": sr}
    finally:
        try:
            engine.unload()
        except Exception as e:
            log.warning("Engine unload failed (non-fatal): %s", e)


def _record_manifest(pkg_dir: str, compiled: dict, engine, sample_rate: int) -> str:
    """Ensure manifest.json exists and record narrator/cast voices + models.

    Adds a ``cast`` key (engine, model, per-speaker anchor clips) alongside the
    standard ``narrator_voice``. Extra keys are ignored by readers (same
    additive-field rule as manifest.py's source_pdf_path).
    """
    from firebrat_cast.fetch import read_json, write_json_atomic

    info = _engine_info(engine)
    anchors: dict[str, str | None] = {}
    roster = compiled.get("character_roster", []) or []
    try:
        anchor_fn = getattr(engine, "anchor", None)
        if callable(anchor_fn):
            ids = ["narrator"] + [c.get("character_id") or c.get("id") or c.get("name")
                                  for c in roster if isinstance(c, dict)]
            for cid in ids:
                if not cid:
                    continue
                try:
                    p = anchor_fn({"character_id": cid} if isinstance(cid, str) else cid)
                    anchors[str(cid)] = str(p) if p else None
                except Exception as e:
                    log.warning("Anchor for %s failed (non-fatal): %s", cid, e)
                    anchors[str(cid)] = None
    except Exception as e:  # anchors must never break synthesis
        log.warning("Anchor pass failed (non-fatal): %s", e)
    manifest_path = os.path.join(pkg_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        from firebrat.pipeline.manifest import build_manifest

        build_manifest(pkg_dir, compiled.get("book_id") or os.path.basename(pkg_dir),
                       compiled.get("title") or "Untitled", compiled.get("book_id") or "book")
    manifest = read_json(manifest_path)
    manifest["narrator_voice"] = {**manifest.get("narrator_voice", {}), **info,
                                  "sample_rate": sample_rate, "reference_clip": anchors.get("narrator")}
    manifest["cast"] = {**info, "sample_rate": sample_rate, "speakers": {
        (c.get("character_id") or c.get("name")): {
            "name": c.get("name"), "anchor": anchors.get(c.get("character_id") or c.get("name")),
            "voice_style": c.get("voice_style", {})} for c in roster if isinstance(c, dict)}}
    write_json_atomic(manifest_path, manifest)
    return manifest_path
