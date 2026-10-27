/// Catalog of on-device LLM options, downloaded directly from Hugging
/// Face as Q4_K_M-quantized GGUF weights and run locally via
/// `llama_cpp_dart` (see `on_device_compiler.dart`). This replaces the
/// earlier Cactus-based implementation: Cactus does not run GGUF/llama.cpp
/// at all — it's a closed, proprietary tensor format resolved through
/// Cactus's own hosted catalog, capped at a 1.7B/1.16GB model on the free
/// tier, with no way to load an arbitrary Hugging Face model. See
/// `mobile-Backend/README.md` "On-device LLM engine" for the full story.
///
/// Memory requirements depend on context length, GPU allocations, and other
/// running apps. A catalog estimate is not a guarantee that Android can keep
/// a model resident. Smaller models are useful when memory pressure closes
/// a conversion. Sizes and SHA-256 checksums were read from the Hugging Face LFS metadata
/// (2026-10-26); the downloader verifies them for fresh downloads.
library;

import '../models/device_capabilities.dart';
import '../models/model_tier.dart';

enum PromptFormatKind { chatml, gemma, llama3, phi }

class OnDeviceLlmModel implements DownloadableAsset {
  final String id;
  @override
  final String displayName;
  final String hfRepo;
  @override
  final String fileName;
  @override
  final int approxSizeBytes;

  /// Working-set estimate of the model itself (weights + context).
  final double approxRamGb;
  final PromptFormatKind promptFormat;
  final String description;

  /// Recommended phone class.
  final ModelTier tier;

  /// Total device RAM (GB) this model needs to run comfortably. Larger than
  /// [approxRamGb]: Android, the app and other processes share the rest.
  final double minDeviceRamGb;

  /// Short licence name and where to read it.
  final String license;
  final String licenseUrl;

  /// Runtime that loads the file.
  final String runtime;

  /// Back ends this model can run on (llama.cpp: CPU, optionally Vulkan GPU).
  final Set<AccelBackend> acceleration;
  @override
  final String? sha256;

  const OnDeviceLlmModel({
    required this.id,
    required this.displayName,
    required this.hfRepo,
    required this.fileName,
    required this.approxSizeBytes,
    required this.approxRamGb,
    required this.promptFormat,
    required this.description,
    this.tier = ModelTier.balanced,
    this.minDeviceRamGb = 6,
    this.license = 'See model card',
    this.licenseUrl = '',
    this.runtime = 'llama.cpp (GGUF, Q4_K_M)',
    this.acceleration = const {AccelBackend.cpu, AccelBackend.vulkan},
    this.sha256,
  });

  @override
  String get downloadUrl => 'https://huggingface.co/$hfRepo/resolve/main/$fileName';

  double get sizeMb => approxSizeBytes / 1048576;
}

const _apache = 'Apache-2.0';
const _gemma = 'Gemma Terms of Use (not OSI open source)';
const _llama32 = 'Llama 3.2 Community License (not OSI open source)';
const _llama31 = 'Llama 3.1 Community License (not OSI open source)';

