"""Book synthesis: compiled.json + VoiceEngine -> standard Firebrat package.

``synthesize_book(compiled_path, pkg_dir, engine)`` renders every segment to wav with the voice
engine, then reuses ``firebrat.pipeline.audio_assemble.assemble_section`` (the same call
``convert.py`` Stage 3 makes) so the output is the standard package: ``manifest.json`` +
``sections/<id>/audio.m4a`` + ``segments.json`` with AAC >= 96 kbps.

Speed: the Qwen engine is launch-bound, so segments of several consecutive sections are gathered
into one group, sorted by length and handed to ``engine.speak_many`` (batched). Engines without
``speak_many`` (Chatterbox, test fakes) are called line by line through ``speak``.

Quality guards per line: text normalisation for reading aloud, duration sanity bounds, long-silence
detection, retry with a fresh seed, best-of fallback (a book is never failed because of one line),
silence trimming, RMS loudness matching with a soft limiter, and context-dependent trailing pauses
(paragraph end > sentence end > mid-sentence fragment) baked into the segment wavs.

Resumable per section: ``sections/<id>/synth.json`` stores a fingerprint of the compiled segments
(text, speaker, emotion); a section is skipped only when it matches and its audio exists.
"""
from __future__ import annotations

import contextlib
import hashlib
import inspect
import json
import logging
import os
import re
import time
import wave

import numpy as np

log = logging.getLogger(__name__)

MIN_S_PER_CHAR = 0.035  # duration sanity bounds for catching clipped/garbled output
MAX_S_PER_CHAR = 0.25
MAX_INTERNAL_GAP_S = 1.6  # longer silence inside one line = broken generation
SPEAK_ATTEMPTS = 3
TARGET_RMS_DB = -21.0
PEAK_LIMIT = 0.97
BASE_PAUSE_MS = 120  # assembler pause between segments; tails below are added to the wavs
TAIL_MS = {"paragraph": 420, "sentence": 140, "fragment": 30}
GROUP_SEGMENTS = 320
MAX_UNIT_CHARS = 150  # long segments are spoken as sentence-sized units (memory ~ rows x frames)
UNIT_JOIN_MS = {"sentence": 150, "clause": 50}
AAC_BITRATE = "112k"

_NUMBER_OF_LETTERS = re.compile(r"[A-Za-z0-9]")


# ── text ────────────────────────────────────────────────────────────

def normalize_text(text: str) -> str:
    """Make text read naturally: abbreviations, numerals, symbols, quotes, stray punctuation."""
    from firebrat_cast.textnorm import normalize_text as _norm

    t = _norm(text or "")
    t = t.replace('"', " ")
    t = re.sub(r"(?<![A-Za-z])'|'(?![A-Za-z])", " ", t)  # quote marks, not apostrophes
    t = re.sub(r"^[\s,;:\-]+", "", t)
    t = re.sub(r"\s+", " ", t).strip()
    t = re.sub(r"\s+([,.;:!?])", r"\1", t)
    return t


_SENT_SPLIT = re.compile(r"(?<=[.!?\u2026])\s+(?=[A-Z0-9(\[])")
_CLAUSE_SPLIT = re.compile(r"(?<=[,;:])\s+")


