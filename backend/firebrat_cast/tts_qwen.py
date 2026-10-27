"""Primary TTS backend: Qwen3-TTS (qwen_tts==0.1.1).

Exact qwen_tts 0.1.1 API relied on (read from the installed package
``qwen_tts/inference/qwen3_tts_model.py`` on the GPU host; model cards at
``Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`` and ``...-Base``):

- Single class ``qwen_tts.Qwen3TTSModel`` for every checkpoint (there are
  NO separate ``VoiceDesign``/``Base`` classes; "VoiceDesign" and "Base"
  are checkpoint ids / ``model.tts_model_type`` values).
- ``Qwen3TTSModel.from_pretrained(repo_or_dir, **kwargs)`` -> model.
  ``**kwargs`` pass straight into ``AutoModel.from_pretrained``
  (e.g. ``device_map="cuda:0"``, ``dtype=torch.bfloat16``,
  ``attn_implementation="flash_attention_2"``).
- ``generate_voice_design(text, instruct, language=None,
  non_streaming_mode=True, **kwargs) -> (list[np.ndarray], sr)`` --
  VoiceDesign checkpoint ONLY; ``instruct`` is the natural-language
  voice/emotion description. Raises ``ValueError`` on other checkpoints.
- ``generate_voice_clone(text, language=None, ref_audio=None,
  ref_text=None, x_vector_only_mode=False, voice_clone_prompt=None,
  non_streaming_mode=False, **kwargs) -> (list[np.ndarray], sr)`` --
  Base checkpoint ONLY; ``ref_audio`` is a wav path / URL / base64 str or
  ``(np.ndarray, sr)`` tuple. Raises ``ValueError`` on other checkpoints.
- ``create_voice_clone_prompt(ref_audio, ref_text,
  x_vector_only_mode) -> list[VoiceClonePromptItem]`` for prebuilt prompts.

Checkpoints used here: ``Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`` (anchor
minting from a text description) and ``Qwen/Qwen3-TTS-12Hz-1.7B-Base``
(line synthesis cloning the anchor).

Strategy (per SPEC): each character's timbre is fixed once via
VoiceDesign -> cached ``voices/<char_id>.wav`` + ``.json``; lines are
synthesized with the Base model cloning that anchor
(``x_vector_only_mode=True`` so only timbre transfers). The Base clone
API takes NO per-line emotion/instruct string -- that is a VoiceDesign-
only feature -- so emotion/delivery currently select the clone input
mode/fallback description rather than steering prosody directly.
A/B alternative (kept as ``use_design_per_line``): synthesize every line
with VoiceDesign using the fixed character description + emotion
appended to ``instruct``; more expressive per line but risks timbre drift
and is slower. Default is the Base-clone path.

VRAM rule: at most ONE Qwen checkpoint is resident at a time; anchor
minting temporarily swaps the design model in, then swaps back.
``unload()`` uses ``del`` + ``gc.collect()`` +
``torch.cuda.empty_cache()`` (guarded if torch is absent).

All ``qwen_tts``/``torch`` imports live inside methods so importing this
module offline (no GPU, packages missing) never fails.
"""
from __future__ import annotations

import gc
import json
import logging
from pathlib import Path
from typing import TYPE_CHECKING, Any

log = logging.getLogger(__name__)

DESIGN_MODEL = "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
BASE_MODEL = "Qwen/Qwen3-TTS-12Hz-1.7B-Base"

DEFAULT_LANGUAGE = "English"
DEFAULT_ANCHOR_TEXT = (
    "Every voice has its own colour, and this is mine. "
    "Listen closely, and you will know me anywhere."
)
DEFAULT_DESCRIPTION = "A warm, clear storytelling voice with natural pacing."

# Emotion -> instruct suffix for VoiceDesign calls (anchors + per-line fallback).
EMOTION_INSTRUCT = {
    "neutral": "in a calm, neutral tone",
    "joy": "with warm joyful energy",
    "sadness": "with gentle sadness",
    "anger": "with controlled anger",
    "fear": "with a fearful, trembling voice",
    "surprise": "with bright surprise",
    "tenderness": "tenderly, softly",
    "sarcasm": "with dry sarcasm",
    "disgust": "with cold disgust",
    "awe": "with hushed awe",
    "suspense": "in a tense, suspenseful whisper",
}

if TYPE_CHECKING:  # pragma: no cover - typing only
    import numpy as np


def _emotion_suffix(emotion: str, delivery: str) -> str:
    bits = [EMOTION_INSTRUCT.get(emotion, EMOTION_INSTRUCT["neutral"])]
    if delivery.strip():
        bits.append(delivery.strip()[:60])
    return ", ".join(bits)


