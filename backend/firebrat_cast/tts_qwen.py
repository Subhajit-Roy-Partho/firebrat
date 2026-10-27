"""Primary TTS backend: Qwen3-TTS (qwen_tts==0.1.1).

Exact qwen_tts 0.1.1 API relied on (read from the installed package
``qwen_tts/inference/qwen3_tts_model.py`` on the GPU host):

- One class ``qwen_tts.Qwen3TTSModel`` for every checkpoint. ``from_pretrained(path, **kw)``
  forwards ``kw`` to ``AutoModel.from_pretrained`` (``device_map``, ``dtype``, ...).
  With ``HF_HUB_OFFLINE=1`` it must be given a LOCAL snapshot directory (a repo id makes
  the tokenizer patch call ``model_info`` and crash), hence ``_snapshot()`` below.
- ``generate_voice_design(text, instruct, language)`` (VoiceDesign checkpoint only) and
  ``generate_voice_clone(text, language, ref_audio | voice_clone_prompt, ref_text,
  x_vector_only_mode)`` (Base checkpoint only). BOTH accept lists, so a whole batch of
  different lines / voices is one call. Output: ``(list[np.ndarray float32], 24000)``.
- ``create_voice_clone_prompt(ref_audio=(np, sr), ref_text, x_vector_only_mode)`` ->
  ``list[VoiceClonePromptItem]`` (prebuilt prompt, cached per speaker here).

Design decision (measured on the RTX 4080, Alice, 5 voices x 3 lines, whisper+resemblyzer):

=====================  ===============  ==================  ==========
path                   same-voice cos   different-voice cos  speed (RTF)
=====================  ===============  ==================  ==========
per-line VoiceDesign   0.70-0.73        0.56-0.60            2.1-2.6
Base clone, ICL        0.90             0.58                 3.2
Base clone, x-vector   0.89             0.58                 3.8   <- default
=====================  ===============  ==================  ==========

Per-line design is the most expressive but the timbre drifts from line to line (pitch of the
same character varied 90 -> 160 Hz), which is unacceptable for a book. So: VoiceDesign mints ONE
anchor clip per character (cached ``voices/<id>.wav`` + ``.json``) and every line is spoken with
the Base model cloning that anchor's speaker embedding (``x_vector_only_mode``). The clone API
takes no emotion instruct; expression comes from the text/punctuation. ``mode="design"`` keeps the
per-line path available.

Throughput: generation is CPU/launch bound (GPU ~15% busy), so the wall time of a call is almost
independent of the batch size; ``speak_many`` therefore synthesises whole batches (default 96).

VRAM: one checkpoint resident at a time (design for anchors, then base).
All ``qwen_tts``/``torch`` imports are lazy so importing this module offline never fails.
"""
from __future__ import annotations

import gc
import json
import logging
import os
import re
from pathlib import Path
from typing import TYPE_CHECKING, Any, Sequence

log = logging.getLogger(__name__)

DESIGN_MODEL = "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
BASE_MODEL = "Qwen/Qwen3-TTS-12Hz-1.7B-Base"

DEFAULT_LANGUAGE = "English"
DEFAULT_ANCHOR_TEXT = (
    "Every voice has its own colour, and this is mine. "
    "Listen closely, and you will know me anywhere, whether I speak softly or raise my voice."
)
DEFAULT_DESCRIPTION = "A warm, clear storytelling voice with natural pacing."
NARRATOR_ID = "narrator"
ANCHOR_BATCH = 8
DEDUPE_ROUNDS = 2
DEDUPE_COSINE = 0.6  # mean-centred x-vector cosine; Alice/Duchess 0.65, unrelated voices < 0.35
CONTRAST_FEMALE = ["A deep, throaty alto", "A bright, light soprano", "A nasal, thin, reedy voice",
                   "A soft, breathy, gentle voice", "A sing-song, lilting voice", "A crisp, clipped, precise voice"]
CONTRAST_MALE = ["A deep, gravelly bass", "A light, quick tenor", "A nasal, reedy voice",
                 "A warm, rounded baritone", "A rough, weathered voice", "A soft-spoken, mild voice"]