const List<OnDeviceLlmModel> kOnDeviceLlmCatalog = [
  OnDeviceLlmModel(
    id: 'qwen3-0.6b',
    displayName: 'Qwen3 0.6B',
    hfRepo: 'bartowski/Qwen_Qwen3-0.6B-GGUF',
    fileName: 'Qwen_Qwen3-0.6B-Q4_K_M.gguf',
    approxSizeBytes: 484220320,
    approxRamGb: 1.0,
    promptFormat: PromptFormatKind.chatml,
    description: 'Smallest, fastest option. Safe fallback on 4-6GB RAM phones.',
    tier: ModelTier.light,
    minDeviceRamGb: 3,
    license: _apache,
    licenseUrl: 'https://huggingface.co/Qwen/Qwen3-0.6B/blob/main/LICENSE',
    sha256: '9acfc1e001311f34b4252001b626f2e466d592a42065f66571bff3790d4e1b14',
  ),
  OnDeviceLlmModel(
    id: 'llama-3.2-1b',
    displayName: 'Llama 3.2 1B Instruct',
    hfRepo: 'bartowski/Llama-3.2-1B-Instruct-GGUF',
    fileName: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
    approxSizeBytes: 807694464,
    approxRamGb: 1.4,
    promptFormat: PromptFormatKind.llama3,
    description: 'Compact Meta model for low-memory phones.',
    tier: ModelTier.light,
    minDeviceRamGb: 3,
    license: _llama32,
    licenseUrl: 'https://www.llama.com/llama3_2/license/',
    sha256: '6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83',
  ),
  OnDeviceLlmModel(
    id: 'smollm2-1.7b',
    displayName: 'SmolLM2 1.7B Instruct',
    hfRepo: 'bartowski/SmolLM2-1.7B-Instruct-GGUF',
    fileName: 'SmolLM2-1.7B-Instruct-Q4_K_M.gguf',
    approxSizeBytes: 1055609824,
    approxRamGb: 1.7,
    promptFormat: PromptFormatKind.chatml,
    description: 'Small general model, good low-RAM fallback for 6GB+ phones.',
    tier: ModelTier.light,
    minDeviceRamGb: 3.5,
    license: _apache,
    licenseUrl: 'https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct',
    sha256: '77665ea4815999596525c636fbeb56ba8b080b46ae85efef4f0d986a139834d7',
  ),
  OnDeviceLlmModel(
    id: 'qwen3-1.7b',
    displayName: 'Qwen3 1.7B',
    hfRepo: 'bartowski/Qwen_Qwen3-1.7B-GGUF',
    fileName: 'Qwen_Qwen3-1.7B-Q4_K_M.gguf',
    approxSizeBytes: 1282439584,
    approxRamGb: 2.0,
    promptFormat: PromptFormatKind.chatml,
    description: 'Balanced default for 6-8GB RAM phones.',
    tier: ModelTier.light,
    minDeviceRamGb: 3.5,
    license: _apache,
    licenseUrl: 'https://huggingface.co/Qwen/Qwen3-1.7B/blob/main/LICENSE',
    sha256: '72c5c3cb38fa32d5256e2fe30d03e7a64c6c79e668ad84057e3bd66e250b24fb',
  ),
  OnDeviceLlmModel(
    id: 'gemma-3-1b',
    displayName: 'Gemma 3 1B IT',
    hfRepo: 'bartowski/google_gemma-3-1b-it-GGUF',
    fileName: 'google_gemma-3-1b-it-Q4_K_M.gguf',
    approxSizeBytes: 806058496,
    approxRamGb: 1.5,
    promptFormat: PromptFormatKind.gemma,
    description: 'Compact text-only Gemma option for lower-memory phones.',
    tier: ModelTier.light,
    minDeviceRamGb: 3,
    license: _gemma,
    licenseUrl: 'https://ai.google.dev/gemma/terms',
    sha256: '12bf0fff8815d5f73a3c9b586bd8fee8e7b248c935de70dec367679873d0f29d',
  ),
  OnDeviceLlmModel(
    id: 'llama-3.2-3b',
    displayName: 'Llama 3.2 3B Instruct',
    hfRepo: 'bartowski/Llama-3.2-3B-Instruct-GGUF',
    fileName: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    approxSizeBytes: 2019377696,
    approxRamGb: 3.0,
    promptFormat: PromptFormatKind.llama3,
    description: "Meta's general-purpose 3B model — strong quality/RAM tradeoff for 8GB phones.",
    tier: ModelTier.balanced,
    minDeviceRamGb: 6,
    license: _llama32,
    licenseUrl: 'https://www.llama.com/llama3_2/license/',
    sha256: '6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff',
  ),
  OnDeviceLlmModel(
    id: 'qwen3-4b',
    displayName: 'Qwen3 4B Instruct (2507)',
    hfRepo: 'bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF',
    fileName: 'Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf',
    approxSizeBytes: 2497280736,
    approxRamGb: 3.8,
    promptFormat: PromptFormatKind.chatml,
    description: 'Higher quality option; may exceed available memory on 8GB phones, especially with GPU offload.',
    tier: ModelTier.balanced,
    minDeviceRamGb: 6,
    license: _apache,
    licenseUrl: 'https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507/blob/main/LICENSE',
    sha256: '2fde00ce69dd4899c70d020845e2638353015bba0fdf161b3eb965f2bca4464e',
  ),
  OnDeviceLlmModel(
    id: 'gemma-3-4b',
    displayName: 'Gemma 3 4B IT',
    hfRepo: 'bartowski/google_gemma-3-4b-it-GGUF',
    fileName: 'google_gemma-3-4b-it-Q4_K_M.gguf',
    approxSizeBytes: 2489758112,
    approxRamGb: 3.8,
    promptFormat: PromptFormatKind.gemma,
    description: "Google's 4B instruction-tuned model — strong alternative to Qwen3 4B.",
    tier: ModelTier.balanced,
    minDeviceRamGb: 6,
    license: _gemma,
    licenseUrl: 'https://ai.google.dev/gemma/terms',
    sha256: '4996030242583a40aa151ff93f49ed787ac8c25e4120c3ae4588b2e2a7d1ae94',
  ),
  OnDeviceLlmModel(
    id: 'phi-4-mini',
    displayName: 'Phi-4 Mini Instruct',
    hfRepo: 'bartowski/microsoft_Phi-4-mini-instruct-GGUF',
    fileName: 'microsoft_Phi-4-mini-instruct-Q4_K_M.gguf',
    approxSizeBytes: 2491874688,
    approxRamGb: 3.8,
    promptFormat: PromptFormatKind.phi,
    description: "Microsoft's 4B-class model, strong at structured/math-adjacent tasks.",
    tier: ModelTier.balanced,
    minDeviceRamGb: 6,
    license: 'MIT',
    licenseUrl: 'https://huggingface.co/microsoft/Phi-4-mini-instruct/blob/main/LICENSE',
    sha256: '01999f17c39cc3074afae5e9c539bc82d45f2dd7faa3917c66cbef76fce8c0c2',
  ),
  OnDeviceLlmModel(
    id: 'qwen3-8b',
    displayName: 'Qwen3 8B',
    hfRepo: 'bartowski/Qwen_Qwen3-8B-GGUF',
    fileName: 'Qwen_Qwen3-8B-Q4_K_M.gguf',
    approxSizeBytes: 5027784224,
    approxRamGb: 6.2,
    promptFormat: PromptFormatKind.chatml,
    description: 'Noticeably better character and narration quality. For 12GB phones; slow on the phone CPU.',
    tier: ModelTier.powerful,
    minDeviceRamGb: 10,
    license: _apache,
    licenseUrl: 'https://huggingface.co/Qwen/Qwen3-8B/blob/main/LICENSE',
    sha256: '54fffa050078e984116639c83dfb64b5aa6d4cd474e018b076777c632bbccccd',
  ),
  OnDeviceLlmModel(
    id: 'llama-3.1-8b',
    displayName: 'Llama 3.1 8B Instruct',
    hfRepo: 'bartowski/Meta-Llama-3.1-8B-Instruct-GGUF',
    fileName: 'Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
    approxSizeBytes: 4920739232,
    approxRamGb: 6.0,
    promptFormat: PromptFormatKind.llama3,
    description: "Meta's 8B instruction model. For 12GB phones; slow on the phone CPU.",
    tier: ModelTier.powerful,
    minDeviceRamGb: 10,
    license: _llama31,
    licenseUrl: 'https://www.llama.com/llama3_1/license/',
    sha256: '7b064f5842bf9532c91456deda288a1b672397a54fa729aa665952863033557c',
  ),
  OnDeviceLlmModel(
    id: 'gemma-3-12b',
    displayName: 'Gemma 3 12B IT',
    hfRepo: 'bartowski/google_gemma-3-12b-it-GGUF',
    fileName: 'google_gemma-3-12b-it-Q4_K_M.gguf',
    approxSizeBytes: 7300575264,
    approxRamGb: 9.0,
    promptFormat: PromptFormatKind.gemma,
    description: 'Desktop-class quality. Only for 16GB phones; expect very slow, hot, battery-heavy runs.',
    tier: ModelTier.desktopClass,
    minDeviceRamGb: 14,
    license: _gemma,
    licenseUrl: 'https://ai.google.dev/gemma/terms',
    sha256: 'fc57f67efa46d711c346e587cbef7d049e95f3df8db2eb2271153343ef0acc7b',
  ),
  OnDeviceLlmModel(
    id: 'qwen3-14b',
    displayName: 'Qwen3 14B',
    hfRepo: 'bartowski/Qwen_Qwen3-14B-GGUF',
    fileName: 'Qwen_Qwen3-14B-Q4_K_M.gguf',
    approxSizeBytes: 9001753632,
    approxRamGb: 11.0,
    promptFormat: PromptFormatKind.chatml,
    description: 'Largest option, best quality. Only for 16GB phones; very slow, hot and battery heavy.',
    tier: ModelTier.desktopClass,
    minDeviceRamGb: 16,
    license: _apache,
    licenseUrl: 'https://huggingface.co/Qwen/Qwen3-14B/blob/main/LICENSE',
    sha256: '915913e22399475dbe6c968ac014d9f1fbe08975e489279aede9d5c7b2c98eb6',
  ),
];

