/// Catalog of on-device LLM options, downloaded directly from Hugging
/// Face as Q4_K_M-quantized GGUF weights and run locally via
/// `llama_cpp_dart` (see `on_device_compiler.dart`). This replaces the
/// earlier Cactus-based implementation: Cactus does not run GGUF/llama.cpp
/// at all — it's a closed, proprietary tensor format resolved through
/// Cactus's own hosted catalog, capped at a 1.7B/1.16GB model on the free
/// tier, with no way to load an arbitrary Hugging Face model. See
/// `mobile-Backend/README.md` "On-device LLM engine" for the full story.
///
/// Every entry here is sized to fit comfortably within an 8GB-RAM Android
/// phone's budget per `PROPOSAL.md`'s own RAM-tier numbers (Q4_K_M, ~1%
/// quality loss vs full precision, practical ceiling ~4-4.5GB resident for
/// a 4B model). Repo/filename pairs and approximate sizes were verified
/// live against the Hugging Face API on 2026-09-16 — re-verify if a
/// download 404s, since a quantizer can rename or replace a repo.
/// `approxSizeBytes` is exact only for `qwen3-4b` (byte count read directly
/// off the HF API); the rest are rounded from the GB figures found during
/// that same check and are for progress-bar/UI purposes, not exact-match
/// download verification.
library;

enum PromptFormatKind { chatml, gemma, llama3, phi }

class OnDeviceLlmModel {
  final String id;
  final String displayName;
  final String hfRepo;
  final String fileName;
  final int approxSizeBytes;
  final double approxRamGb;
  final PromptFormatKind promptFormat;
  final String description;

  const OnDeviceLlmModel({
    required this.id,
    required this.displayName,
    required this.hfRepo,
    required this.fileName,
    required this.approxSizeBytes,
    required this.approxRamGb,
    required this.promptFormat,
    required this.description,
  });

  String get downloadUrl => 'https://huggingface.co/$hfRepo/resolve/main/$fileName';
}

const List<OnDeviceLlmModel> kOnDeviceLlmCatalog = [
  OnDeviceLlmModel(
    id: 'qwen3-0.6b',
    displayName: 'Qwen3 0.6B',
    hfRepo: 'bartowski/Qwen_Qwen3-0.6B-GGUF',
    fileName: 'Qwen_Qwen3-0.6B-Q4_K_M.gguf',
    approxSizeBytes: 484 * 1024 * 1024,
    approxRamGb: 1.0,
    promptFormat: PromptFormatKind.chatml,
    description: 'Smallest, fastest option. Safe fallback on 4-6GB RAM phones.',
  ),
  OnDeviceLlmModel(
    id: 'smollm2-1.7b',
    displayName: 'SmolLM2 1.7B Instruct',
    hfRepo: 'bartowski/SmolLM2-1.7B-Instruct-GGUF',
    fileName: 'SmolLM2-1.7B-Instruct-Q4_K_M.gguf',
    approxSizeBytes: 1138166169,
    approxRamGb: 1.7,
    promptFormat: PromptFormatKind.chatml,
    description: 'Small general model, good low-RAM fallback for 6GB+ phones.',
  ),
  OnDeviceLlmModel(
    id: 'qwen3-1.7b',
    displayName: 'Qwen3 1.7B',
    hfRepo: 'bartowski/Qwen_Qwen3-1.7B-GGUF',
    fileName: 'Qwen_Qwen3-1.7B-Q4_K_M.gguf',
    approxSizeBytes: 1374389534,
    approxRamGb: 2.0,
    promptFormat: PromptFormatKind.chatml,
    description: 'Balanced default for 6-8GB RAM phones.',
  ),
  OnDeviceLlmModel(
    id: 'llama-3.2-3b',
    displayName: 'Llama 3.2 3B Instruct',
    hfRepo: 'bartowski/Llama-3.2-3B-Instruct-GGUF',
    fileName: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    approxSizeBytes: 2169770016,
    approxRamGb: 3.0,
    promptFormat: PromptFormatKind.llama3,
    description: "Meta's general-purpose 3B model — strong quality/RAM tradeoff for 8GB phones.",
  ),
  OnDeviceLlmModel(
    id: 'qwen3-4b',
    displayName: 'Qwen3 4B Instruct (2507)',
    hfRepo: 'bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF',
    fileName: 'Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf',
    approxSizeBytes: 2497280736,
    approxRamGb: 3.8,
    promptFormat: PromptFormatKind.chatml,
    description: 'Best general quality that still comfortably fits an 8GB phone. Recommended default.',
  ),
  OnDeviceLlmModel(
    id: 'gemma-3-4b',
    displayName: 'Gemma 3 4B IT',
    hfRepo: 'bartowski/google_gemma-3-4b-it-GGUF',
    fileName: 'google_gemma-3-4b-it-Q4_K_M.gguf',
    approxSizeBytes: 2673901568,
    approxRamGb: 3.8,
    promptFormat: PromptFormatKind.gemma,
    description: "Google's 4B instruction-tuned model — strong alternative to Qwen3 4B.",
  ),
  OnDeviceLlmModel(
    id: 'phi-4-mini',
    displayName: 'Phi-4 Mini Instruct',
    hfRepo: 'bartowski/microsoft_Phi-4-mini-instruct-GGUF',
    fileName: 'microsoft_Phi-4-mini-instruct-Q4_K_M.gguf',
    approxSizeBytes: 2673901568,
    approxRamGb: 3.8,
    promptFormat: PromptFormatKind.phi,
    description: "Microsoft's 4B-class model, strong at structured/math-adjacent tasks.",
  ),
];

const String kDefaultOnDeviceLlmId = 'qwen3-4b';

OnDeviceLlmModel findOnDeviceLlmModel(String? id) => kOnDeviceLlmCatalog.firstWhere(
      (m) => m.id == id,
      orElse: () => kOnDeviceLlmCatalog.firstWhere((m) => m.id == kDefaultOnDeviceLlmId),
    );