CONTRAST_TRAITS = CONTRAST_FEMALE + CONTRAST_MALE
TOKENS_PER_SECOND = 12.5  # 12 Hz codec
MAX_TOKENS_PER_CHAR = 2.2  # ~0.18 s/char, far above natural speech (~0.07 s/char)

# Emotion -> instruct suffix for VoiceDesign calls (anchors + per-line design mode).
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


def _snapshot(repo: str) -> str:
    """Local snapshot directory of a cached HF repo (needed with HF_HUB_OFFLINE=1)."""
    if os.path.isdir(repo):
        return repo
    try:
        from huggingface_hub import snapshot_download

        return snapshot_download(repo, local_files_only=True)
    except Exception:  # not cached / hub missing: let from_pretrained try the id
        return repo


def _safe_name(char: str) -> str:
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in char) or NARRATOR_ID


DECODE_CHUNK = 6


def patch_decoder_batching(model: Any, chunk: int = DECODE_CHUNK) -> None:
    """Decode codec frames a few rows at a time.

    The 12 Hz speech-tokenizer decoder upsamples a whole batch to 24 kHz at once; for 64 rows that
    peak (~10 GB) is what runs the GPU out of memory, not the talker. Splitting only the decode keeps
    the generation batch large (the speed lever) and the peak small.
    """
    tok = getattr(getattr(model, "model", None), "speech_tokenizer", None)
    orig = getattr(tok, "decode", None)
    if tok is None or orig is None or getattr(orig, "_firebrat_chunked", False):
        return

    def decode(items, *args, **kwargs):
        if len(items) <= chunk:
            return orig(items, *args, **kwargs)
        wavs: list = []
        fs = None
        for i in range(0, len(items), chunk):
            part, fs = orig(items[i:i + chunk], *args, **kwargs)
            wavs.extend(part)
        return wavs, fs

    decode._firebrat_chunked = True  # type: ignore[attr-defined]
    tok.decode = decode


def expected_frames(text: str) -> int:
    """Frames a line really takes (~1 per char at natural pace) + prompt/context; drives batch memory."""
    return int(len(text) * 1.3) + 30


def max_new_tokens_for(texts: Sequence[str]) -> int:
    """Hard cap on generated codec frames so a runaway line cannot spin for 2048 steps."""
    longest = max((len(t) for t in texts), default=1)
    return int(min(2048, max(48, longest * MAX_TOKENS_PER_CHAR + 40)))


