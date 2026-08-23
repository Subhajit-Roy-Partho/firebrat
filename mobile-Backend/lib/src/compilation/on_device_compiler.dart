import 'package:cactus/cactus.dart';
import '../models/compiled_models.dart';
import '../models/raw_page.dart';
import 'prompt.dart';
import 'response_parser.dart';

typedef ModelDownloadProgress = void Function(double? progress, String status);

/// Wraps `CactusLM` for the "easy" chunk tier (prose-only, no equation
/// hints — see `routing.dart`). The model is downloaded once by the plugin
/// itself (from Cactus's model catalog, by slug) and cached on-device;
/// nothing is bundled into the app.
///
/// **Not runtime-verified**: this compiles and type-checks against the
/// `cactus` package's real API (see package README), but actually running
/// on-device inference needs a physical device/emulator this sandbox
/// cannot provide (`adb` does not run here — see `frontend/firebrat_app`'s
/// `AGENTS.md`). Treat this class as reviewed, not proven.
class OnDeviceCompiler {
  final String modelSlug;
  final CactusLM _lm = CactusLM();
  bool _initialized = false;

  OnDeviceCompiler({this.modelSlug = 'qwen3-0.6'});

  Future<void> ensureReady({ModelDownloadProgress? onProgress}) async {
    if (_initialized) return;
    await _lm.downloadModel(
      model: modelSlug,
      downloadProcessCallback: (progress, status, isError) {
        onProgress?.call(progress, status);
      },
    );
    await _lm.initializeModel(params: CactusInitParams(model: modelSlug, contextSize: 4096));
    _initialized = true;
  }

  Future<CompiledChunkOutput> compileChunk(
    PageChunk chunk, {
    required int Function() nextFormulaNumber,
  }) async {
    if (!_initialized) {
      throw StateError('OnDeviceCompiler.ensureReady() must succeed before compileChunk()');
    }
    final userMessage = buildUserMessage(
      chunk.chunkIdx,
      chunk.pages.map((p) => (pageIdx: p.pageIdx, text: p.text)).toList(),
    );
    final result = await _lm.generateCompletion(
      messages: [
        ChatMessage(content: buildSystemPrompt(), role: 'system'),
        ChatMessage(content: userMessage, role: 'user'),
      ],
      params: CactusCompletionParams(temperature: 0.2, maxTokens: 3000),
    );
    if (!result.success) {
      throw OnDeviceCompilerException('on-device generation failed for chunk ${chunk.chunkIdx}');
    }
    return parseCompiledChunkResponse(result.response, nextFormulaNumber: nextFormulaNumber);
  }

  void dispose() {
    if (_initialized) _lm.unload();
    _initialized = false;
  }
}

class OnDeviceCompilerException implements Exception {
  final String message;
  OnDeviceCompilerException(this.message);
  @override
  String toString() => 'OnDeviceCompilerException: $message';
}
