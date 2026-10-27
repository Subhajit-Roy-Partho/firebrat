"""synth.py tests: fake engine + fake assembler, tiny fake book, no models/numpy required."""
import json
import math
import os

import pytest

from firebrat_cast import synth


def _sine(text, sr=24000, s_per_char=0.12):
    n = max(1, int(len(text) * s_per_char * sr))
    return [0.5 * math.sin(2 * math.pi * 220 * i / sr) for i in range(n)], sr


class FakeEngine:
    """Duck-typed VoiceEngine: lists instead of ndarrays (no numpy needed)."""

    def __init__(self):
        self.loaded = False
        self.spoke = []
        self.seeds = []

    def load(self):
        self.loaded = True

    def unload(self):
        self.loaded = False

    def anchor(self, char):
        cid = char.get("character_id") if isinstance(char, dict) else char
        return f"/tmp/anchors/{cid}.wav"

    def speak(self, text, speaker_id="narrator", emotion="neutral", delivery="", seed=None):
        self.spoke.append((text, speaker_id, emotion, delivery))
        self.seeds.append(seed)
        return _sine(text)


def _assembler(section, segments, wav_paths, out_dir, pause_ms=260):
    sec_dir = os.path.join(out_dir, "sections", section["section_id"])
    os.makedirs(sec_dir, exist_ok=True)
    for p in wav_paths.values():
        assert os.path.isfile(p), f"missing segment wav {p}"
    audio = os.path.join(sec_dir, "audio.m4a")
    with open(audio, "wb") as f:
        f.write(b"FAKEAAC" * 100)
    timed = [{**s, "index": i, "start_ms": i * 100, "end_ms": (i + 1) * 100}
             for i, s in enumerate(segments)]
    with open(os.path.join(sec_dir, "segments.json"), "w") as f:
        json.dump({"section_id": section["section_id"], "segments": timed}, f)
    return {"audio_path": audio, "duration_ms": len(timed) * 100}


def _book(tmp_path):
    compiled = {
        "book_id": "tiny-test",
        "title": "Tiny Test",
        "character_roster": [
            {"character_id": "char_001", "name": "Alice",
             "voice_style": {"emotion": "joy", "delivery": "laughing"}}],
        "sections": [
            {"section_id": "sec_0001", "title": "Ch 1", "source_pages": [0],
             "segments": [
                 {"text": "Alice said hello.", "speaker_id": "char_001",
                  "voice_style": {"emotion": "joy", "delivery": "laughing"}},
                 {"text": "The room was quiet.", "speaker_id": "narrator",
                  "voice_style": {}}]},
            {"section_id": "sec_0002", "title": "Ch 2", "source_pages": [1],
             "segments": [{"text": "Then they left.", "speaker_id": "narrator",
                            "voice_style": {}}]},
        ],
    }
    compiled_path = str(tmp_path / "compiled.json")
    with open(compiled_path, "w") as f:
        json.dump(compiled, f)
    pkg = str(tmp_path / "pkg")
    os.makedirs(pkg)
    return compiled_path, pkg


def test_synthesize_book_end_to_end(tmp_path):
    compiled_path, pkg = _book(tmp_path)
    eng = FakeEngine()
    stats = synth.synthesize_book(compiled_path, pkg, eng, assembler=_assembler)
    assert stats == {"sections": 2, "skipped": 0, "segments": 3, "sample_rate": 24000}
    assert eng.loaded is False  # unloaded afterwards
    assert len(eng.spoke) == 3
    assert eng.seeds[0] == synth.seed_for("char_001", "Alice said hello.")
    assert len({s for s in eng.seeds}) == 3  # distinct per line
    manifest = json.load(open(os.path.join(pkg, "manifest.json")))
    assert manifest["cast"]["engine"] == "FakeEngine"
    assert manifest["cast"]["speakers"]["char_001"]["anchor"] == "/tmp/anchors/char_001.wav"
    assert manifest["narrator_voice"]["sample_rate"] == 24000


def test_synthesize_book_resumes_finished_sections(tmp_path):
    compiled_path, pkg = _book(tmp_path)
    eng = FakeEngine()
    synth.synthesize_book(compiled_path, pkg, eng, assembler=_assembler)
    eng2 = FakeEngine()
    stats = synth.synthesize_book(compiled_path, pkg, eng2, assembler=_assembler)
    assert stats["skipped"] == 2 and stats["sections"] == 0
    assert eng2.spoke == []


def test_speak_retry_then_fail(tmp_path):
    compiled_path, pkg = _book(tmp_path)

    class Silent(FakeEngine):
        def speak(self, text, speaker_id="narrator", emotion="neutral", delivery="", seed=None):
            self.spoke.append((text, speaker_id, emotion, delivery))
            return ([0.0] * 10, 24000)  # near-empty -> fails sanity

    with pytest.raises(RuntimeError):
        synth.synthesize_book(compiled_path, pkg, Silent(), assembler=_assembler)


def test_accepts_numpy_arrays(tmp_path):
    np = pytest.importorskip("numpy")
    compiled_path, pkg = _book(tmp_path)

    class NPEngine(FakeEngine):
        def speak(self, text, speaker_id="narrator", emotion="neutral", delivery="", seed=None):
            audio, sr = _sine(text)
            return np.asarray(audio, dtype=np.float32), sr

    stats = synth.synthesize_book(compiled_path, pkg, NPEngine(), assembler=_assembler)
    assert stats["segments"] == 3


def test_normalize_text():
    t = synth.normalize_text("Mr. Darcy met Dr. Watson in St. Albans. Paid $5 & 10% for Ch. IV.")
    assert "mister" in t and "doctor" in t and "saint" in t
    assert "4" in t and "dollars" in t and "percent" in t and " and " in t


def test_trim_and_normalize():
    sr = 1000
    samples = [0.0] * 200 + [0.1, 0.2, -0.1] + [0.0] * 200
    trimmed = synth.trim_silence(samples, sr)
    assert len(trimmed) < len(samples) and len(trimmed) >= 3 + 2 * int(sr * 30 / 1000) - 2
    normed = synth.normalize_loudness([0.0, 0.25, -0.5])
    assert max(abs(s) for s in normed) == pytest.approx(0.89)


def test_write_wav_roundtrip(tmp_path):
    import wave

    p = str(tmp_path / "x.wav")
    synth.write_wav(p, [0.0, 0.5, -0.5, 1.0], 24000)
    with wave.open(p, "rb") as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 24000)
        assert w.getnframes() == 4
