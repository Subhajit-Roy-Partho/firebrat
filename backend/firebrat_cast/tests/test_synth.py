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
    assert (stats["sections"], stats["skipped"], stats["segments"], stats["sample_rate"]) == (2, 0, 3, 24000)
    assert stats["fallbacks"] == 0 and stats["audio_s"] > 0
    assert eng.loaded is False  # unloaded afterwards
    assert len(eng.spoke) == 3
    assert synth.seed_for("char_001", "Alice said hello.") in eng.seeds
    assert len({s for s in eng.seeds}) == 3  # distinct per line
    manifest = json.load(open(os.path.join(pkg, "manifest.json")))
    assert manifest["cast"]["engine"] == "FakeEngine"
    assert manifest["content_mode"] == "cast"
    assert manifest["narrator_voice"]["engine"] == "FakeEngine"
    assert manifest["narrator_voice"]["sample_rate"] == 24000


def test_synthesize_book_resumes_finished_sections(tmp_path):
    compiled_path, pkg = _book(tmp_path)
    eng = FakeEngine()
    synth.synthesize_book(compiled_path, pkg, eng, assembler=_assembler)
    eng2 = FakeEngine()
    stats = synth.synthesize_book(compiled_path, pkg, eng2, assembler=_assembler)
    assert stats["skipped"] == 2 and stats["sections"] == 0
    assert eng2.spoke == []


def test_silent_engine_never_fails_the_book(tmp_path):
    compiled_path, pkg = _book(tmp_path)

    class Silent(FakeEngine):
        def speak(self, text, speaker_id="narrator", emotion="neutral", delivery="", seed=None):
            self.spoke.append((text, speaker_id, emotion, delivery))
            return ([0.0] * 10, 24000)  # empty after trim -> silence placeholder

    eng = Silent()
    stats = synth.synthesize_book(compiled_path, pkg, eng, assembler=_assembler)
    assert stats["fallbacks"] == 3 and stats["segments"] == 3
    assert len(eng.spoke) == 3 * synth.SPEAK_ATTEMPTS  # retried then silence


def test_retry_uses_fresh_seed_and_recovers(tmp_path):
    compiled_path, pkg = _book(tmp_path)

    class Flaky(FakeEngine):
        def speak(self, text, speaker_id="narrator", emotion="neutral", delivery="", seed=None):
            self.seeds.append(seed)
            return _sine(text, s_per_char=0.01) if len(self.seeds) == 1 else _sine(text)

    eng = Flaky()
    stats = synth.synthesize_book(compiled_path, pkg, eng, assembler=_assembler)
    assert stats["fallbacks"] == 0
    assert len(eng.seeds) == 4 and len(set(eng.seeds)) == 4


class BatchEngine(FakeEngine):
    def __init__(self):
        super().__init__()
        self.batches = []
        self.bound = None
        self.anchors_for = None

    def bind_book(self, book_id, voices_dir, descriptions=None):
        self.bound = (book_id, voices_dir, descriptions)

    def ensure_anchors(self, chars):
        self.anchors_for = list(chars)

    def speak_many(self, items, seed=None):
        self.batches.append([i["text"] for i in items])
        return [_sine(i["text"]) for i in items]


def test_batched_engine_bound_per_book_and_sorted_by_length(tmp_path):
    compiled_path, pkg = _book(tmp_path)
    c = json.load(open(compiled_path))
    c["character_roster"][0]["description"] = "bright voice"
    c["narrator"] = {"description": "warm narrator"}
    json.dump(c, open(compiled_path, "w"))
    eng = BatchEngine()
    synth.synthesize_book(compiled_path, pkg, eng, assembler=_assembler)
    assert eng.bound[0] == "tiny-test"
    assert eng.bound[1] == os.path.join(pkg, "voices")
    assert eng.bound[2] == {"char_001": "bright voice", "narrator": "warm narrator"}
    assert eng.anchors_for == ["narrator", "char_001"]
    assert len(eng.batches) == 1 and len(eng.batches[0]) == 3  # one group, one call
    assert [len(t) for t in eng.batches[0]] == sorted(len(t) for t in eng.batches[0])
    assert not eng.spoke  # speak() unused when speak_many exists


def test_resume_detects_changed_speaker(tmp_path):
    compiled_path, pkg = _book(tmp_path)
    synth.synthesize_book(compiled_path, pkg, FakeEngine(), assembler=_assembler)
    c = json.load(open(compiled_path))
    c["sections"][1]["segments"][0]["speaker_id"] = "char_001"
    json.dump(c, open(compiled_path, "w"))
    eng = FakeEngine()
    stats = synth.synthesize_book(compiled_path, pkg, eng, assembler=_assembler)
    assert stats["skipped"] == 1 and stats["sections"] == 1


