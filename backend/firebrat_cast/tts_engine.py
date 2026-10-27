"""Shared TTS engine contract for firebrat_cast.

Defines the VoiceEngine protocol plus the minimal shared dataclasses.
Keep this module dependency-light: numpy appears only under
TYPE_CHECKING so offline/unit-test imports never need it.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Protocol, runtime_checkable

if TYPE_CHECKING:  # pragma: no cover - typing only
    import numpy as np


@dataclass(frozen=True)
class VoiceAnchor:
    """Cached reference clip identifying one character's timbre."""

    speaker_id: str
    path: Path
    description: str = ""
    sample_rate: int = 0
    meta: dict = field(default_factory=dict)


@dataclass(frozen=True)
class SynthResult:
    """Single utterance synthesis result (float32 mono + sample rate)."""

    audio: "np.ndarray"
    sample_rate: int


@runtime_checkable
class VoiceEngine(Protocol):
    """Minimal contract every TTS backend must satisfy."""

    def load(self) -> None:
        """Load model weights (lazy; safe to call twice)."""
        ...

    def unload(self) -> None:
        """Free model weights / VRAM (safe to call when unloaded)."""
        ...

    def anchor(self, char: str) -> Path:
        """Return cached anchor wav path for a character, creating it if needed."""
        ...

    def speak(
        self,
        text: str,
        speaker_id: str,
        emotion: str = "neutral",
        delivery: str = "",
    ) -> "tuple[np.ndarray, int]":
        """Synthesize text -> (float32 mono waveform, sample rate)."""
        ...
