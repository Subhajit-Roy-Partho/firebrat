import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import '../models/compiled_models.dart';
import '../models/raw_page.dart';
import 'model_catalog.dart';
import 'model_downloader.dart';
import 'prompt.dart';
import 'response_parser.dart';

typedef ModelDownloadProgress = void Function(double? progress, String status);

/// Builds the raw prompt text for a model family that doesn't have a
/// dedicated formatter in `llama_cpp_dart` (Llama 3's and Phi's chat
/// templates aren't among the package's built-in `ChatMLFormat` /
/// `GemmaFormat` / `AlpacaFormat` / harmony formatters).
String _formatPrompt(PromptFormatKind kind, String systemPrompt, String userMessage) {
  switch (kind) {
    case PromptFormatKind.chatml:
      return ChatMLFormat().formatMessages([
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userMessage},
      ]);
    case PromptFormatKind.gemma:
      return GemmaFormat().formatMessages([
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userMessage},
      ]);
    case PromptFormatKind.llama3:
      return '<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n'
          '$systemPrompt<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n'
          '$userMessage<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n';
    case PromptFormatKind.phi:
      return '<|system|>\n$systemPrompt<|end|>\n<|user|>\n$userMessage<|end|>\n<|assistant|>\n';
  }
}

/// Runs a Hugging Face GGUF model locally via `llama_cpp_dart` for the
/// "easy" chunk tier (prose-only, no equation hints — see `routing.dart`).
///
/// Replaces an earlier Cactus-based implementation: Cactus turned out not
/// to run GGUF at all (a closed proprietary tensor format resolved through
/// Cactus's own hosted catalog, capped at 1.7B/1.16GB on the free tier —
/// see `model_catalog.dart`'s doc comment), so it couldn't satisfy
/// "download real weights from Hugging Face, pick from multiple models."
/// `llama_cpp_dart` compiles real llama.cpp from source via NDK/CMake at
/// Android build time (see the package's `android/build.gradle`), so any
/// GGUF file works, not just a fixed catalog.
///
/// Model weights are never bundled into the app — [ensureReady] downloads
/// the selected [OnDeviceLlmModel]'s GGUF file directly from Hugging Face
/// into [modelsDir] the first time it's needed (see `model_downloader.dart`),
/// then loads it from disk on every subsequent run.
///
/// [gpuLayers] is the hardware-acceleration knob: llama.cpp offloads this
/// many transformer layers to the GPU via its own Vulkan/OpenCL backend
/// (compiled in by `llama_cpp_dart`'s native build). `99` (the package's
/// own default) offloads everything that fits; `0` forces pure-CPU
/// inference. There's no reliable way to probe "does this phone's GPU
/// driver actually support this" ahead of time from Dart, so this is a
/// user-facing setting with a safe-looking default rather than an
/// auto-detected one — see `mobile-Backend/README.md` for the fallback
/// advice if a device's GPU driver doesn't cooperate.
///
/// **Not runtime-verified**: compiles and links against the real
/// `llama_cpp_dart` API (types/signatures read directly from the
/// installed package source and its own example), and the native library
/// builds successfully via NDK/CMake, but actually running inference needs
/// a physical device/emulator this sandbox cannot provide (no `adb`, no
/// emulator). Treat this class as reviewed, not proven — same caveat this
/// package already carried for the Cactus code it replaces.
class OnDeviceCompiler {
  final OnDeviceLlmModel model;
  final int gpuLayers;
  final ModelDownloader _downloader = ModelDownloader();
  Llama? _llama;

  OnDeviceCompiler({OnDeviceLlmModel? model, this.gpuLayers = 99}) : model = model ?? findOnDeviceLlmModel(null);

  Future<void> ensureReady({
    required String modelsDir,
    ModelDownloadProgress? onProgress,
  }) async {
    if (_llama != null) return;
    final path = await _downloader.ensureDownloaded(
      model,
      modelsDir,
      onProgress: onProgress,
    );
    onProgress?.call(null, 'loading ${model.displayName} into memory');
    _llama = Llama(
      path,
      modelParams: ModelParams()..nGpuLayers = gpuLayers,
      contextParams: ContextParams()
        ..nCtx = 4096
        ..nPredict = 3000,
      verbose: false,
    );
  }

  Future<CompiledChunkOutput> compileChunk(
    PageChunk chunk, {
    required int Function() nextFormulaNumber,
  }) async {
    final llama = _llama;
    if (llama == null) {
      throw StateError('OnDeviceCompiler.ensureReady() must succeed before compileChunk()');
    }
    final userMessage = buildUserMessage(
      chunk.chunkIdx,
      chunk.pages.map((p) => (pageIdx: p.pageIdx, text: p.text)).toList(),
    );
    final prompt = _formatPrompt(model.promptFormat, buildSystemPrompt(), userMessage);

    // Each chunk is an independent request — no multi-turn memory wanted
    // between chunks — so the context is cleared before every prompt
    // rather than accumulating turns the way the package's own chat-demo
    // example does.
    llama.clear();
    llama.setPrompt(prompt);
    final response = await llama.generateCompleteText(maxTokens: 3000);
    if (response.trim().isEmpty) {
      throw OnDeviceCompilerException('on-device generation returned empty output for chunk ${chunk.chunkIdx}');
    }
    return parseCompiledChunkResponse(response, nextFormulaNumber: nextFormulaNumber);
  }

  void dispose() {
    _llama?.dispose();
    _llama = null;
  }
}

class OnDeviceCompilerException implements Exception {
  final String message;
  OnDeviceCompilerException(this.message);
  @override
  String toString() => 'OnDeviceCompilerException: $message';
}