def split_units(text: str, max_chars: int = MAX_UNIT_CHARS) -> list[tuple[str, str]]:
    """Split normalised text into speakable units: [(unit_text, join_after)].

    Sentences are packed greedily up to ``max_chars``; a sentence longer than that is cut at
    commas/semicolons. ``join_after`` is the pause class to the NEXT unit ('sentence' or 'clause';
    the last unit's value is unused). Short texts stay one unit.
    """
    text = text.strip()
    if len(text) <= max_chars:
        return [(text, "sentence")]
    pieces: list[tuple[str, str]] = []
    for sent in _SENT_SPLIT.split(text):
        if len(sent) <= max_chars:
            pieces.append((sent, "sentence"))
            continue
        clauses = _CLAUSE_SPLIT.split(sent)
        cur = ""
        for cl in clauses:
            if cur and len(cur) + 1 + len(cl) > max_chars:
                pieces.append((cur, "clause"))
                cur = cl
            else:
                cur = f"{cur} {cl}".strip()
        if cur:
            pieces.append((cur, "sentence"))
    units: list[tuple[str, str]] = []
    for piece, join in pieces:  # pack neighbours while they fit
        if units and len(units[-1][0]) + 1 + len(piece) <= max_chars:
            units[-1] = (f"{units[-1][0]} {piece}", join)
        else:
            units.append((piece, join))
    merged: list[tuple[str, str]] = []
    for unit, join in units:  # never leave an unspeakable fragment
        if merged and not _NUMBER_OF_LETTERS.search(unit):
            merged[-1] = (f"{merged[-1][0]} {unit}", join)
        else:
            merged.append((unit, join))
    return merged


def tail_kind(raw_text: str) -> str:
    """Pause class after a segment, from its ORIGINAL text (paragraph breaks survive there)."""
    if raw_text.endswith("\n\n") or raw_text.endswith("\n"):
        return "paragraph"
    stripped = raw_text.rstrip().rstrip("\"'”’»)]")
    return "sentence" if stripped[-1:] in ".!?…" else "fragment"


# ── audio ───────────────────────────────────────────────────────────

def to_array(audio) -> np.ndarray:
    """float32 mono from ndarray / tensor / list / (channels, samples) nesting."""
    if hasattr(audio, "detach"):
        audio = audio.detach().float().cpu().numpy()
    a = np.asarray(audio, dtype=np.float32)
    if a.ndim > 1:
        a = a.mean(axis=0) if a.shape[0] <= 8 and a.shape[0] < a.shape[-1] else a.reshape(-1)
    a = np.nan_to_num(a.ravel(), nan=0.0, posinf=0.0, neginf=0.0)
    return np.ascontiguousarray(a, dtype=np.float32)


def trim_silence(samples, sr: int, thresh: float = 0.01, margin_ms: int = 30) -> np.ndarray:
    """Cut leading/trailing near-silence, keeping a short margin."""
    a = to_array(samples)
    loud = np.nonzero(np.abs(a) >= thresh)[0]
    if loud.size == 0:
        return a[:0]
    margin = int(sr * margin_ms / 1000)
    return a[max(0, int(loud[0]) - margin): min(a.size, int(loud[-1]) + 1 + margin)]


def normalize_loudness(samples, sr: int = 24000, target_db: float = TARGET_RMS_DB) -> np.ndarray:
    """Match RMS across voices; scale down (never hard-clip) if the peak would exceed the limit."""
    a = to_array(samples)
    rms = float(np.sqrt(np.mean(a * a))) if a.size else 0.0
    if rms <= 1e-6:
        return a
    gain = min(10 ** (target_db / 20.0) / rms, 12.0)
    peak = float(np.max(np.abs(a))) * gain
    if peak > PEAK_LIMIT:
        gain *= PEAK_LIMIT / peak
    return a * np.float32(gain)


