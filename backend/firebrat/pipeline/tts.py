"""Chatterbox TTS wrapper — uses the firebrat-tts env's chatterbox-tts 0.1.7."""
import logging
import os
import shutil
import tempfile

log = logging.getLogger(__name__)


class FirebratTTS:
    def __init__(self, device: str = "cuda", hf_home: str | None = None,
                 exaggeration: float = 0.4, cfg_weight: float = 0.5,
                 voice_ref: str | None = None):
        self.device = device
        self.exaggeration = exaggeration
        self.cfg_weight = cfg_weight
        self.voice_ref = voice_ref
        if hf_home:
            os.environ["HF_HOME"] = hf_home
        elif "HF_HOME" not in os.environ:
            # default redirect off home quota
            os.environ["HF_HOME"] = "/scratch/sroy85/.cache/huggingface"
        self._model = None
        self.sample_rate: int = 24000

    def load(self):
        if self._model is not None:
            return self._model
        # MIG targeting: caller should have set CUDA_VISIBLE_DEVICES; we just use "cuda"
        from chatterbox.tts import ChatterboxTTS  # type: ignore
        log.info("Loading ChatterboxTTS on %s (HF_HOME=%s)", self.device, os.environ.get("HF_HOME"))
        self._model = ChatterboxTTS.from_pretrained(device=self.device)
        # sample rate property varies by version: .sr or .sample_rate
        self.sample_rate = getattr(self._model, "sr", getattr(self._model, "sample_rate", 24000))
        log.info("ChatterboxTTS loaded, sr=%s", self.sample_rate)
        return self._model

    def synthesize(self, text: str, out_wav_path: str) -> bool:
        """Synthesize one utterance to wav. Returns True on success."""
        text = text.strip()
        if not text:
            log.warning("Empty text, skipping TTS")
            return False
        os.makedirs(os.path.dirname(out_wav_path) or ".", exist_ok=True)
        try:
            model = self.load()
            kwargs: dict = {}
            # exaggeration/cfg only present in some versions
            if self.voice_ref and os.path.isfile(self.voice_ref):
                kwargs["audio_prompt_path"] = self.voice_ref
            # Not all versions accept exaggeration/cfg_weight — probe safely
            import inspect
            sig = inspect.signature(model.generate)
            if "exaggeration" in sig.parameters:
                kwargs["exaggeration"] = self.exaggeration
            if "cfg_weight" in sig.parameters:
                kwargs["cfg_weight"] = self.cfg_weight

            wav = model.generate(text, **kwargs)
            # wav is torch tensor (samples,) or (1, samples)
            import torch
            import soundfile as sf
            if isinstance(wav, torch.Tensor):
                wav = wav.detach().cpu().numpy()
                if wav.ndim == 2:
                    wav = wav[0]
            elif hasattr(wav, "numpy"):
                wav = wav.numpy()
                if wav.ndim == 2:
                    wav = wav[0]
            sf.write(out_wav_path, wav, self.sample_rate)
            return True
        except Exception as e:
            log.exception("TTS synthesize failed for %r: %s", text[:80], e)
            return False

    def synthesize_segments(self, segments: list[dict], out_dir: str) -> dict[str, str]:
        """Batch helper. Returns {segment_id: wav_path} for successes."""
        os.makedirs(out_dir, exist_ok=True)
        result: dict[str, str] = {}
        for seg in segments:
            sid = seg.get("segment_id") or seg.get("id") or str(id(seg))
            text = seg.get("text", "")
            wav_path = os.path.join(out_dir, f"{sid}.wav")
            if self.synthesize(text, wav_path):
                result[sid] = wav_path
                log.info("TTS %s -> %s", sid, wav_path)
            else:
                # Write 200ms silence so downstream assembly doesn't break
                from pydub import AudioSegment
                silence = AudioSegment.silent(duration=200, frame_rate=self.sample_rate)
                silence.export(wav_path, format="wav")
                result[sid] = wav_path
                log.warning("TTS failed for %s, wrote silence placeholder", sid)
        return result
