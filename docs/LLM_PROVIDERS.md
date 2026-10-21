# Stage-2 LLM providers: nano-gpt vs local GPU

Stage 2 (`firebrat/pipeline/compile_llm.py`) sends each page-chunk to an
OpenAI-compatible `/chat/completions` endpoint. Which endpoint is picked
by two env vars (`docs/ENV.md`), so switching providers is configuration,
not code:

| variable | default | meaning |
|---|---|---|
| `MODEL_API_KEY` (`NANO_API_KEY` alias) | `""` | Bearer key. Any string works against the local server (accepted, ignored). |
| `NANO_API_URL` | `https://nano-gpt.com/api/v1` | Base URL. Point at `http://127.0.0.1:8080/v1` for local. |
| `LLM_PROVIDER` | `nanogpt` | Only read by `backend/docker/entrypoint.sh`: `local` also boots the bundled LLM server. Bare-metal runs set `NANO_API_URL` directly instead. |
| `LOCAL_MODEL_DIR` | — | (Docker `local` mode) mounted HF snapshot dir, e.g. `/models/qwen3-4b`. |
| `LOCAL_LLM_PORT` / `LOCAL_MAX_SEQ_LEN` | `8080` / `16384` | Shim port and context cap. |
| `FIREBRAT_CHUNK_PAGES` | `10` | Pages per LLM chunk. Lower it if your endpoint kills long generations (below). |

## Option A — nano-gpt (default)

Managed endpoint, no GPU needed for Stage 2. Model routing lives in
`firebrat/config.py`: `z-ai/glm-5.3-flash` both tiers (env-overridable).
Verify a key with a real `chat/completions` call — a `models` listing can
succeed while chat 401s (this happened here; see `AGENTS.md`).

Known endpoint behavior (measured Sep 2026, may change):
- **~340s connection wall.** Thinking-tier generations past ~5m40s get
  `RemoteDisconnected`, every time, at the same elapsed time. A dense
  10-page chunk's unabridged output needs longer than that, so default
  chunks die 5/5 retries. Workaround: `FIREBRAT_CHUNK_PAGES=2` (≈350
  calls for a 700-page book, ~3–5 min each ≈ 15–25 h total).
- **7k completion budget is too small.** Unabridged output runs 4–14k
  tokens/chunk; `compile_llm.py` therefore requests `max_tokens=16000`,
  `timeout=600`. Don't lower these without re-measuring.

## Option B — local GPU model (verified on Tesla V100 16GB)

`backend/scripts/llm_server.py` is a minimal OpenAI-compatible shim
(`POST /v1/chat/completions` only — the one endpoint `llm_client.py`
uses) around HF `transformers`. Verified Sep 2026: Qwen3-4B-Instruct
(`Qwen/Qwen3-4B-Instruct-2507`, fp16 ≈ 8GB) on a V100, real DDCA pages
10–11 through the true Stage-2 prompt → schema-valid, 2 sections /
17 segments, 0.77 word coverage (nano-gpt scored ~0.79 on the same pages).

Setup recipe (what was actually required on this Rocky 8 box):
1. Model: `huggingface_hub.snapshot_download('Qwen/Qwen3-4B-Instruct-2507',
   local_dir=..., allow_patterns=['*.json','*.safetensors','tokenizer*','*.txt'])`.
2. Env with torch that still ships sm_70 (V100) kernels: torch 2.13 **cu126**
   build (`pip install torch==2.13.0 --index-url .../cu126`) — cu130
   dropped Volta entirely. Plus matching `torchvision` (transformers'
   `modeling_qwen3` import chain requires it), `transformers`,
   `accelerate`, `fastapi`, `uvicorn[standard]`.
3. Dead ends, so you don't repeat them: prebuilt llama.cpp CUDA wheels
   need glibc ≥ 2.29 (Rocky 8 has 2.28); source builds need nvcc
   (absent); CPU-only llama.cpp is too slow for book-scale output.
4. Run: `python backend/scripts/llm_server.py --model-dir ... --port 8080`
   (tmux), then `NANO_API_URL=http://127.0.0.1:8080/v1`.
5. VRAM budget (measured): 4B fp16 ≈ 8GB weights + ~2.5GB KV @16k ctx.
   **Do not run it alongside Stage 3 TTS** — Chatterbox needs the same
   VRAM, and the combination OOM-killed a conversion here. One GPU job
   at a time.
6. Speed honesty: ~15–30 tok/s on V100 → 7–13 min per dense chunk.
   Slower than nano-gpt per chunk, but no wall, no quotas, no key.
   Keep one model per book (audibly consistent narration).

`backend/scripts/probe_local_chunk.py` replays a real 2-page chunk
through the pipeline prompt + `chat_json` against the local server and
scores coverage — run it after any server/model change.

## Docker

`subhajitroy/firebrat:gpu` (CI-built, see
`.github/workflows/docker-publish.yml`) bundles the shim's deps in the
extract venv. Weights are deliberately NOT baked in — mount them:

```bash
# nano-gpt (or any OpenAI-compatible endpoint):
docker run -e MODEL_API_KEY=sk-... -v books:/data -p 8000:8000 \
    subhajitroy/firebrat:latest
# local GPU model (needs --gpus all + a models volume):
docker run --gpus all -e LLM_PROVIDER=local \
    -e LOCAL_MODEL_DIR=/models/qwen3-4b -v /host/models:/models \
    -v books:/data -p 8000:8000 subhajitroy/firebrat:latest
```
