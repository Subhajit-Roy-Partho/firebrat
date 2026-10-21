"""Minimal OpenAI-compatible chat server around a local HF transformers model.

Lets the Firebrat pipeline run Stage 2 against an on-GPU model with ZERO
code changes: `NANO_API_URL=http://127.0.0.1:8080/v1` (+ any bearer token,
which is accepted and ignored). Only `/v1/chat/completions` is implemented,
which is the single endpoint `firebrat/llm_client.py` uses.

Usage (needs the `firebrat-extract` env: torch+CUDA, transformers,
accelerate, fastapi, uvicorn — all present):
  /scratch/sroy85/conda-envs/firebrat-extract/bin/python \\
      backend/scripts/llm_server.py --model-dir /scratch/sroy85/llm-models/qwen3-4b \\
      --port 8080

Notes:
- fp16 on a 16GB V100: 4B weights ~8GB + KV cache for --max-seq-len tokens.
  Keep --max-seq-len at 16384 or below or the KV cache won't fit.
- No auth, localhost only (binds 127.0.0.1) — this box is shared.
- Generation is slow (~15-30 tok/s on V100): a dense 2-page chunk's ~10k
  output tokens take ~10 min. No 340s connection wall, but also no speed.
"""

import argparse
import time
import uuid

import torch
from fastapi import FastAPI
from pydantic import BaseModel
from transformers import AutoModelForCausalLM, AutoTokenizer


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    model: str = "local"
    messages: list[ChatMessage] = []
    temperature: float = 0.2
    max_tokens: int = 6000


def build_app(model_dir: str, max_seq_len: int) -> FastAPI:
    print(f"[llm_server] loading {model_dir} ...", flush=True)
    tok = AutoTokenizer.from_pretrained(model_dir, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        model_dir,
        torch_dtype=torch.float16,
        device_map="cuda:0",
        trust_remote_code=True,
    ).eval()
    print("[llm_server] model on", next(model.parameters()).device, flush=True)
    app = FastAPI()

    @app.get("/v1/models")
    def models():
        return {"data": [{"id": "local-qwen3-4b"}]}

    @app.post("/v1/chat/completions")
    def chat(req: ChatRequest):
        prompt = tok.apply_chat_template(
            [{"role": m.role, "content": m.content} for m in req.messages],
            tokenize=False,
            add_generation_prompt=True,
        )
        inputs = tok(prompt, return_tensors="pt").to("cuda:0")
        in_len = inputs["input_ids"].shape[1]
        max_new = min(req.max_tokens, max(512, max_seq_len - in_len))
        t0 = time.time()
        with torch.no_grad():
            out = model.generate(
                **inputs,
                max_new_tokens=max_new,
                temperature=max(req.temperature, 0.01),
                do_sample=req.temperature > 0,
                pad_token_id=tok.eos_token_id,
            )
        gen = out[0][in_len:]
        text = tok.decode(gen, skip_special_tokens=True)
        created = int(time.time())
        return {
            "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
            "object": "chat.completion",
            "created": created,
            "model": req.model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }],
            "usage": {
                "prompt_tokens": in_len,
                "completion_tokens": len(gen),
                "total_tokens": in_len + len(gen),
            },
        }

    return app


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--max-seq-len", type=int, default=16384)
    args = ap.parse_args()
    import uvicorn
    uvicorn.run(build_app(args.model_dir, args.max_seq_len),
                host="127.0.0.1", port=args.port, log_level="info")
