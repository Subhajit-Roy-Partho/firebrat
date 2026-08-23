import 'package:dio/dio.dart';
import '../models/compiled_models.dart';
import '../models/conversion_settings.dart';
import '../models/raw_page.dart';
import 'prompt.dart';
import 'response_parser.dart';

/// OpenAI-compatible chat-completions client for the "difficult" chunks
/// (math-heavy / figure-table-dense — see `routing.dart`). Mirrors
/// `backend/firebrat/llm_client.py`'s request shape exactly, but the
/// endpoint/key/model are all user-supplied (`OnDeviceModeSettings`) —
/// this works with nano-gpt, OpenAI itself, or any other
/// OpenAI-compatible provider without code changes.
class CloudCompiler {
  final OnDeviceModeSettings settings;
  final Dio _dio;

  CloudCompiler(this.settings)
      : _dio = Dio(BaseOptions(
          baseUrl: settings.llmBaseUrl,
          connectTimeout: const Duration(seconds: 30),
          // Cloud "difficult chunk" calls can legitimately take 60-150s+
          // for a strong reasoning-tier model — see llm_client.py's own
          // 240s timeout note for why this isn't tightened.
          receiveTimeout: const Duration(seconds: 240),
          headers: {'Authorization': 'Bearer ${settings.llmApiKey}'},
        ));

  Future<CompiledChunkOutput> compileChunk(
    PageChunk chunk, {
    required int Function() nextFormulaNumber,
    int retries = 3,
  }) async {
    final messages = [
      {'role': 'system', 'content': buildSystemPrompt()},
      {
        'role': 'user',
        'content': buildUserMessage(
          chunk.chunkIdx,
          chunk.pages.map((p) => (pageIdx: p.pageIdx, text: p.text)).toList(),
        ),
      },
    ];

    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final resp = await _dio.post(
          '/chat/completions',
          data: {
            'model': settings.llmModel,
            'messages': messages,
            'temperature': 0.2,
            'max_tokens': 7000,
            'response_format': {'type': 'json_object'},
          },
        );
        final content = resp.data['choices'][0]['message']['content'] as String;
        return parseCompiledChunkResponse(content, nextFormulaNumber: nextFormulaNumber);
      } catch (e) {
        lastError = e;
        if (attempt < retries) {
          await Future.delayed(Duration(seconds: (2 * (attempt + 1))));
        }
      }
    }
    throw CloudCompilerException('cloud compilation failed after $retries retries: $lastError');
  }
}

class CloudCompilerException implements Exception {
  final String message;
  CloudCompilerException(this.message);
  @override
  String toString() => 'CloudCompilerException: $message';
}