def test_punctuation_only_segment_gets_short_silence(tmp_path):
    compiled_path, pkg = _book(tmp_path)
    c = json.load(open(compiled_path))
    c["sections"][1]["segments"].append({"text": " \u2014 ", "speaker_id": "narrator", "voice_style": {}})
    json.dump(c, open(compiled_path, "w"))
    eng = FakeEngine()
    stats = synth.synthesize_book(compiled_path, pkg, eng, assembler=_assembler)
    assert stats["segments"] == 4 and len(eng.spoke) == 3


def test_tail_kind():
    assert synth.tail_kind("It ended.\n\n") == "paragraph"
    assert synth.tail_kind("\u201cWell!\u201d") == "sentence"
    assert synth.tail_kind("thought Alice to herself, ") == "fragment"


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
    t = synth.normalize_text("Mr. Darcy met Dr. Watson in St. Albans. Paid $5 & 10% for it.")
    assert "Mister" in t or "mister" in t
    assert "doctor" in t.lower() and "saint" in t.lower()
    assert "dollars" in t and "percent" in t and " and " in t


def test_normalize_text_strips_quotes_and_leading_punctuation():
    assert synth.normalize_text(", but \u201cWell!\u201d said she \u2014 and left.") == "but Well! said she, and left."
    assert synth.normalize_text("\u2018Tis the dog\u2019s bone") .endswith("dog's bone")


def test_trim_and_normalize():
    sr = 1000
    samples = [0.0] * 200 + [0.1, 0.2, -0.1] + [0.0] * 200
    trimmed = synth.trim_silence(samples, sr)
    assert len(trimmed) < len(samples) and len(trimmed) >= 3 + 2 * int(sr * 30 / 1000) - 2
    normed = synth.normalize_loudness([0.0, 0.25, -0.5], sr)
    assert max(abs(normed)) <= synth.PEAK_LIMIT + 1e-6  # limited, not hard clipped
    quiet = synth.normalize_loudness([0.01, -0.01] * 100, sr)
    assert float((quiet ** 2).mean() ** 0.5) == pytest.approx(10 ** (synth.TARGET_RMS_DB / 20), rel=1e-3)


def test_internal_gap_detection():
    sr = 1000
    ok = [0.3] * 500 + [0.0] * 100 + [0.3] * 500
    bad = [0.3] * 500 + [0.0] * 2500 + [0.3] * 500
    assert synth.max_internal_gap_s(ok, sr) < synth.MAX_INTERNAL_GAP_S
    assert synth.max_internal_gap_s(bad, sr) > synth.MAX_INTERNAL_GAP_S


def test_write_wav_roundtrip(tmp_path):
    import wave

    p = str(tmp_path / "x.wav")
    synth.write_wav(p, [0.0, 0.5, -0.5, 1.0], 24000)
    with wave.open(p, "rb") as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 24000)
        assert w.getnframes() == 4


def test_split_units_packs_sentences_and_cuts_long_ones_at_commas():
    short = "Down, down, down. Would the fall never come to an end?"
    assert synth.split_units(short) == [(short, "sentence")]
    long_text = ("Alice was beginning to get very tired of sitting by her sister on the bank. " * 4).strip()
    units = synth.split_units(long_text)
    assert len(units) >= 3 and all(len(u) <= synth.MAX_UNIT_CHARS for u, _ in units)
    assert " ".join(u for u, _ in units) == long_text  # nothing lost
    clauses = ("she considered, in her own mind, as well as she could, for the hot day made her feel very sleepy and stupid, "
               "whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, "
               "when suddenly a White Rabbit with pink eyes ran close by her")
    cu = synth.split_units(clauses)
    assert len(cu) >= 2 and all(len(u) <= synth.MAX_UNIT_CHARS for u, _ in cu)
    assert cu[0][1] == "clause"
    assert " ".join(u for u, _ in cu) == clauses


def test_long_segment_is_spoken_in_units_and_joined(tmp_path):
    compiled_path, pkg = _book(tmp_path)
    c = json.load(open(compiled_path))
    long_text = " ".join(f"Sentence number {i} is here to be read aloud nicely." for i in range(8))
    c["sections"][1]["segments"][0]["text"] = long_text
    json.dump(c, open(compiled_path, "w"))
    eng = BatchEngine()
    stats = synth.synthesize_book(compiled_path, pkg, eng, assembler=_assembler)
    spoken = [t for b in eng.batches for t in b]
    assert len(spoken) > 3 and max(len(t) for t in spoken) <= synth.MAX_UNIT_CHARS
    assert stats["segments"] == 3 and stats["fallbacks"] == 0
    assert stats["audio_s"] > len(long_text) * 0.1  # all units concatenated into the segment wav
