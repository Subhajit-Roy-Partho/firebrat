"""Small audio helpers for the cast TTS pipeline (numpy only, no torch/scipy).

Convention: mono float32 arrays. Stereo input is averaged to mono.
Each function raises ImportError with a clear message if numpy is missing.
"""

from __future__ import annotations

import math

try:
    import numpy as np
except ImportError:  # pragma: no cover - tests importorskip numpy instead
    np = None  # type: ignore[no-redef]


def _require_numpy() -> None:
    if np is None:
        raise ImportError("firebrat_cast.audio_utils requires numpy")


def _as_mono(wav: np.ndarray) -> np.ndarray:
    """Coerce input to 1-D float32 mono (average channels if stereo)."""
    a = np.asarray(wav, dtype=np.float32)
    if a.ndim > 1:
        a = a.mean(axis=tuple(range(1, a.ndim)))
    return np.ascontiguousarray(a.ravel(), dtype=np.float32)


def trim_silence(wav: np.ndarray, sr: int,
                 thresh_db: float = -40.0, margin_ms: int = 20) -> np.ndarray:
    """Cut leading/trailing samples below thresh_db (dBFS amplitude).

    Keeps `margin_ms` of context each side (clamped to bounds); returns an
    empty float32 array if nothing exceeds the threshold.
    """
    _require_numpy()
    a = _as_mono(wav)
    if a.size == 0:
        return a
    thresh = 10.0 ** (thresh_db / 20.0)
    loud = np.nonzero(np.abs(a) > thresh)[0]
    if loud.size == 0:
        return np.zeros(0, dtype=np.float32)
    margin = int(sr * margin_ms / 1000)
    start = max(0, int(loud[0]) - margin)
    end = min(a.size, int(loud[-1]) + 1 + margin)
    return np.ascontiguousarray(a[start:end], dtype=np.float32)


def normalize_loudness(wav: np.ndarray, sr: int,
                       target_dbfs: float = -20.0) -> np.ndarray:
    """Scale so RMS equals target_dbfs; peaks clipped to [-1, 1].

    `sr` is kept for API symmetry (loudness is sample-rate independent).
    All-silence input is returned unchanged (no division by zero).
    """
    _require_numpy()
    del sr
    a = _as_mono(wav).copy()
    rms = float(np.sqrt(np.mean(a ** 2))) if a.size else 0.0
    if rms <= 0.0 or not math.isfinite(rms):
        return a
    a *= 10.0 ** (target_dbfs / 20.0) / rms
    np.clip(a, -1.0, 1.0, out=a)
    return a


def make_pause(duration_ms: int, sr: int) -> np.ndarray:
    """Return `duration_ms` milliseconds of float32 silence at `sr`."""
    _require_numpy()
    n = max(0, int(round(sr * duration_ms / 1000.0)))
    return np.zeros(n, dtype=np.float32)


def resample(wav: np.ndarray, src_sr: int, dst_sr: int) -> np.ndarray:
    """Linear-interpolation resample; output length ~= len * dst/src."""
    _require_numpy()
    if src_sr <= 0 or dst_sr <= 0:
        raise ValueError(f"sample rates must be positive: {src_sr}, {dst_sr}")
    a = _as_mono(wav)
    if src_sr == dst_sr or a.size == 0:
        return a.copy()
    n_out = max(1, int(round(a.size * dst_sr / src_sr)))
    if a.size == 1:
        return np.full(n_out, a[0], dtype=np.float32)
    old = np.linspace(0.0, 1.0, a.size)
    new = np.linspace(0.0, 1.0, n_out)
    return np.interp(new, old, a).astype(np.float32)
