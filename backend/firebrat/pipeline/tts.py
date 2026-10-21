"""Chatterbox TTS wrapper — uses the firebrat-tts env's chatterbox-tts 0.1.7."""
import logging
import os
import shutil
import tempfile

log = logging.getLogger(__name__)


class FirebratTTS:
    def __init__(self, device: str | None = None, hf_home: str | None = None,
                 exaggeration: float = 0.4, cfg_weight: float = 0.5,
                 voice_ref: str | None = None,
                 male_voice_ref: str | None = None, female_voice_ref: str | None = None):
        self.device = device or os.environ.get("FIREBRAT_TTS_DEVICE", "auto")
        self.exaggeration = exaggeration
        self.cfg_weight = cfg_weight
        self.voice_ref = voice_ref
        self.character_voice_refs = {"male": male_voice_ref, "female": female_voice_ref}
        for reference in (voice_ref, male_voice_ref, female_voice_ref):
            if reference and not os.path.isfile(reference):
                raise ValueError(f"Voice reference must be an existing local file: {reference}")
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
        import torch
        if self.device == "auto":
            self.device = "cuda" if torch.cuda.is_available() else "cpu"
        if self.device not in {"cpu", "cuda"}:
            raise ValueError("FIREBRAT_TTS_DEVICE must be auto, cpu or cuda; speech always runs locally.")
        if self.device == "cuda" and not torch.cuda.is_available():
            raise RuntimeError("CUDA is unavailable. Select CPU voice generation or install a compatible NVIDIA driver/PyTorch build.")
        from chatterbox.tts import ChatterboxTTS  # type: ignore
        log.info("Loading ChatterboxTTS on %s (HF_HOME=%s)", self.device, os.environ.get("HF_HOME"))
        self._model = ChatterboxTTS.from_pretrained(device=self.device)
        # sample rate property varies by version: .sr or .sample_rate
        self.sample_rate = getattr(self._model, "sr", getattr(self._model, "sample_rate", 24000))
        log.info("ChatterboxTTS loaded, sr=%s", self.sample_rate)
        return self._model

    def reference_for_style(self, voice_style: dict | None = None):
        gender = (voice_style or {}).get("voice_gender", "unknown")
        return self.character_voice_refs.get(gender) or self.voice_ref

    def synthesize(self, text: str, out_wav_path: str,
                   voice_style: dict | None = None) -> bool:
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
            reference = self.reference_for_style(voice_style)
            if reference:
                kwargs["audio_prompt_path"] = reference
            # Not all versions accept exaggeration/cfg_weight — probe safely
            import inspect
            sig = inspect.signature(model.generate)
            if "exaggeration" in sig.parameters:
                kwargs["exaggeration"] = (voice_style or {}).get("exaggeration", self.exaggeration)
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
            semitones = (voice_style or {}).get("pitch_semitones", 0)
            if semitones:
                from pydub import AudioSegment
                audio = AudioSegment.from_wav(out_wav_path)
                audio = audio._spawn(audio.raw_data, overrides={
                    "frame_rate": round(audio.frame_rate * 2 ** (semitones / 12))
                }).set_frame_rate(self.sample_rate)
                audio.export(out_wav_path, format="wav")
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
            if self.synthesize(text, wav_path, voice_style=seg.get("voice_style")):
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
