"""Fallback TTS backend wrapping ``firebrat.pipeline.tts.FirebratTTS``.

Anchors are the configured Chatterbox reference clips (per-character
overrides fall back to the default ``voice_ref``). ``speak()`` renders to
a temp wav via ``FirebratTTS.synthesize`` then loads float32 mono numpy
(``soundfile`` when available, stdlib ``wave`` otherwise).

``FirebratTTS`` is imported lazily inside methods so this module imports
cleanly offline without torch/chatterbox installed.
"""
from __future__ import annotations

import gc
import logging
import tempfile
from pathlib import Path
from typing import TYPE_CHECKING, Any

log = logging.getLogger(__name__)

if TYPE_CHECKING:  # pragma: no cover - typing only
    import numpy as np

# Emotion -> Chatterbox exaggeration hint (FirebratTTS reads the
# "exaggeration" key out of the voice_style dict when supported).
EMOTION_EXAGGERATION = {
    "neutral": 0.4,
    "joy": 0.6,
    "sadness": 0.45,
    "anger": 0.65,
    "fear": 0.55,
    "surprise": 0.6,
    "tenderness": 0.35,
    "sarcasm": 0.5,
    "disgust": 0.55,
    "awe": 0.5,
    "suspense": 0.5,
}


class ChatterboxVoiceEngine:
    """VoiceEngine fallback backed by Chatterbox (FirebratTTS)."""

    def __init__(
        self,
        voice_ref: str | Path | None = None,
        character_refs: dict[str, str | Path] | None = None,
        device: str | None = None,
        exaggeration: float = 0.4,
        **tts_kwargs: Any,
    ) -> None:
        self.voice_ref = Path(voice_ref) if voice_ref else None
        self.character_refs = {k: Path(v) for k, v in (character_refs or {}).items()}
        self.device = device
        self.exaggeration = exaggeration
        self.tts_kwargs = dict(tts_kwargs)
        self._tts: Any = None

    # -- lifecycle ------------------------------------------------------
    def load(self) -> None:
        if self._tts is not None:
            return
        from firebrat.pipeline.tts import FirebratTTS

        ref = str(self.voice_ref) if self.voice_ref else None
        self._tts = FirebratTTS(
            device=self.device,
            voice_ref=ref,
            exaggeration=self.exaggeration,
            **self.tts_kwargs,
        )
        self._tts.load()

    def unload(self) -> None:
        if self._tts is None:
            return
        try:
            model = getattr(self._tts, "_model", None)
            if model is not None:
                del model
            del self._tts
        finally:
            self._tts = None
            gc.collect()
            try:
                import torch

                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
            except ImportError:
                pass

    # -- contract ---------------------------------------------------------
    def anchor(self, char: str) -> Path:
        """Return the reference clip path for a character (no synthesis)."""
        ref = self.character_refs.get(char) or self.voice_ref
        if ref is None:
            raise FileNotFoundError(
                f"No Chatterbox reference clip configured for {char!r} "
                "(pass voice_ref= or character_refs=)"
            )
        if not ref.is_file():
            raise FileNotFoundError(f"Reference clip missing for {char!r}: {ref}")
        return ref

    def speak(
        self,
        text: str,
        speaker_id: str,
        emotion: str = "neutral",
        delivery: str = "",
    ) -> "tuple[np.ndarray, int]":
        import numpy as np

        text = " ".join(text.split())
        if not text:
            raise ValueError("speak() needs non-empty text")
        self.load()
        assert self._tts is not None
        try:
            ref = self.character_refs.get(speaker_id) or self.voice_ref
            style: dict[str, Any] = {
                "exaggeration": EMOTION_EXAGGERATION.get(emotion, self.exaggeration),
            }
            if ref is not None:
                style["audio_prompt_path"] = str(ref)
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                tmp_path = tmp.name
            ok = self._tts.synthesize(text, tmp_path, voice_style=style)
            if not ok:
                raise RuntimeError(f"FirebratTTS failed for {len(text)} chars")
            return self._load_wav(tmp_path)
        finally:
            try:
                import os

                os.unlink(tmp_path)
            except (NameError, OSError):
                pass

    @staticmethod
    def _load_wav(path: str) -> "tuple[np.ndarray, int]":
        import numpy as np

        try:
            import soundfile as sf

            wav, sr = sf.read(path, dtype="float32", always_2d=True)
            return np.asarray(wav[:, 0], dtype=np.float32), int(sr)
        except ImportError:
            import wave

            with wave.open(path, "rb") as f:
                sr = f.getframerate()
                n = f.getnframes()
                raw = f.readframes(n)
                width = f.getsampwidth()
                ch = f.getnchannels()
        dtype = {1: np.int8, 2: np.int16, 4: np.int32}[width]
        arr = np.frombuffer(raw, dtype=dtype).astype(np.float32)
        if ch > 1:
            arr = arr.reshape(-1, ch)[:, 0]
        scale = float(2 ** (8 * width - 1))
        return (arr / scale).astype(np.float32), int(sr)
