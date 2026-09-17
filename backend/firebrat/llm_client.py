"""OpenAI-compatible client for nano-gpt, with retry + strict JSON parsing."""
from __future__ import annotations
import json
import time
import logging
from typing import Any

import requests

from firebrat.config import NANO_API_URL, NANO_API_KEY

log = logging.getLogger(__name__)


def _headers() -> dict[str, str]:
    return {
        "Authorization": f"Bearer {NANO_API_KEY}",
        "Content-Type": "application/json",
    }


def chat_completion(
    messages: list[dict],
    model: str,
    temperature: float = 0.2,
    max_tokens: int = 6000,
    response_format_json: bool = False,
    retries: int = 4,
    backoff_base: float = 2.0,
    timeout: int = 240,
) -> dict[str, Any]:
    """Call /v1/chat/completions, retry on 429/5xx with exponential backoff.

    timeout defaults to 240s, not requests' usual short default — observed
    latency for both the flash and thinking-tier models on this endpoint
    routinely runs 120-150s+ under load, and a too-tight timeout just burns
    a full retry cycle (another ~timeout seconds) for a request that would
    have succeeded if given a bit longer.
    """
    url = f"{NANO_API_URL.rstrip('/')}/chat/completions"
    payload: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
    }
    if response_format_json:
        payload["response_format"] = {"type": "json_object"}

    last_err: Exception | None = None
    for attempt in range(retries + 1):
        try:
            resp = requests.post(url, headers=_headers(), json=payload, timeout=timeout)
            if resp.status_code == 429 or resp.status_code >= 500:
                raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:500]}")
            resp.raise_for_status()
            return resp.json()
        except Exception as e:
            last_err = e
            if attempt == retries:
                break
            sleep = backoff_base ** attempt + (0.5 if attempt > 1 else 0)
            log.warning("chat_completion attempt %d/%d failed (%s), retry in %.1fs",
                        attempt + 1, retries + 1, e, sleep)
            time.sleep(sleep)
    assert last_err is not None
    raise last_err


def chat_json(
    messages: list[dict],
    model: str,
    temperature: float = 0.2,
    max_tokens: int = 6000,
    retries_parse: int = 3,
    fallback_model: str | None = None,
    timeout: int = 240,
) -> tuple[dict, str]:
    """Call chat_completion and parse JSON from the response content.

    Retries with the parse error appended to the prompt on JSON failure.
    On repeated failure, optionally escalates to fallback_model.

    Returns (parsed_json, model_used).
    """
    cur_messages = list(messages)
    cur_model = model

    for attempt in range(retries_parse + 1):
        raw = chat_completion(cur_messages, cur_model, temperature, max_tokens,
                              response_format_json=(attempt == 0), timeout=timeout)
        content = raw["choices"][0]["message"]["content"]
        # Strip ```json fences if present
        text = content.strip()
        if text.startswith("```"):
            # remove first line and last ```
            lines = text.splitlines()
            lines = lines[1:]  # drop ```json
            if lines and lines[-1].strip() == "```":
                lines = lines[:-1]
            text = "\n".join(lines)

        try:
            parsed = json.loads(text)
            # Log token usage if present
            usage = raw.get("usage", {})
            if usage:
                log.info("LLM %s tokens prompt=%s completion=%s",
                         cur_model, usage.get("prompt_tokens"), usage.get("completion_tokens"))
            return parsed, cur_model
        except json.JSONDecodeError as je:
            if attempt == retries_parse:
                if fallback_model and cur_model != fallback_model:
                    log.warning("JSON parse failed with %s, escalating to %s", cur_model, fallback_model)
                    cur_model = fallback_model
                    cur_messages = list(messages)
                    # one more round with fallback model
                    for fb_attempt in range(retries_parse + 1):
                        raw2 = chat_completion(cur_messages, cur_model, temperature, max_tokens,
                                               response_format_json=(fb_attempt == 0), timeout=timeout)
                        content2 = raw2["choices"][0]["message"]["content"].strip()
                        if content2.startswith("```"):
                            ls = content2.splitlines()[1:]
                            if ls and ls[-1].strip() == "```":
                                ls = ls[:-1]
                            content2 = "\n".join(ls)
                        try:
                            return json.loads(content2), cur_model
                        except json.JSONDecodeError as je2:
                            if fb_attempt == retries_parse:
                                raise ValueError(f"LLM JSON parse failed after escalation: {je2}\nRaw: {content2[:2000]}") from je2
                            cur_messages = list(messages) + [
                                {"role": "assistant", "content": content2},
                                {"role": "user", "content": f"Your previous response was not valid JSON: {je2}. Reply with ONLY valid JSON matching the required schema."},
                            ]
                raise ValueError(f"LLM JSON parse failed: {je}\nRaw: {text[:2000]}") from je

            # Append parse error and retry
            cur_messages = cur_messages + [
                {"role": "assistant", "content": content},
                {"role": "user", "content": f"Your previous response was not valid JSON: {je}. Reply with ONLY valid JSON matching the required schema. No markdown fences."},
            ]
            log.warning("JSON parse attempt %d failed, retrying: %s", attempt + 1, je)

    raise RuntimeError("unreachable")
