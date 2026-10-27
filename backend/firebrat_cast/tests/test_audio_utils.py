"""Tests for firebrat_cast.audio_utils (skipped entirely without numpy)."""

import pytest

np = pytest.importorskip("numpy")

from firebrat_cast import audio_utils


def _sine(sr: int, seconds: float, amp: float = 0.5) -> np.ndarray:
    t = np.arange(int(sr * seconds), dtype=np.float32) / sr
    return (amp * np.sin(2 * np.pi * 440.0 * t)).astype(np.float32)


def _dbfs(wav: np.ndarray) -> float:
    return 20.0 * float(np.log10(np.sqrt(np.mean(wav ** 2))))


def test_trim_silence():
    sr = 16000
    wav = np.concatenate([np.zeros(8000, dtype=np.float32),
                          _sine(sr, 1.0),
                          np.zeros(8000, dtype=np.float32)])
    out = audio_utils.trim_silence(wav, sr)
    assert out.dtype == np.float32
    assert abs(len(out) - (16000 + 2 * 320)) <= 2  # 20 ms margin = 320 samples
    assert np.max(np.abs(out)) > 0.01


def test_trim_silence_custom_margin_and_thresh():
    sr = 8000
    wav = np.concatenate([np.zeros(1000, dtype=np.float32), _sine(sr, 0.5)])
    out = audio_utils.trim_silence(wav, sr, thresh_db=-20.0, margin_ms=0)
    assert abs(len(out) - 4000) <= 2


def test_trim_all_silence_returns_empty():
    out = audio_utils.trim_silence(np.zeros(1000, dtype=np.float32), 16000)
    assert out.dtype == np.float32
    assert out.size == 0


def test_normalize_loudness():
    sr = 16000
    out = audio_utils.normalize_loudness(_sine(sr, 1.0, amp=0.02), sr)
    assert out.dtype == np.float32
    assert abs(_dbfs(out) - (-20.0)) < 0.5
    assert float(np.max(np.abs(out))) <= 1.0


def test_normalize_silence_is_safe():
    out = audio_utils.normalize_loudness(np.zeros(500, dtype=np.float32), 16000)
    assert out.dtype == np.float32
    assert np.all(out == 0.0)


def test_make_pause():
    pause = audio_utils.make_pause(250, 16000)
    assert pause.dtype == np.float32
    assert pause.shape == (4000,)
    assert np.all(pause == 0.0)
    assert audio_utils.make_pause(0, 16000).shape == (0,)


def test_resample_length_ratio():
    sr, wav = 16000, _sine(16000, 1.0)
    down = audio_utils.resample(wav, 16000, 8000)
    assert down.dtype == np.float32
    assert down.shape == (8000,)
    up = audio_utils.resample(wav, 16000, 32000)
    assert up.shape == (32000,)
    # content preserved: still a ~440 Hz tone (peak away from DC/edges)
    spectrum = np.abs(np.fft.rfft(down))
    peak = int(np.argmax(spectrum[1:]) + 1)
    assert abs(peak - 440) <= 5  # 1 Hz bins at 8 kHz / 8000 samples


def test_resample_same_rate_copies():
    wav = _sine(16000, 0.1)
    out = audio_utils.resample(wav, 16000, 16000)
    assert out is not wav
    assert np.array_equal(out, wav)
