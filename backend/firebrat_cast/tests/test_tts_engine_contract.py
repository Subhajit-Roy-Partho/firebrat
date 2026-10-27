"""VoiceEngine contract tests (offline: fake engine, no GPU/models)."""
from __future__ import annotations

from pathlib import Path

import pytest

np = pytest.importorskip("numpy")

from firebrat_cast.tts_engine import VoiceEngine, SynthResult, VoiceAnchor


class FakeEngine:
    """In-memory VoiceEngine for contract checks."""

    def __init__(self, sr: int = 24000) -> None:
        self.sr = sr
        self.loaded = False
        self.anchors: dict[str, Path] = {}

    def load(self) -> None:
        self.loaded = True

    def unload(self) -> None:
        self.loaded = False

    def anchor(self, char: str) -> Path:
        p = Path(f"/tmp/fake_voices/{char}.wav")
        self.anchors[char] = p
        return p

    def speak(
        self, text: str, speaker_id: str, emotion: str = "neutral", delivery: str = ""
    ) -> tuple[np.ndarray, int]:
        assert self.loaded, "speak() requires load() first"
        wav = np.zeros(int(self.sr * 0.1), dtype=np.float32)
        wav[0] = 0.5  # non-silent marker
        return wav, self.sr


def test_fake_engine_satisfies_protocol() -> None:
    eng = FakeEngine()
    assert isinstance(eng, VoiceEngine)
    eng.load()
    wav, sr = eng.speak("Hello world.", "char_001", emotion="joy", delivery="warmly")
    assert isinstance(wav, np.ndarray) and wav.dtype == np.float32
    assert wav.ndim == 1 and wav.size > 0
    assert isinstance(sr, int) and sr > 0
    assert isinstance(eng.anchor("char_001"), Path)
    eng.unload()
    assert not eng.loaded


def test_synth_result_and_anchor_dataclasses() -> None:
    wav = np.zeros(16, dtype=np.float32)
    res = SynthResult(audio=wav, sample_rate=24000)
    assert res.audio.dtype == np.float32 and res.sample_rate == 24000
    anchor = VoiceAnchor(speaker_id="char_001", path=Path("voices/char_001.wav"))
    assert anchor.speaker_id == "char_001" and anchor.path.suffix == ".wav"


def test_qwen_engine_importable_and_structural() -> None:
    mod = pytest.importorskip("firebrat_cast.tts_qwen")
    for name in ("load", "unload", "anchor", "speak"):
        assert hasattr(mod.QwenVoiceEngine, name), name
    eng = mod.QwenVoiceEngine(voices_dir="/tmp/fake_voices_qwen")
    for name in ("load", "unload", "anchor", "speak"):
        assert callable(getattr(eng, name)), name


def test_chatterbox_engine_importable_and_structural() -> None:
    mod = pytest.importorskip("firebrat_cast.tts_chatterbox")
    for name in ("load", "unload", "anchor", "speak"):
        assert hasattr(mod.ChatterboxVoiceEngine, name), name
    eng = mod.ChatterboxVoiceEngine()
    for name in ("load", "unload", "anchor", "speak"):
        assert callable(getattr(eng, name)), name