const String kDefaultOnDeviceLlmId = 'qwen3-1.7b';

OnDeviceLlmModel findOnDeviceLlmModel(String? id) => kOnDeviceLlmCatalog.firstWhere(
      (m) => m.id == id,
      orElse: () => kOnDeviceLlmCatalog.firstWhere((m) => m.id == kDefaultOnDeviceLlmId),
    );

/// Best catalog model for [device]: the largest one (by tier, then size) whose
/// RAM need the phone meets with margin, never above the phone's own tier.
/// Unknown RAM returns the safe default.
OnDeviceLlmModel recommendLlm(DeviceCapabilities device) {
  var best = findOnDeviceLlmModel(null);
  if (device.totalRamMb == null) return best;
  for (final m in llmModelsByTier()) {
    if (m.tier.index > device.tier.index) continue;
    final fit = assessFit(name: m.displayName, minDeviceRamGb: m.minDeviceRamGb, device: device).fit;
    if (fit == ModelFit.good) best = m;
  }
  return best;
}

/// Catalog models grouped by tier, in ascending tier order then size.
List<OnDeviceLlmModel> llmModelsByTier() {
  final list = [...kOnDeviceLlmCatalog];
  list.sort((a, b) {
    final t = a.tier.index.compareTo(b.tier.index);
    return t != 0 ? t : a.approxSizeBytes.compareTo(b.approxSizeBytes);
  });
  return list;
}