def max_internal_gap_s(samples, sr: int, frame_ms: int = 20, thresh_db: float = -48.0) -> float:
    """Longest run of near-silent frames (callers pass trimmed audio, so edges don't count)."""
    a = to_array(samples)
    n = max(1, int(sr * frame_ms / 1000))
    frames = a[: (a.size // n) * n].reshape(-1, n) if a.size >= n else a.reshape(1, -1)
    quiet = np.sqrt((frames ** 2).mean(axis=1)) < 10 ** (thresh_db / 20.0)
    best = run = 0
    for q in quiet:
        run = run + 1 if q else 0
        best = max(best, run)
    return best * frame_ms / 1000.0


def write_wav(path: str, samples, sr: int) -> None:
    """Write mono 16-bit PCM wav with the stdlib."""
    a = np.clip(to_array(samples), -1.0, 1.0)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    pcm = np.round(a * 32767.0).astype("<i2").tobytes()
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(sr))
        w.writeframes(pcm)


def seed_for(speaker_id: str, text: str) -> int:
    """Deterministic per-line seed so re-runs reproduce the same voice."""
    return int(hashlib.sha256(f"{speaker_id}\0{text}".encode()).hexdigest()[:8], 16)


def _duration_ok(n: int, sr: int, text: str) -> bool:
    if not sr or n == 0:
        return False
    secs, chars = n / sr, max(1, len(text))
    return min(MIN_S_PER_CHAR * chars, 8.0) <= secs <= max(MAX_S_PER_CHAR * chars, 2.0)


def _score(n: int, sr: int, text: str) -> float:
    """Distance from natural speaking rate (~0.075 s/char); lower is better."""
    return abs(n / max(sr, 1) / max(1, len(text)) - 0.075)


@contextlib.contextmanager
def _aac_bitrate(bitrate: str = AAC_BITRATE):
    """The shared assembler exports AAC without a bitrate (ffmpeg's mono default is < 96 kbps)."""
    try:
        from pydub import AudioSegment
    except ImportError:  # assembler stubbed in tests
        yield
        return
    orig = AudioSegment.export
    bitrate_default = bitrate

    def export(self, out_f=None, format="mp3", codec=None, bitrate=None, *args, **kw):
        if codec == "aac" and not bitrate:
            bitrate = bitrate_default
        return orig(self, out_f, format, codec, bitrate, *args, **kw)

    AudioSegment.export = export
    try:
        yield
    finally:
        AudioSegment.export = orig


# ── engine plumbing ─────────────────────────────────────────────────

def _speak(engine, text: str, speaker_id: str, emotion: str, delivery: str, seed: int | None = None):
    """Call speak(), passing seed only if the engine accepts it."""
    try:
        if "seed" in inspect.signature(engine.speak).parameters:
            return engine.speak(text, speaker_id, emotion, delivery,
                                seed=seed if seed is not None else seed_for(speaker_id, text))
    except (TypeError, ValueError):
        pass
    return engine.speak(text, speaker_id, emotion, delivery)


def _engine_batch(engine, jobs: list[dict], attempt: int):
    """Synthesize jobs (dicts with text/speaker_id/emotion/delivery); returns [(audio, sr)]."""
    many = getattr(engine, "speak_many", None)
    if callable(many):
        seed = (seed_for("batch", jobs[0]["text"]) + attempt) & 0x7FFFFFFF if jobs else 0
        return list(many(jobs, seed=seed))
    out = []
    for j in jobs:
        seed = seed_for(j["speaker_id"], j["text"]) if attempt == 0 else seed_for(j["speaker_id"], j["text"]) + attempt
        out.append(_speak(engine, j["text"], j["speaker_id"], j["emotion"], j["delivery"], seed=seed))
    return out


def _clean(audio, sr: int, tail_ms: int) -> np.ndarray:
    samples = normalize_loudness(trim_silence(to_array(audio), sr), sr)
    if samples.size:
        samples = np.concatenate([samples, np.zeros(int(sr * tail_ms / 1000), np.float32)])
    return samples


def _render_group(engine, jobs: list[dict]) -> dict[str, tuple[np.ndarray, int, bool]]:
    """Render jobs (each with segment_id/text/tail_ms/speaker_id/emotion/delivery) with retries.

    Returns {segment_id: (samples, sr, ok)}; ok False means best-effort fallback was used.
    """
    results: dict[str, tuple[np.ndarray, int]] = {}
    best: dict[str, tuple[float, np.ndarray, int]] = {}
    pending = sorted(jobs, key=lambda j: len(j["text"]))
    for attempt in range(SPEAK_ATTEMPTS):
        if not pending:
            break
        try:
            outs = _engine_batch(engine, pending, attempt)
        except Exception as e:  # one bad batch (OOM, garbage) must not kill the book
            log.warning("Batch of %d failed on attempt %d: %s", len(pending), attempt + 1, e)
            _free_gpu_cache()
            outs = [None] * len(pending)
        retry = []
        for job, out in zip(pending, outs):
            if out is None:
                retry.append(job)
                continue
            audio, rate = out
            sr = int(rate)
            samples = trim_silence(to_array(audio), sr)
            ok = (samples.size > 0 and _duration_ok(samples.size, sr, job["text"])
                  and max_internal_gap_s(samples, sr) <= MAX_INTERNAL_GAP_S)
            if samples.size and (job["segment_id"] not in best
                                 or _score(samples.size, sr, job["text"]) < best[job["segment_id"]][0]):
                best[job["segment_id"]] = (_score(samples.size, sr, job["text"]), samples, sr)
            if ok:
                results[job["segment_id"]] = (_clean(samples, sr, job["tail_ms"]), sr, True)
            else:
                retry.append(job)
        pending = retry
    flagged: dict[str, tuple[np.ndarray, int, bool]] = dict(results)  # type: ignore[arg-type]
    for job in pending:
        sid = job["segment_id"]
        if sid in best:
            _, samples, sr = best[sid]
            log.warning("Using best-effort audio for %s (%.1fs for %d chars): %r", sid,
                        samples.size / sr, len(job["text"]), job["text"][:60])
            flagged[sid] = (_clean(samples, sr, job["tail_ms"]), sr, False)
        else:
            log.warning("No audio for %s; inserting silence: %r", sid, job["text"][:60])
            flagged[sid] = (np.zeros(int(24000 * 0.4), np.float32), 24000, False)
    return flagged


def _free_gpu_cache() -> None:
    try:
        import gc

        import torch

        gc.collect()
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
    except Exception:
        pass


# ── resumability ────────────────────────────────────────────────────

def _fingerprint(segments: list[dict]) -> str:
    items = [(s.get("text"), s.get("speaker_id", "narrator"),
              (s.get("voice_style") or {}).get("emotion", ""),
              (s.get("voice_style") or {}).get("delivery", "")) for s in segments]
    return hashlib.sha1(json.dumps(items, ensure_ascii=False).encode()).hexdigest()


def _section_done(pkg_dir: str, section: dict, segments: list[dict]) -> bool:
    """True when the audio + segments.json exist and the stored fingerprint matches."""
    from firebrat_cast.fetch import read_json

    sec_dir = os.path.join(pkg_dir, "sections", section["section_id"])
    if not os.path.isfile(os.path.join(sec_dir, "segments.json")):
        return False
    if not any(os.path.isfile(os.path.join(sec_dir, a)) for a in ("audio.m4a", "audio.mp3")):
        return False
    try:
        meta = read_json(os.path.join(sec_dir, "synth.json"))
    except (OSError, ValueError):
        return False
    return meta.get("fingerprint") == _fingerprint(segments) and bool(segments)


def _engine_info(engine) -> dict:
    for attr in ("model_name", "model_id", "model", "name"):
        val = getattr(engine, attr, None)
        if isinstance(val, str) and val:
            return {"engine": type(engine).__name__, "model": val}
    return {"engine": type(engine).__name__, "model": type(engine).__name__}


def _segment_id(section_id: str, idx: int) -> str:
    try:
        from firebrat.utils.ids import make_segment_id

        return make_segment_id(section_id, idx)
    except ImportError:
        return f"{section_id}_seg_{idx + 1:03d}"


def _descriptions(compiled: dict) -> dict[str, str]:
    d = {c.get("character_id") or c.get("name"): c.get("voice_prompt") or c.get("description", "")
         for c in compiled.get("character_roster", []) or [] if isinstance(c, dict)}
    narr = (compiled.get("narrator") or {}).get("description")
    if narr:
        d["narrator"] = narr
    return {k: v for k, v in d.items() if k and v}


def synthesize_book(compiled_path: str, pkg_dir: str, engine, pause_ms: int | None = None,
                    on_progress=None, assembler=None) -> dict:
    """Render the whole book. Returns stats {sections, skipped, segments, sample_rate, ...}."""
    from firebrat_cast.fetch import read_json, write_json_atomic

    if assembler is None:
        from firebrat.pipeline.audio_assemble import assemble_section as assembler
    pause_ms = BASE_PAUSE_MS if pause_ms is None else pause_ms
    compiled = read_json(compiled_path)
    sections = compiled.get("sections", [])
    if not sections:
        raise ValueError(f"No sections in {compiled_path}")
    for sec in sections:
        for si, s in enumerate(sec.get("segments", [])):
            s.setdefault("segment_id", _segment_id(sec["section_id"], si))
    # Compiled must live next to the manifest so refreshes agree (same rule as convert.py).
    pkg_compiled = os.path.join(pkg_dir, "compiled.json")
    if os.path.abspath(compiled_path) != os.path.abspath(pkg_compiled):
        write_json_atomic(pkg_compiled, compiled)

    engine.load()
    t_start = time.monotonic()
    audio_s = 0.0
    try:
        if hasattr(engine, "bind_book"):
            engine.bind_book(compiled.get("book_id") or os.path.basename(pkg_dir),
                             os.path.join(pkg_dir, "voices"), _descriptions(compiled))
        pending = [s for s in sections if not _section_done(pkg_dir, s, s["segments"])]
        skipped = len(sections) - len(pending)
        if hasattr(engine, "ensure_anchors"):  # mint every anchor in one design pass, up front
            used = sorted({s.get("speaker_id", "narrator") for sec in pending for s in sec["segments"]
                           if normalize_text(s.get("text", ""))}, key=lambda c: (c != "narrator", c))
            engine.ensure_anchors(used)
        wav_dir = os.path.join(pkg_dir, "_segment_wavs")
        os.makedirs(wav_dir, exist_ok=True)
        done, seg_total, fallbacks, sr = 0, 0, 0, 24000
        groups: list[list[dict]] = []
        for sec in pending:
            if not groups or sum(len(x["segments"]) for x in groups[-1]) >= GROUP_SEGMENTS:
                groups.append([])
            groups[-1].append(sec)
        for group in groups:
            jobs, empties = [], []
            for sec in group:
                for seg in sec["segments"]:
                    text = normalize_text(seg.get("text", ""))
                    vs = seg.get("voice_style") or {}
                    if not _NUMBER_OF_LETTERS.search(text):
                        empties.append(seg["segment_id"])
                        continue
                    units = split_units(text)
                    for k, (unit, join) in enumerate(units):
                        last = k == len(units) - 1
                        jobs.append({"segment_id": f"{seg['segment_id']}#{k}", "text": unit,
                                     "speaker_id": seg.get("speaker_id", "narrator"),
                                     "emotion": vs.get("emotion", "neutral"), "delivery": vs.get("delivery", ""),
                                     "tail_ms": TAIL_MS[tail_kind(seg.get("text", ""))] if last
                                     else UNIT_JOIN_MS[join]})
                    seg["_units"] = len(units)
            rendered = _render_group(engine, jobs) if jobs else {}
            for sec in group:
                wav_paths: dict[str, str] = {}
                for seg in sec["segments"]:
                    sid = seg["segment_id"]
                    n_units = seg.pop("_units", 0)
                    if n_units:
                        parts = [rendered[f"{sid}#{k}"] for k in range(n_units)]
                        samples, sr = np.concatenate([p[0] for p in parts]), parts[0][1]
                        fallbacks += 0 if all(p[2] for p in parts) else 1
                    else:  # punctuation-only segment
                        samples, sr = np.zeros(int(24000 * 0.25), np.float32), 24000
                    path = os.path.join(wav_dir, f"{sid}.wav")
                    write_wav(path, samples, sr)
                    wav_paths[sid] = path
                    audio_s += samples.size / sr
                    seg_total += 1
                with _aac_bitrate():
                    res = assembler(sec, sec["segments"], wav_paths, pkg_dir, pause_ms)
                audio_path = (res or {}).get("audio_path", "") if isinstance(res, dict) else ""
                if audio_path.endswith(".mp3"):
                    raise RuntimeError(f"AAC export failed for {sec['section_id']} (got mp3); "
                                       "check that ffmpeg with the aac encoder is on PATH")
                write_json_atomic(os.path.join(pkg_dir, "sections", sec["section_id"], "synth.json"),
                                  {"fingerprint": _fingerprint(sec["segments"]), "engine": _engine_info(engine)})
                done += 1
                if on_progress is not None:
                    on_progress((skipped + done) / len(sections), sec.get("section_id", ""))
            wall = max(time.monotonic() - t_start, 1e-6)
            log.info("Synth %d/%d sections, %.0f s audio in %.0f s wall (x%.2f realtime)",
                     skipped + done, len(sections), audio_s, wall, audio_s / wall)
        _record_manifest(pkg_dir, compiled, engine, sr)
        wall = time.monotonic() - t_start
        return {"sections": done, "skipped": skipped, "segments": seg_total, "sample_rate": sr,
                "fallbacks": fallbacks, "audio_s": round(audio_s, 1), "wall_s": round(wall, 1),
                "realtime_x": round(audio_s / wall, 2) if wall > 0 else 0.0}
    finally:
        try:
            engine.unload()
        except Exception as e:
            log.warning("Engine unload failed (non-fatal): %s", e)


def _record_manifest(pkg_dir: str, compiled: dict, engine, sample_rate: int) -> str:
    """(Re)build manifest.json from the finished sections and record voices + models.

    Always rebuilt (a stale manifest from an earlier partial run would miss sections). Adds a
    ``cast`` key (engine, model, per-speaker anchor clip names), sets ``narrator_voice`` to the
    engine, ``content_mode`` to ``cast`` and the book author. Extra keys are ignored by readers.
    """
    from firebrat.pipeline.manifest import build_manifest

    from firebrat_cast.fetch import read_json, write_json_atomic

    info = _engine_info(engine)
    book_id = compiled.get("book_id") or os.path.basename(pkg_dir)
    build_manifest(pkg_dir, book_id, compiled.get("title") or "Untitled", book_id)
    roster = [c for c in compiled.get("character_roster", []) or [] if isinstance(c, dict)]
    voices = os.path.join(pkg_dir, "voices")

    def anchor(cid: str) -> str | None:
        safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in cid)
        return f"voices/{safe}.wav" if os.path.isfile(os.path.join(voices, f"{safe}.wav")) else None

    manifest_path = os.path.join(pkg_dir, "manifest.json")
    manifest = read_json(manifest_path)
    manifest["content_mode"] = "cast"
    if compiled.get("author"):
        manifest["author"] = compiled["author"]
    manifest["narrator_voice"] = {**manifest.get("narrator_voice", {}), **info,
                                  "engine": "qwen3-tts" if "Qwen" in info["engine"] else info["engine"],
                                  "model_class": info["engine"], "sample_rate": sample_rate,
                                  "reference_clip": anchor("narrator")}
    manifest["cast"] = {**info, "sample_rate": sample_rate,
                        "narrator": {"anchor": anchor("narrator")},
                        "speakers": {
                            (c.get("character_id") or c.get("name")): {
                                "name": c.get("name"),
                                "anchor": anchor(c.get("character_id") or c.get("name") or ""),
                                "voice_style": c.get("voice_style", {})}
                            for c in roster if anchor(c.get("character_id") or c.get("name") or "")}}
    write_json_atomic(manifest_path, manifest)
    return manifest_path
