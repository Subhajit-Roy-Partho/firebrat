"""Pluggable LLM backends for casting + JSON extraction/repair helpers.

Backends implement ``generate_text`` (raw string) and ``generate_json``
(parsed dict). Heavy deps (transformers/torch) import lazily inside methods
so unit tests and offline tooling never need a GPU or model weights.
"""
from __future__ import annotations

import gc
import json
import logging
import os
import re
from typing import Any, Protocol

log = logging.getLogger(__name__)

MODEL_ID = "Qwen/Qwen3.5-9B"
THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)
_FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL | re.IGNORECASE)
_TRAILING_COMMA_RE = re.compile(r",(\s*[}\]])")


class LLMBackend(Protocol):
    """Casting LLM. ``name`` identifies it in cast.json's ``llm`` record."""

    name: str

    def generate_text(self, system: str, user: str, max_tokens: int = 2048) -> str:
        ...

    def generate_json(self, system: str, user: str, schema_hint: str = "",
                      max_tokens: int = 2048) -> dict:
        ...


def strip_thinking(text: str) -> str:
    """Drop Qwen3 <think>...</think> reasoning blocks, keep the answer."""
    return THINK_RE.sub("", text).strip()


def _strip_fences(text: str) -> str:
    m = _FENCE_RE.search(text)
    return m.group(1).strip() if m else text.strip()


def _as_dict(obj: Any, snippet: str) -> dict:
    if not isinstance(obj, dict):
        raise ValueError(f"expected a JSON object, got {type(obj).__name__}: {snippet}")
    return obj


def extract_json_value(text: str) -> Any:
    """Pull one JSON value out of free-form model output (fences/think ok)."""
    cleaned = _strip_fences(strip_thinking(text or ""))
    attempts = [cleaned, _TRAILING_COMMA_RE.sub(r"\1", cleaned)]
    for attempt in attempts:
        try:
            return json.loads(attempt)
        except json.JSONDecodeError:
            pass
        start_candidates = [i for i in (attempt.find("{"), attempt.find("["))
                            if i >= 0]
        if start_candidates:
            try:
                return json.JSONDecoder().raw_decode(attempt[min(start_candidates):])[0]
            except json.JSONDecodeError:
                pass
    raise ValueError(f"no JSON value found in {len(text or '')} chars: {cleaned[:160]!r}")


def extract_json(text: str) -> dict:
    """extract_json_value narrowed to objects (what generate_json returns)."""
    return _as_dict(extract_json_value(text), (text or "")[:160])


def extract_json_array(text: str) -> list:
    """Parse a bare ``[...]`` reply (the compact attribution shape)."""
    obj = extract_json_value(text)
    if not isinstance(obj, list):
        raise ValueError(f"expected a JSON array: {(text or '')[:160]!r}")
    return obj


def generate_json_with_retry(backend: LLMBackend, system: str, user: str,
                             schema_hint: str = "", max_tokens: int = 2048,
                             tries: int = 2) -> dict:
    """generate_json, retrying once with a repair note naming the failure."""
    error: str | None = None
    for _ in range(max(1, tries)):
        attempt_user = user if error is None else (
            f"{user}\n\nYour previous reply was unusable ({error}). "
            f"Reply again with exactly one JSON object and nothing else."
        )
        try:
            return backend.generate_json(system, attempt_user, schema_hint, max_tokens)
        except ValueError as e:
            error = str(e)[:200]
    raise ValueError(f"LLM kept returning bad JSON: {error}")


