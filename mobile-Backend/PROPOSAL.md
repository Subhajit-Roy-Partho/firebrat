# On-device conversion — feasibility research & proposal

Researched 2026-08-23. Question: can the PDF → audiobook pipeline (currently
a Python backend: marker-pdf extraction, an LLM compilation stage, and
chatterbox-tts narration) run entirely on the phone itself, pushed to the
edge of what current mobile hardware can do? This document is the research
findings plus a concrete recommendation — not an implementation yet.

**Short answer: two of the three stages are genuinely ready to move
on-device today. The third (LLM compilation) is ready for most chunks but
has one specific, hard-to-detect failure mode worth designing around. Full
on-device is achievable *for most of a book*, not safely for 100% of one —
see the recommendation in §5.**

---

## 1. The three stages, on-device feasibility

### 1a. Extraction (marker-pdf's job today: layout, OCR, figures/tables/formula regions)

| Sub-task | On-device today? | What to use |
|---|---|---|
| Raw text extraction from a digitally-native PDF (has a text layer already, no OCR needed) | **Yes, mature** | mupdf-based mobile bindings — direct text+position extraction, no ML model at all |
| Layout labeling (is this region body text / figure / table / caption?) | **Yes, mature** | [DocLayout-YOLO](https://github.com/opendatalab/DocLayout-YOLO) or PP-DocLayout-S — YOLOv10-based, tens of MB, ONNX-exportable, designed for exactly this |
| OCR (for scanned pages, or verifying figure/table captions) | **Yes, production-grade** | Google ML Kit Text Recognition v2 (Android), Apple Vision `RecognizeDocumentsRequest` (iOS 18+) — both fully on-device, ship in billions of phones already |
| Formula region → LaTeX (marker's Texify equivalent) | **No mature lightweight mobile option found** | Gap. See below. |

The formula-recognition gap matters less than it sounds for *this specific
project*, because — per `AGENTS.md` — the sample book barely uses
LaTeX-taggable formula regions at all; nearly all its math is typeset as
plain text (`tCK = 1/f = 10 ns`) that Stage 2's LLM already recognizes and
authors LaTeX for from prose, not from Texify. So the piece with no mobile
equivalent (image-of-an-equation → LaTeX) is one this project doesn't
currently lean on heavily. A book that *does* typeset real equation images
would hit this gap directly.

### 1b. LLM compilation (today: deepseek-v4-flash/pro via nano-gpt — narration text, ref insertion, LaTeX authoring)

**Framework**: [Cactus](https://cactuscompute.com) is the standout finding
here — a cross-platform on-device inference engine with **official Flutter
bindings already on pub.dev** (`cactus`), grammar-constrained/structured
generation (relevant for your segment/ref JSON schema), and — notably — a
**built-in cloud-fallback router** that escalates a request to a cloud model
when on-device confidence is low. That last feature maps almost exactly
onto the existing flash/pro routing heuristic in `compile_llm.py`; see §5.
The alternative low-level frameworks (ExecuTorch, MLC-LLM, Google
LiteRT-LM, Apple's Foundation Models framework) are all real and maturing
fast, but none of them hand you a ready Flutter plugin — you'd be
hand-rolling a platform channel per OS.

**Model size vs. phone**: Q4_K_M quantization is the practical sweet spot
(≈4-4.5GB for a 7B model, <1% quality loss vs full precision).

- **3-4B params, 8GB+ RAM, Snapdragon 8 Gen 2-class or newer** → 15-30
  tok/s on CPU alone; Cactus reports 70+ tok/s on 2026 flagship NPUs.
- **7-8B params** → noticeably slower on mid-range silicon; comfortable
  only on 12-16GB flagship RAM tiers.
- No mobile-sized *official* DeepSeek distill exists — an on-device model
  would be a different model family (Gemma 3/3n, Qwen3, Phi-4-mini, Llama
  3.x), not a smaller DeepSeek.

**The real risk — not speed, quality**: general-purpose small models can
plausibly hit the *shape* of the task (segments, correctly-referenced
figure/table ids) with decent prompting and grammar-constrained output.
The dangerous failure mode is specifically **LaTeX authored from prose
math** — research on structured output found that schema-valid JSON can
still contain *silently wrong content*, and this is exactly that shape: a
`formula_callout` with perfectly well-formed LaTeX that mistranscribes the
math, and nothing about the JSON's validity would catch it. Specialist
math-vision 7B models (MAVIS-7B, MultiMath-7B) close much of the gap with
frontier models *on math specifically*, but that's a different, separately
fine-tuned model from the one doing prose narration — you likely can't get
frontier-adjacent math-authoring quality out of the same general 3-4B model
that's also writing narration and picking ref ids.

### 1c. TTS (today: chatterbox-tts, voice-cloned from `narrator_ref.wav`)

- **Fixed-voice on-device TTS is mature and shippable right now**:
  [Kokoro-82M](https://soniqo.audio/guides/kokoro/android) — ~350MB, ONNX,
  faster than real-time even on CPU, 50 preset voices. Piper is even
  lighter, same limitation.
- **Voice *cloning* from an arbitrary reference clip — matching what
  chatterbox does with `narrator_ref.wav` — is the single riskiest part of
  this whole idea.** XTTS-v2 (the closest cloud-parity cloning model) is a
  1.8GB checkpoint explicitly described as not mobile-suited (~12× slower
  on CPU-only inference). The one real proof-of-concept for on-device
  cloning ([CloneTTS](https://github.com/sipeter/CloneTTS), Android,
  NPU-accelerated on Snapdragon flagships) is a small single-maintainer
  project, not vetted at production/chatterbox consistency. Academic work
  (MobileSpeech) confirms this is an active research direction, not a
  shipped, mature library yet.

### 1d. Formula *rendering* (not extraction — displaying LaTeX once you have it)

No research needed here — this is already solved. `flutter_math_fork`
already renders LaTeX as vector math client-side in the app
(`lib/widgets/formula_view.dart`); the backend's `pdflatex`+`ghostscript`
PNG rendering exists only as a fallback for LaTeX the renderer can't parse.
An on-device pipeline needs zero new work for this — it's the *producing*
of correct LaTeX (§1a, §1b) that's the open question, never the rendering.

---

## 2. Mobile hardware, 2026 snapshot

- **NPU headline numbers**: Snapdragon 8 Elite Gen 5 ≈ 80 TOPS (Qualcomm
  also claims up to 100 TOPS at INT2), Dimensity 9500 markets "first 100
  TOPS" mobile chip. **But headline TOPS doesn't predict real LLM
  throughput** — a cross-chip 2026 benchmark found Apple's A19 Pro at ~51
  tok/s (GPU/ANE) vs Snapdragon 8 Elite Gen 5's ~48.5 tok/s and Dimensity
  9500's ~16.5 tok/s, attributed to CoreML/ANE software maturity more than
  raw silicon spec. Don't spec a device off a TOPS number alone.
- **RAM** is the binding constraint if more than one model needs to be
  resident at once (layout model + LLM + TTS). Practical consensus: 1-3B
  LLM comfortable on 8GB, ~4B is the practical ceiling on mid-range RAM,
  7-8B needs 12GB+ to not be miserable.
- Apple's A18 Pro/A19 Pro punch above their RAM number specifically for LLM
  throughput (software stack advantage), but get tight running extraction +
  LLM + TTS concurrently on only 8GB.

---

## 3. Minimum device needed — tiered by what you actually run on it

| Tier | What runs on-device | Min RAM / chipset | Representative 2026 device | Approx. price |
|---|---|---|---|---|
| **1 — Extraction + free TTS only** (LLM compilation stays cloud) | Layout+OCR extraction, Kokoro fixed-voice narration | ~4-6GB RAM, any 2022+ mid-tier chipset | Redmi Note 13 Pro+, POCO X7 Pro class | **~$250-300** |
| **2 — + on-device LLM for simple chunks** | Tier 1 + a 3-4B Q4 model for prose-only chunks | 8GB+ RAM, Snapdragon 8 Gen 2/Apple A17-class or newer | Pixel 10, Xiaomi 15T Pro, iPhone with A17/A18 | **~$500-700** |
| **3 — Max-capability, everything local incl. bigger models** | Tier 2 + 7-8B model attempted for math-heavy chunks | 12-16GB RAM, Snapdragon 8 Elite Gen 4/5, Apple A18 Pro/A19 Pro | Galaxy S25/S26 Ultra, OnePlus 15, iPhone Pro | **~$900+** |

Even Tier 3, on a current flagship, does **not** close the two specific
gaps in §1b/§1c (frontier-grade LaTeX authoring, arbitrary-voice cloning)
— it just runs a bigger/faster general model, which narrows but doesn't
eliminate that risk. Buying a more expensive phone is not a substitute for
the missing pieces of the pipeline.

---

## 4. Cost of the other routes, for comparison

On-device's real cost is the device (§3, one-time). Here's what the
*status quo and its cloud alternatives* cost per book, for comparison:

| Route | What it is | Rough cost per book |
|---|---|---|
| **Current setup** (this repo, run on institutional/owned compute) | Same pipeline, LLM calls still hit the cloud API regardless of where extraction/TTS run | Near-$0 marginal compute cost (compute already owned) + LLM API tokens, see below |
| **LLM API tokens alone** (DeepSeek official pricing, Aug 2026) | V4-Flash: $0.14 in / $0.28 out per 1M tokens (cache-miss). V4-Pro: $0.435 in / $0.87 out per 1M tokens | A 659-page book chunks into ~65 ten-page chunks; at a few thousand tokens in/out per chunk this lands in the **low single-digit dollars total**, even accounting for the ~40% of chunks this project had to retry at the pricier pro tier (per `TASK.md`'s real run). Cheap regardless of self-hosting. |
| **Rent GPU compute instead of owning a cluster** (extraction + TTS stages) | A100 ≈ $0.67-1.99/hr (Vast.ai-RunPod range), H100 ≈ $1.49-3.29/hr, 2026 market rates | A full book (extraction batches + ~7.4 hours of narration audio) plausibly needs **3-6 GPU-hours** → **≈$2-12/book** on a rented A100, cheaper on Vast.ai's marketplace tier |
| **On-device (this proposal)** | Zero marginal cost per conversion once the device is owned | **$0/book**, device cost is the one-time entry fee (§3) |

The practical takeaway: **the current cloud-API route is already very
cheap per book** (DeepSeek's per-token pricing is low enough that even a
650-page book costs low single-digit dollars in LLM calls). On-device's
win isn't really "saving money over the API" — it's **offline capability,
privacy (the PDF never leaves the phone), and not depending on a server
being reachable at all**. That's the honest case for doing this, not cost.

---

## 5. Recommendation

Don't move to "fully on-device" as a single flag — the two specific gaps
(§1b's LaTeX-authoring risk, §1c's voice-cloning immaturity) are real and
would quietly degrade output quality for exactly the content this project
cares most about (math, and a deliberately chosen calm narrator voice).
Instead, propose a **hybrid, three-part rollout** that ships the mature
parts now and keeps the two risky parts on the existing cloud path until
their on-device equivalents actually mature:

1. **Move extraction on-device now.** Layout detection (DocLayout-YOLO) +
   on-device OCR (ML Kit/Vision) are production-grade today. This is a
   real win: private, offline, and removes marker-pdf/torch/PyMuPDF from
   the server-side dependency entirely for books with a text layer.

2. **Add Kokoro as a free, on-device, offline "stock voice" option**,
   *alongside* — not replacing — the existing chatterbox-tts cloud path.
   Frame it as a product choice for the user: "Narrate now, offline, free,
   stock voice" vs. "Send to server for the calm cloned narrator voice."
   Zero risk to the existing feature, real value added (works with no
   server at all).

3. **Route LLM compilation through Cactus's on-device-model with
   cloud-fallback**, reusing the *exact* heuristic `compile_llm.py`
   already has for flash-vs-pro routing (chunk looks math-heavy, or has
   2+ figures/tables → escalate). Add one more tier below flash: a local
   3-4B model handles chunks that are pure prose (no formula/figure/table
   refs at all — the common case for most of a book), everything else
   still goes to the cloud exactly as it does today. This gets the
   "mostly free, mostly offline" benefit for the bulk of a book without
   touching the one failure mode (silent bad LaTeX) that's hardest to
   catch automatically.

This ships real, valuable on-device capability now, on a device as cheap
as **Tier 1 (~$250-300, extraction+TTS only)** or **Tier 2 (~$500-700,
adds partial on-device compilation)**, without overclaiming reliability
Tier 3 hardware can't actually deliver either.

---

## Sources

**LLM/compilation**: [Cactus docs](https://docs.cactuscompute.com/v1.9/) ·
[cactus Flutter package](https://pub.dev/packages/cactus) ·
[cactus GitHub](https://github.com/cactus-compute/cactus) ·
[Google AI Edge LLM Inference](https://developers.google.com/edge/mediapipe/solutions/genai/llm_inference) ·
[Apple Foundation Models + Gemini](https://firebase.blog/posts/2026/06/apple-foundation-models-gemini/) ·
[JSONSchemaBench](https://arxiv.org/pdf/2501.10868) ·
["Capacity Not Format" structured-output paper](https://arxiv.org/pdf/2606.09410) ·
[MathVista leaderboard](https://llm-stats.com/benchmarks/mathvista) ·
[MultiMath paper](https://arxiv.org/pdf/2409.00147) ·
[DeepSeek official pricing](https://deepseek.ai/pricing).

**Extraction/OCR**: [DocLayout-YOLO paper](https://arxiv.org/abs/2503.17213) ·
[DocLayout-YOLO GitHub](https://github.com/opendatalab/DocLayout-YOLO) ·
[Google ML Kit Text Recognition v2](https://developers.google.com/ml-kit/vision/text-recognition/v2) ·
[Apple Vision docs](https://developer.apple.com/documentation/vision/recognizing-text-in-images).

**TTS**: [Kokoro on Android](https://soniqo.audio/guides/kokoro/android) ·
[TTS/STT landscape 2026](https://offlinetts.com/blog/tts-stt-landscape-h1-2026/) ·
[XTTS-v2 mobile assessment](https://localaimaster.com/models/coqui-tts) ·
[CloneTTS](https://github.com/sipeter/CloneTTS) ·
[MobileSpeech paper](https://arxiv.org/abs/2402.09378).

**Hardware**: [On-device AI cross-chip benchmark](https://gadgets.beebom.com/stories/i-tested-on-device-ai-on-android-and-iphone-results-not-even-close) ·
[Snapdragon 8 Elite Gen 5 AI spec sheet](https://multicoreperformance.com/snapdragon-8-elite-gen-5-dedicated-ai-spec-sheet-80-tops-architecture-deep-thermal-truths/) ·
[7B-on-smartphone hardware requirements](https://ithy.com/article/hardware-requirements-7b-llm-smartphones-zn83cgyg).

**Cost**: [H100 rental price comparison 2026](https://intuitionlabs.ai/articles/h100-rental-prices-cloud-comparison) ·
[GPU cloud pricing 2026](https://www.synpixcloud.com/blog/cloud-gpu-pricing-comparison-2026) ·
[DeepSeek API pricing Aug 2026](https://benchlm.ai/deepseek/api-pricing).