class QwenVoiceEngine:
    """VoiceEngine backed by the Qwen3-TTS design (anchors) + base (lines) checkpoints."""

    def __init__(
        self,
        voices_dir: Path | str | None = None,
        design_model: str = DESIGN_MODEL,
        base_model: str = BASE_MODEL,
        language: str = DEFAULT_LANGUAGE,
        anchor_text: str = DEFAULT_ANCHOR_TEXT,
        descriptions: dict[str, str] | None = None,
        use_design_per_line: bool | None = None,
        model_kwargs: dict[str, Any] | None = None,
        batch_size: int | None = None,
        clone_icl: bool | None = None,
        temperature: float | None = None,
        model_loader: Any = None,
    ) -> None:
        self.model_loader = model_loader
        self.voices_dir = Path(voices_dir) if voices_dir else None
        self.design_model = design_model
        self.base_model = base_model
        self.model_name = "Qwen3-TTS-12Hz-1.7B"
        self.language = language
        self.anchor_text = anchor_text
        self.descriptions = dict(descriptions or {})
        if use_design_per_line is None:
            use_design_per_line = os.environ.get("FIREBRAT_QWEN_MODE", "clone") == "design"
        self.use_design_per_line = use_design_per_line
        if clone_icl is None:
            clone_icl = os.environ.get("FIREBRAT_QWEN_CLONE", "xvec") == "icl"
        self.clone_icl = clone_icl
        self.batch_size = int(batch_size or os.environ.get("FIREBRAT_QWEN_BATCH", 96))
        # rows x frames per generate call (memory ~ linear in it; 15k frames peaked at ~7.5 GB)
        self.token_budget = int(os.environ.get("FIREBRAT_QWEN_TOKEN_BUDGET", 14000))
        env_t = os.environ.get("FIREBRAT_QWEN_TEMPERATURE")
        self.temperature = temperature if temperature is not None else (float(env_t) if env_t else None)
        self.model_kwargs = dict(model_kwargs or {})
        self.book_id = ""
        self._model: Any = None
        self._resident: str | None = None
        self._prompts: dict[tuple[str, str], list] = {}  # (voices_dir, char) -> prompt items

    # -- per-book binding ------------------------------------------------
    def bind_book(self, book_id: str, voices_dir: Path | str,
                  descriptions: dict[str, str] | None = None) -> None:
        """Point the engine at one book: its own voices dir + character descriptions.

        Anchors are cached under ``voices_dir`` (``<root>/out/<slug>/voices``), so characters
        of different books never collide even when one engine serves several books.
        """
        self.book_id = book_id
        self.voices_dir = Path(voices_dir)
        self.descriptions = dict(descriptions or {})
        self._prompts = {k: v for k, v in self._prompts.items() if k[0] == str(self.voices_dir)}

    # -- lifecycle ------------------------------------------------------
    def load(self) -> None:
        """Lazy: models load on first use (design for anchors, base for lines)."""

    def unload(self) -> None:
        had = self._model is not None
        self._model = None
        self._resident = None
        self._prompts.clear()
        if had:
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
        log.info("Loading Qwen TTS %s (%s)", which, want)
        if self.model_loader is not None:  # test seam
            self._model = self.model_loader(want)
        else:
            import torch
            from qwen_tts import Qwen3TTSModel

            frac = os.environ.get("FIREBRAT_QWEN_VRAM_FRACTION")
            if frac and torch.cuda.is_available():  # lets two workers share one GPU
                torch.cuda.set_per_process_memory_fraction(float(frac))
            kwargs = {"device_map": "cuda:0", "dtype": torch.bfloat16}
            kwargs.update(self.model_kwargs)
            self._model = Qwen3TTSModel.from_pretrained(_snapshot(want), **kwargs)
            patch_decoder_batching(self._model)
        self._resident = want
        return self._model

    def _gen_kwargs(self, texts: Sequence[str]) -> dict[str, Any]:
        kw: dict[str, Any] = {"max_new_tokens": max_new_tokens_for(texts)}
        if self.temperature is not None:
            kw["temperature"] = self.temperature
            kw["subtalker_temperature"] = self.temperature
        return kw

    @staticmethod
    def _seed(seed: int | None) -> None:
        if seed is None:
            return
        try:
            import torch
        except ImportError:
            return
        torch.manual_seed(int(seed) & 0x7FFFFFFF)

    # -- anchors ---------------------------------------------------------
    def _require_dir(self) -> Path:
        if self.voices_dir is None:
            raise RuntimeError("QwenVoiceEngine has no voices_dir; call bind_book() first")
        return self.voices_dir

    def _anchor_paths(self, char: str) -> tuple[Path, Path]:
        safe = _safe_name(char)
        d = self._require_dir()
        return d / f"{safe}.wav", d / f"{safe}.json"

    def describe(self, char: str) -> str:
        return self.descriptions.get(char) or DEFAULT_DESCRIPTION

    def _anchor_ok(self, char: str) -> bool:
        wav_path, json_path = self._anchor_paths(char)
        return wav_path.is_file() and wav_path.stat().st_size > 0 and json_path.is_file()

    def anchor(self, char: str) -> Path:
        self.ensure_anchors([char])
        return self._anchor_paths(char)[0]

    def ensure_anchors(self, chars: Sequence[str]) -> None:
        """Mint every missing anchor (one VoiceDesign batch per 24), then make them distinct.

        After minting, speaker embeddings (the model's own x-vectors, mean-centred over the book's
        anchors) are compared; a new anchor too close to an earlier one is re-minted with a new
        seed and a contrasting trait, up to ``DEDUPE_ROUNDS`` times. Anchors of a character are
        never re-minted once the book has been rendered with them (existing files are reused).
        """
        todo = [c for c in dict.fromkeys(chars) if not self._anchor_ok(c)]
        if not todo:
            return
        self._require_dir().mkdir(parents=True, exist_ok=True)
        variants = {c: 0 for c in todo}
        for rnd in range(DEDUPE_ROUNDS + 1):
            model = self._ensure("design")
            minting = [c for c in todo if not self._anchor_ok(c)]
            for i in range(0, len(minting), ANCHOR_BATCH):
                self._mint_batch(model, minting[i:i + ANCHOR_BATCH], variants)
            if rnd == DEDUPE_ROUNDS:
                break
            clash = self._close_anchors(todo)
            if not clash:
                break
            log.warning("Round %d: %d anchors too close to another voice, re-minting: %s",
                        rnd + 1, len(clash), ", ".join(clash))
            for c in clash:
                variants[c] = variants.get(c, 0) + 1
                for p in self._anchor_paths(c):
                    p.unlink(missing_ok=True)

    def _close_anchors(self, fresh: Sequence[str]) -> list[str]:
        """Fresh anchors whose centred x-vector cosine to an earlier anchor exceeds the threshold."""
        import numpy as np

        d = self._require_dir()
        allc = sorted({p.stem for p in d.glob("*.wav")} | set(fresh))
        # earlier = already established; the narrator (most audio) is never re-minted
        order = [c for c in allc if c not in fresh] + sorted(fresh, key=lambda c: c != NARRATOR_ID)
        vecs: dict[str, Any] = {}
        for c in order:
            if not self._anchor_ok(c):
                continue
            item = self._prompt_for(c, fresh_clone=True)[0]
            emb = getattr(item, "ref_spk_embedding", None)
            if emb is None:
                return []  # engine/fake without embeddings: skip the check
            v = emb.detach().float().cpu().numpy().ravel() if hasattr(emb, "detach") else np.asarray(emb, np.float32).ravel()
            vecs[c] = v
        if len(vecs) < 3:
            return []
        mean = np.mean(list(vecs.values()), axis=0)
        unit = {c: (v - mean) / (np.linalg.norm(v - mean) + 1e-9) for c, v in vecs.items()}
        clash = []
        seen: list[str] = [c for c in order if c in unit and c not in fresh]
        for c in sorted(fresh, key=lambda c: c != NARRATOR_ID):
            if c not in unit:
                continue
            if c == NARRATOR_ID:
                seen.append(c)
                continue
            worst = max((float(unit[c] @ unit[o]) for o in seen), default=-1.0)
            if worst > DEDUPE_COSINE:
                clash.append(c)
            else:
                seen.append(c)
        return clash

    def _mint_batch(self, model: Any, chars: Sequence[str], variants: dict[str, int] | None = None) -> None:
        pending = list(chars)
        variants = variants or {}
        for attempt in range(3):
            if not pending:
                break
            self._seed(1000 + attempt + 100 * max((variants.get(c, 0) for c in pending), default=0))
            instructs = [self._anchor_instruct(c, variants.get(c, 0)) for c in pending]
            wavs = sr = None
            oom = False
            try:
                wavs, sr = model.generate_voice_design(
                    text=[self.anchor_text] * len(pending),
                    instruct=instructs,
                    language=[self.language] * len(pending),
                    **self._gen_kwargs([self.anchor_text]),
                )
            except Exception as e:  # CUDA OOM (e.g. two workers sharing the GPU): mint in halves
                if "out of memory" not in str(e).lower() or len(pending) <= 1:
                    raise
                oom = True
            if oom:  # outside the except block so the failed call's tensors can be freed
                log.warning("CUDA OOM minting %d anchors; retrying as halves", len(pending))
                self._free_cache()
                half = len(pending) // 2
                self._mint_batch(model, pending[:half], variants)
                self._mint_batch(model, pending[half:], variants)
                return
            retry = []
            for c, wav, instruct in zip(pending, wavs, instructs):
                arr = self._to_f32(wav)
                dur = arr.size / float(sr)
                if not 5.0 <= dur <= 22.0 and attempt < 2:
                    log.warning("Anchor %s has odd length %.1fs; re-minting", c, dur)
                    retry.append(c)
                    continue
                wav_path, json_path = self._anchor_paths(c)
                self._write_wav(wav_path, arr, int(sr))
                json_path.write_text(json.dumps(
                    {"speaker_id": c, "book_id": self.book_id, "description": self.describe(c),
                     "instruct": instruct, "variant": variants.get(c, 0),
                     "ref_text": self.anchor_text, "sample_rate": int(sr), "seconds": round(dur, 2)},
                    indent=2))
                log.info("Minted anchor %s -> %s (%.1fs)", c, wav_path, dur)
            pending = retry

    def _anchor_instruct(self, char: str, variant: int) -> str:
        base = f"{self.describe(char)}, {_emotion_suffix('neutral', '')}"
        if variant <= 0:
            return base
        low = self.describe(char).lower()
        female = re.search(r"\b(woman|girl|female|lady)\b", low)
        male = re.search(r"\b(man|boy|male|gentleman)\b", low)
        pool = CONTRAST_FEMALE if female and not male else CONTRAST_MALE if male and not female else CONTRAST_TRAITS
        trait = pool[(sum(map(ord, char)) + variant) % len(pool)]
        return f"{trait}. {base}"

    def _prompt_for(self, char: str, fresh_clone: bool = False) -> list:
        """Cached VoiceClonePromptItem list for the character's anchor."""
        d = str(self._require_dir())
        key = (d, char)
        if fresh_clone:
            self._prompts.pop(key, None)  # anchor may have been re-minted
        if key not in self._prompts:
            wav_path, json_path = self._anchor_paths(char)
            try:
                meta = json.loads(json_path.read_text())
            except (OSError, ValueError):
                meta = {}
            arr, sr = self._read_wav(wav_path)
            model = self._ensure("base")
            self._prompts[key] = model.create_voice_clone_prompt(
                ref_audio=(arr, int(sr)),
                ref_text=(meta.get("ref_text") or self.anchor_text) if self.clone_icl else None,
                x_vector_only_mode=not self.clone_icl,
            )
        return self._prompts[key]

    # -- synthesis -------------------------------------------------------
    @staticmethod
    def _to_f32(wav: Any) -> "np.ndarray":
        import numpy as np

        if hasattr(wav, "detach"):  # torch tensor
            wav = wav.detach().float().cpu().numpy()
        return np.asarray(wav, dtype=np.float32).ravel()

    def speak(self, text: str, speaker_id: str, emotion: str = "neutral",
              delivery: str = "", seed: int | None = None) -> "tuple[np.ndarray, int]":
        return self.speak_many(
            [{"text": text, "speaker_id": speaker_id, "emotion": emotion, "delivery": delivery}],
            seed=seed)[0]

    def speak_many(self, items: Sequence[dict], seed: int | None = None) -> "list[tuple[np.ndarray, int]]":
        """Synthesise a list of ``{text, speaker_id, emotion, delivery}`` (any mix of voices).

        Returned in input order. Callers pre-sort by text length so rows in a batch have
        similar lengths (padding waste) and chunk to ``batch_size``.
        """
        import time

        out: list[tuple[Any, int]] = []
        for chunk in self._chunks(items):
            t0 = time.monotonic()
            res = self._speak_batch_safe(chunk, seed)
            wall = time.monotonic() - t0
            secs = sum(w.size / float(sr) for w, sr in res)
            log.info("TTS batch: %d rows, %d max chars, %.1fs audio in %.1fs (x%.1f)", len(chunk),
                     max(len(str(i.get("text") or "")) for i in chunk), secs, wall, secs / max(wall, 1e-6))
            out.extend(res)
        return out

    @staticmethod
    def _free_cache() -> None:
        gc.collect()
        try:
            import torch

            torch.cuda.empty_cache()
        except ImportError:
            pass

    def _speak_batch_safe(self, chunk: Sequence[dict], seed: int | None):
        """On CUDA OOM free the cache and retry the batch as two halves (down to one row).

        The retry runs OUTSIDE the ``except`` block: inside it the exception's traceback still
        references the failed call's tensors, so the cache could not actually be freed.
        """
        try:
            return self._speak_batch(chunk, seed)
        except Exception as e:  # torch.OutOfMemoryError subclasses RuntimeError
            if "out of memory" not in str(e).lower():
                raise
            oom = True
            if len(chunk) <= 1 and getattr(self, "_oom_single_retry", False):
                raise
        if oom:
            log.warning("CUDA OOM on a batch of %d; freeing cache and retrying", len(chunk))
            self._free_cache()
            if len(chunk) <= 1:  # one more try on a clean cache, then give up
                self._oom_single_retry = True
                try:
                    return self._speak_batch(chunk, seed)
                finally:
                    self._oom_single_retry = False
            half = len(chunk) // 2
            return self._speak_batch_safe(chunk[:half], seed) + self._speak_batch_safe(chunk[half:], seed)

    def _chunks(self, items: Sequence[dict]) -> list[Sequence[dict]]:
        """Split into batches of <= batch_size rows and <= token_budget rows x frames."""
        chunks: list[list[dict]] = []
        cur: list[dict] = []
        cur_max = 0
        for it in items:
            need = expected_frames(str(it.get("text") or ""))
            if cur and (len(cur) + 1 > max(1, self.batch_size)
                        or (len(cur) + 1) * max(cur_max, need) > self.token_budget):
                chunks.append(cur)
                cur, cur_max = [], 0
            cur.append(it)
            cur_max = max(cur_max, need)
        if cur:
            chunks.append(cur)
        return chunks

    def _speak_batch(self, items: Sequence[dict], seed: int | None):
        texts = []
        for it in items:
            t = " ".join(str(it["text"]).split())
            if not t:
                raise ValueError("speak() needs non-empty text")
            texts.append(t)
        chars = [str(it.get("speaker_id") or NARRATOR_ID) for it in items]
        self.ensure_anchors(chars)  # no-op once minted
        if self.use_design_per_line:
            model = self._ensure("design")
            instructs = [f"{self.describe(c)}, {_emotion_suffix(str(it.get('emotion') or 'neutral'), str(it.get('delivery') or ''))}"
                         for c, it in zip(chars, items)]
            self._seed(seed)
            wavs, sr = model.generate_voice_design(
                text=texts, instruct=instructs, language=[self.language] * len(texts),
                **self._gen_kwargs(texts))
        else:
            model = self._ensure("base")
            prompts: list = []
            for c in chars:
                prompts.extend(self._prompt_for(c))
            self._seed(seed)
            wavs, sr = model.generate_voice_clone(
                text=texts, language=[self.language] * len(texts),
                voice_clone_prompt=prompts, **self._gen_kwargs(texts))
        return [(self._to_f32(w), int(sr)) for w in wavs]

    @staticmethod
    def _write_wav(path: Path, wav: Any, sr: int) -> None:
        import wave

        import numpy as np

        arr = np.clip(np.asarray(wav, dtype=np.float32).ravel(), -1.0, 1.0)
        tmp = path.with_name(path.name + ".tmp")
        with wave.open(str(tmp), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(int(sr))
            w.writeframes(np.round(arr * 32767.0).astype("<i2").tobytes())
        os.replace(tmp, path)

    @staticmethod
    def _read_wav(path: Path) -> "tuple[np.ndarray, int]":
        import wave

        import numpy as np

        with wave.open(str(path), "rb") as w:
            sr, n = w.getframerate(), w.getnframes()
            pcm = np.frombuffer(w.readframes(n), dtype="<i2")
        return (pcm.astype(np.float32) / 32768.0), int(sr)
