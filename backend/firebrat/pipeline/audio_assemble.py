"""Per-section concatenation with sample-accurate segment timing.

Adapted from alexandria's compute_timeline() pattern: walk ordered
(segment, AudioSegment) pairs and track cursor_ms from actual durations.
"""
import json
import logging
import os
import tempfile
import shutil
import subprocess

from firebrat.config import PAUSE_MS, SAMPLE_RATE

log = logging.getLogger(__name__)


def _load_segment(path: str):
    from pydub import AudioSegment
    return AudioSegment.from_file(path)


def _maybe_load_ffmpeg_module():
    # ffmpeg module load is shell-only; in-process check: try finding binary
    from firebrat.utils.audio_utils import find_ffmpeg
    ff = find_ffmpeg()
    if ff:
        os.environ.setdefault("FFMPEG_BINARY", ff)
        # pydub looks at which("ffmpeg") — ensure PATH sees it
        d = os.path.dirname(ff)
        if d not in os.environ.get("PATH", ""):
            os.environ["PATH"] = d + ":" + os.environ.get("PATH", "")
    return ff


def compute_timeline(segments: list[dict], wav_paths: dict[str, str],
                     pause_ms: int = PAUSE_MS) -> list[dict]:
    """Return timed segments with start_ms/end_ms from actual wav durations.

    segments: ordered list of {segment_id, type, text, ref, visually_essential, ...}
    wav_paths: {segment_id: wav_path}
    """
    from pydub import AudioSegment
    timed: list[dict] = []
    cursor = 0
    for idx, seg in enumerate(segments):
        sid = seg["segment_id"]
        wav_path = wav_paths.get(sid)
        if wav_path and os.path.isfile(wav_path):
            audio = _load_segment(wav_path)
            dur = len(audio)  # pydub duration in ms, sample-accurate
        else:
            # fallback: estimate 150ms per word, at least 600ms
            words = max(1, len(seg.get("text", "").split()))
            dur = max(600, words * 150)
            log.warning("Missing wav for %s, estimating duration %d ms", sid, dur)

        start = cursor
        end = start + dur
        timed.append({
            **seg,
            "index": idx,
            "start_ms": start,
            "end_ms": end,
        })
        cursor = end + pause_ms
    # Trim trailing pause (cursor includes last segment's following pause)
    if timed:
        cursor -= pause_ms
    return timed, cursor  # timed list + total duration


def assemble_section(section: dict, segments: list[dict],
                     wav_paths: dict[str, str],
                     out_dir: str,
                     pause_ms: int = PAUSE_MS,
                     sample_rate: int = SAMPLE_RATE) -> dict:
    """Concatenate wavs for one section, export audio.m4a + segments.json.

    section: {section_id, title, ...}
    segments: ordered segment dicts (must each have segment_id)
    wav_paths: {segment_id: wav_path}
    out_dir: package dir (e.g. backend/output/<book_id>)

    Returns {audio_path, segments_path, duration_ms}
    """
    _maybe_load_ffmpeg_module()
    from pydub import AudioSegment

    section_id = section["section_id"]
    sec_dir = os.path.join(out_dir, "sections", section_id)
    os.makedirs(sec_dir, exist_ok=True)

    if not segments:
        log.warning("Section %s has no segments, writing placeholder", section_id)
        silence = AudioSegment.silent(duration=400, frame_rate=sample_rate)
        out_audio = os.path.join(sec_dir, "audio.m4a")
        try:
            silence.export(out_audio, format="ipod", codec="aac")
        except Exception:
            out_audio = os.path.join(sec_dir, "audio.mp3")
            silence.export(out_audio, format="mp3")
        out_seg = os.path.join(sec_dir, "segments.json")
        with open(out_seg, "w", encoding="utf-8") as f:
            json.dump({"section_id": section_id, "sample_rate": sample_rate,
                       "pause_ms_between_segments": pause_ms, "segments": []},
                      f, indent=2)
        return {"audio_path": out_audio, "segments_path": out_seg, "duration_ms": 400}

    timed, total_ms = compute_timeline(segments, wav_paths, pause_ms)

    # Build combined AudioSegment
    combined = None
    for seg in timed:
        wav_path = wav_paths.get(seg["segment_id"])
        if wav_path and os.path.isfile(wav_path):
            seg_audio = _load_segment(wav_path)
        else:
            seg_audio = AudioSegment.silent(duration=seg["end_ms"] - seg["start_ms"],
                                            frame_rate=sample_rate)
        if combined is None:
            combined = seg_audio
        else:
            combined += AudioSegment.silent(duration=pause_ms, frame_rate=sample_rate) + seg_audio

    assert combined is not None

    # Export — prefer aac/m4a, fall back to mp3
    out_audio_m4a = os.path.join(sec_dir, "audio.m4a")
    out_audio = out_audio_m4a
    try:
        combined.export(out_audio_m4a, format="ipod", codec="aac")
    except Exception as e:
        log.warning("AAC export failed (%s), falling back to mp3: %s", out_audio_m4a, e)
        out_audio = os.path.join(sec_dir, "audio.mp3")
        combined.export(out_audio, format="mp3")

    # Write segments.json with timing
    from firebrat.pipeline.schema import SegmentsFile, TimedSegment
    seg_models = [TimedSegment(
        segment_id=s["segment_id"], index=s["index"], type=s["type"],
        text=s["text"], ref=s.get("ref"), start_ms=s["start_ms"], end_ms=s["end_ms"],
        visually_essential=s.get("visually_essential", False),
    ) for s in timed]
    sf = SegmentsFile(section_id=section_id, sample_rate=sample_rate,
                      pause_ms_between_segments=pause_ms, segments=seg_models)
    out_seg = os.path.join(sec_dir, "segments.json")
    with open(out_seg, "w", encoding="utf-8") as f:
        json.dump(json.loads(sf.model_dump_json()), f, ensure_ascii=False, indent=2)

    # Cleanup per-segment wavs now that combined exists (optional — keep for debug if env flag)
    if os.environ.get("FIREBRAT_KEEP_SEGMENT_WAVS") != "1":
        for p in wav_paths.values():
            try:
                os.remove(p)
            except OSError:
                pass

    log.info("Assembled %s: %d segments, %d ms -> %s", section_id, len(timed), total_ms, out_audio)
    return {"audio_path": out_audio, "segments_path": out_seg, "duration_ms": total_ms}


def assemble_all(compiled_path: str, segment_wavs_dir: str, output_dir: str,
                 pause_ms: int = PAUSE_MS) -> list[dict]:
    """Assemble all sections from compiled.json. Returns per-section results.

    compiled_path: path to compiled.json
    segment_wavs_dir: dir containing per-segment wavs (keyed by segment_id)
    output_dir: package dir
    """
    with open(compiled_path, "r", encoding="utf-8") as f:
        compiled = json.load(f)

    # Discover all segment wavs
    wav_map: dict[str, str] = {}
    if os.path.isdir(segment_wavs_dir):
        for fname in os.listdir(segment_wavs_dir):
            if fname.endswith(".wav"):
                sid = os.path.splitext(fname)[0]
                wav_map[sid] = os.path.join(segment_wavs_dir, fname)

    results: list[dict] = []
    for sec in compiled.get("sections", []):
        # segments in compiled may not yet have segment_ids — assign here deterministically
        from firebrat.utils.ids import make_segment_id
        segs = sec.get("segments", [])
        for idx, s in enumerate(segs):
            s.setdefault("segment_id", make_segment_id(sec["section_id"], idx))
        results.append(assemble_section(sec, segs, wav_map, output_dir, pause_ms))
    return results