class QwenVoiceEngine:
    """VoiceEngine backed by Qwen3-TTS design + base checkpoints."""

    def __init__(
        self,
        voices_dir: Path | str,
        design_model: str = DESIGN_MODEL,
        base_model: str = BASE_MODEL,
        language: str = DEFAULT_LANGUAGE,
        anchor_text: str = DEFAULT_ANCHOR_TEXT,
        descriptions: dict[str, str] | None = None,
        use_design_per_line: bool = False,
        model_kwargs: dict[str, Any] | None = None,
    ) -> None:
        self.voices_dir = Path(voices_dir)
        self.design_model = design_model
        self.base_model = base_model
        self.language = language
        self.anchor_text = anchor_text
        self.descriptions = dict(descriptions or {})
        self.use_design_per_line = use_design_per_line
        self.model_kwargs = dict(model_kwargs or {})
        self._model: Any = None
        self._resident: str | None = None  # which checkpoint is loaded

    # -- lifecycle ------------------------------------------------------
    def load(self) -> None:
        self._ensure("base")

    def unload(self) -> None:
        if self._model is None:
            self._resident = None
            return
        try:
            del self._model
        finally:
            self._model = None
            self._resident = None
            gc.collect()
            try:
                import torch

                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
            except ImportError:
                pass

    def _ensure(self, which: str) -> Any:
        """Load the requested checkpoint, evicting the other one first."""
        want = self.design_model if which == "design" else self.base_model
        if self._model is not None and self._resident == want:
            return self._model
        self.unload()  # only one model resident at a time
        from qwen_tts import Qwen3TTSModel

        log.info("Loading Qwen TTS %s (%s)", which, want)
        self._model = Qwen3TTSModel.from_pretrained(want, **self.model_kwargs)
        self._resident = want
        return self._model

    # -- anchors ---------------------------------------------------------
    def _anchor_paths(self, char: str) -> tuple[Path, Path]:
        safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in char) or "narrator"
        return self.voices_dir / f"{safe}.wav", self.voices_dir / f"{safe}.json"

    def describe(self, char: str) -> str:
        return self.descriptions.get(char, DEFAULT_DESCRIPTION)

    def anchor(self, char: str) -> Path:
        wav_path, json_path = self._anchor_paths(char)
        if wav_path.is_file() and wav_path.stat().st_size > 0:
            return wav_path
        self.voices_dir.mkdir(parents=True, exist_ok=True)
        description = self.describe(char)
        model = self._ensure("design")
        wavs, sr = model.generate_voice_design(
            text=self.anchor_text,
            instruct=f"{description}, {_emotion_suffix('neutral', '')}",
            language=self.language,
        )
        self._write_wav(wav_path, wavs[0], sr)
        json_path.write_text(
            json.dumps(
                {"speaker_id": char, "description": description, "sample_rate": sr},
                indent=2,
            )
        )
        log.info("Minted anchor %s -> %s", char, wav_path)
        return wav_path

    # -- synthesis -------------------------------------------------------
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
        if self.use_design_per_line:
            return self._speak_design(text, speaker_id, emotion, delivery)
        anchor_path = self.anchor(speaker_id)
        model = self._ensure("base")
        wavs, sr = model.generate_voice_clone(
            text=text,
            language=self.language,
            ref_audio=str(anchor_path),
            x_vector_only_mode=True,
        )
        wav = np.asarray(wavs[0], dtype=np.float32).ravel()
        return wav, int(sr)

    def _speak_design(
        self, text: str, speaker_id: str, emotion: str, delivery: str
    ) -> "tuple[np.ndarray, int]":
        """A/B path: per-line VoiceDesign with fixed description + emotion."""
        import numpy as np

        # Ensure the anchor exists first so timbre has a fixed reference.
        self.anchor(speaker_id)
        model = self._ensure("design")
        instruct = f"{self.describe(speaker_id)}, {_emotion_suffix(emotion, delivery)}"
        wavs, sr = model.generate_voice_design(
            text=text, instruct=instruct, language=self.language
        )
        return np.asarray(wavs[0], dtype=np.float32).ravel(), int(sr)

    @staticmethod
    def _write_wav(path: Path, wav: Any, sr: int) -> None:
        import numpy as np

        arr = np.asarray(wav, dtype=np.float32).ravel()
        try:
            import soundfile as sf

            sf.write(str(path), arr, sr)
        except ImportError:
            import wave

            pcm = (arr * 32767.0).clip(-32768, 32767).astype("<i2").tobytes()
            with wave.open(str(path), "wb") as f:
                f.setnchannels(1)
                f.setsampwidth(2)
                f.setframerate(sr)
                f.writeframes(pcm)
