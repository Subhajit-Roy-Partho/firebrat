"""One-chunk quality probe: feeds REAL DDCA pages 10-11 through the real
Stage-2 prompt + chat_json against the LOCAL Qwen3-4B server, validates
the schema, and scores word coverage. Answers: can the local LLM do the
narration job (not just toy JSON)?
Run: env -u MODEL_API_KEY -u NANO_API_KEY NANO_API_URL=http://127.0.0.1:8080/v1
     <serve-python> backend/scripts/probe_local_chunk.py
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ["NANO_API_URL"] = "http://127.0.0.1:8080/v1"
os.environ["NANO_API_KEY"] = "local"
os.environ.pop("MODEL_API_KEY", None)

from firebrat.pipeline.compile_llm import (
    SYSTEM_PROMPT,
    _build_user_message,
    _normalize_wrapper,
    _sanitize_refs,
    _sanitize_latex,
    LLMOutput,
)
from firebrat.llm_client import chat_json

STOP = set("""the a an and or of to in on for with as by at from is are was were be been it its this that these those they them he she we you i have has had do does did will would can could should may not no yes if then than so such only also very more most other into over under between through during through each every any all both few many much own same me my him her us our your their what which who whom whose when where why how because until while against among within without about than too s fig figure table page pages chapter section shown above below follows following example eq equation""".split())


def words(t):
    return [w for w in re.findall(r"[a-z0-9]+", t.lower()) if w not in STOP and len(w) > 2]


raw = json.load(open("/scratch/sroy85/unabridged-test/ddca-unabridged-test/raw/raw_pages.json"))
pages = [p for p in raw["pages"] if p["page_idx"] in (10, 11)]
chunk = {"chunk_idx": 0, "page_range": (10, 11), "pages": pages,
         "catalog": {"figures": [], "tables": []}}
messages = [
    {"role": "system", "content": SYSTEM_PROMPT},
    {"role": "user", "content": _build_user_message(chunk)},
]
print(f"prompt chars: {len(messages[0]['content']) + len(messages[1]['content'])}", flush=True)
parsed, model = chat_json(messages, "local-qwen3-4b", temperature=0.2,
                          max_tokens=16000, retries_parse=1, timeout=1200)
parsed = _sanitize_latex(_sanitize_refs(_normalize_wrapper(parsed)))
output = LLMOutput.model_validate(parsed)
nseg = sum(len(s.segments) for s in output.sections)
src = set()
for p in pages:
    src |= set(words((p.get("text") or "") + " " + (p.get("markdown") or "")))
nar = set()
for s in output.sections:
    for seg in s.segments:
        nar |= set(words(seg.text))
print(f"LOCAL-CHUNK-RESULT sections={len(output.sections)} segments={nseg} "
      f"src_words={len(src)} coverage={len(src & nar)/max(1, len(src)):.2f}", flush=True)
for s in output.sections:
    print(f"  - {s.title[:80]} ({len(s.segments)} segs)", flush=True)