class LocalHFBackend:
    """In-process Qwen3.5-9B via transformers; unload() frees VRAM."""

    name = "local-hf"

    def __init__(self, model_id: str = MODEL_ID, quantize: str = "auto") -> None:
        self.model_id = model_id
        self.quantize = quantize  # 'auto' | 'fp8' | 'bnb8' | 'fp16'
        self.quant_used: str | None = None
        self._model = None
        self._tok = None

    def load(self) -> None:
        self._ensure_loaded()

    def _ensure_loaded(self) -> None:
        if self._model is not None:
            return
        # Qwen3.5 ships as a conditional-generation (vision+text) checkpoint; this class is the one verified to load it fully.
        from transformers import AutoModelForImageTextToText as AutoModelForCausalLM, AutoTokenizer
        self._tok = AutoTokenizer.from_pretrained(self.model_id, trust_remote_code=True)
        # 'auto' prefers bnb 8-bit: on the server FP8 on-the-fly conversion of Qwen3.5-9B produced corrupted outputs
        wants = [self.quantize] if self.quantize != "auto" else ["bnb8", "fp8", "fp16"]
        error: Exception | None = None
        for want in wants:
            try:
                kwargs: dict[str, Any] = {"trust_remote_code": True, "device_map": "cuda"}
                if want == "fp8":
                    from transformers import FineGrainedFP8Config
                    kwargs["quantization_config"] = FineGrainedFP8Config()
                elif want == "bnb8":
                    from transformers import BitsAndBytesConfig
                    kwargs["quantization_config"] = BitsAndBytesConfig(
                        load_in_8bit=True, llm_int8_skip_modules=["visual", "lm_head"])
                self._model = AutoModelForCausalLM.from_pretrained(self.model_id, **kwargs)
                self.quant_used = want
                break
            except Exception as e:  # next cheaper/fallback option
                error = e
                log.warning("LocalHFBackend quant %s failed (%s), trying next", want, e)
        if self._model is None:
            raise RuntimeError(f"could not load {self.model_id}: {error}")
        log.info("LocalHFBackend loaded %s (quant=%s)", self.model_id, self.quant_used)

    def _prompt(self, system: str, user: str) -> str:
        apply = getattr(self._tok, "apply_chat_template", None)
        if callable(apply):
            messages = [{"role": "system", "content": system},
                        {"role": "user", "content": user}]
            try:
                return apply(messages, tokenize=False, add_generation_prompt=True,
                             enable_thinking=False)
            except TypeError:  # older template without the flag
                return apply(messages, tokenize=False, add_generation_prompt=True)
        return (f"<|im_start|>system\n{system}<|im_end|>\n"
                f"<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n")

    def generate_text(self, system: str, user: str, max_tokens: int = 2048) -> str:
        import torch
        self._ensure_loaded()
        inputs = self._tok(self._prompt(system, user), return_tensors="pt")
        inputs = {k: v.to(self._model.device) for k, v in inputs.items()}
        with torch.no_grad():
            out = self._model.generate(**inputs, max_new_tokens=max_tokens,
                                       do_sample=False,
                                       pad_token_id=self._tok.eos_token_id)
        new_tokens = out[0][inputs["input_ids"].shape[1]:]
        return strip_thinking(self._tok.decode(new_tokens, skip_special_tokens=True))

    def generate_json(self, system: str, user: str, schema_hint: str = "",
                      max_tokens: int = 2048) -> dict:
        hint = f"\nReply with exactly one JSON object matching: {schema_hint}" if schema_hint else ""
        return extract_json(self.generate_text(system, user + hint, max_tokens))

    def unload(self) -> None:
        """Drop the model and release VRAM (the TTS stage needs the GPU next)."""
        self._model, self._tok = None, None
        gc.collect()
        try:
            import torch
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except ImportError:
            pass


class OpenAICompatBackend:
    """External OpenAI-compatible endpoint (env CAST_LLM_URL / CAST_LLM_KEY).

    Lets casting run while the local GPU stays on TTS; stdlib urllib only.
    """

    def __init__(self, model: str | None = None, base_url: str | None = None,
                 api_key: str | None = None, timeout: int = 600) -> None:
        self.base_url = (base_url or os.environ.get("CAST_LLM_URL") or "").rstrip("/")
        self.api_key = api_key or os.environ.get("CAST_LLM_KEY", "")
        self.model = model or os.environ.get("CAST_LLM_MODEL", MODEL_ID)
        self.timeout = timeout
        self.name = f"openai-compat:{self.model}"
        if not self.base_url:
            raise ValueError("OpenAICompatBackend needs base_url or CAST_LLM_URL")

    def load(self) -> None:  # API backend: nothing resident on the GPU
        return

    def unload(self) -> None:
        return

    def _post(self, payload: dict) -> dict:
        import urllib.request
        req = urllib.request.Request(
            f"{self.base_url}/chat/completions",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json",
                     **({"Authorization": f"Bearer {self.api_key}"} if self.api_key else {})},
            method="POST")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.load(resp)

    def generate_text(self, system: str, user: str, max_tokens: int = 2048) -> str:
        body = {"model": self.model,
                "messages": [{"role": "system", "content": system},
                             {"role": "user", "content": user}],
                "temperature": 0, "max_tokens": max_tokens,
                "chat_template_kwargs": {"enable_thinking": False}}
        data = self._post(body)
        try:
            content = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as e:
            raise ValueError(f"bad chat-completions reply: {e}")
        return strip_thinking(content or "")

    def generate_json(self, system: str, user: str, schema_hint: str = "",
                      max_tokens: int = 2048) -> dict:
        hint = f"\nReply with exactly one JSON object matching: {schema_hint}" if schema_hint else ""
        return extract_json(self.generate_text(system, user + hint, max_tokens))
