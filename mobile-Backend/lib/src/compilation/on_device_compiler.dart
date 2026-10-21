import 'dart:async';
import 'dart:isolate';
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
String formatOnDevicePrompt(PromptFormatKind kind, String systemPrompt, String userMessage) {
  switch (kind) {
    case PromptFormatKind.chatml:
      return ChatMLFormat().formatMessages([
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userMessage},
      ]);
    case PromptFormatKind.gemma:
      // Gemma 1-3 have no system role: prepend instructions to the same
      // initial user turn instead of emitting consecutive user turns.
      return GemmaFormat().formatPrompt('$systemPrompt\n\n$userMessage');
    case PromptFormatKind.llama3:
      return '<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n'
          '$systemPrompt<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n'
          '$userMessage<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n';
    case PromptFormatKind.phi:
      return '<|system|>\n$systemPrompt<|end|>\n<|user|>\n$userMessage<|end|>\n<|assistant|>\n';
  }
}

/// Runs downloaded GGUF weights through the Android plugin's pinned llama.cpp.
/// Call from the conversion service isolate: model loading and token evaluation
/// use synchronous native calls. Models and voices must be downloaded before
/// disconnecting. GPU offload depends on driver support and available memory;
/// setting [gpuLayers] to zero selects CPU inference.
class OnDeviceCompiler {
  final OnDeviceLlmModel model;
  final int gpuLayers;
  final ModelDownloader _downloader = ModelDownloader();
  Isolate? _worker;
  ReceivePort? _replies;
  SendPort? _commands;
  ModelDownloadProgress? _progress;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextRequest = 0;
  Map<String, dynamic> lastGenerationStats = {};
  String lastRawResponse = '';

  Future<Object?> _request(Map<String, Object?> message) {
    final id = _nextRequest++;
    final result = Completer<Object?>();
    _pending[id] = result;
    _commands!.send({...message, 'id': id});
    return result.future;
  }

  OnDeviceCompiler({OnDeviceLlmModel? model, this.gpuLayers = 0}) : model = model ?? findOnDeviceLlmModel(null);

  Future<void> ensureReady({
    required String modelsDir,
    ModelDownloadProgress? onProgress,
  }) async {
    if (_worker != null) return;
    _progress = onProgress;
    final path = await _downloader.ensureDownloaded(model, modelsDir, onProgress: onProgress);
    final ready = Completer<SendPort>();
    final replies = _replies = ReceivePort();
    replies.listen((dynamic message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message == null || message is List) {
        final error = OnDeviceCompilerException('Local model worker stopped: $message');
        if (!ready.isCompleted) ready.completeError(error);
        for (final result in _pending.values) {
          if (!result.isCompleted) result.completeError(error);
        }
        _pending.clear();
        _commands = null;
      } else if (message is Map && message.containsKey('progress')) {
        _progress?.call(null, message['progress'] as String);
      } else if (message is Map) {
        final pending = _pending.remove(message['id']);
        if (message['error'] != null) {
          pending?.completeError(OnDeviceCompilerException(message['error'].toString()));
        } else {
          pending?.complete(message['result']);
        }
      }
    });
    _worker = await Isolate.spawn(_llamaWorker, replies.sendPort,
        onError: replies.sendPort, onExit: replies.sendPort);
    _commands = await ready.future;
    await _request({'command': 'load', 'path': path, 'gpuLayers': gpuLayers});
  }

  Future<CompiledChunkOutput> compileChunk(
    PageChunk chunk, {
    required int Function() nextFormulaNumber,
  }) async {
    if (_commands == null) throw StateError('Load a local model before compiling');
    final userMessage = buildUserMessage(
      chunk.chunkIdx,
      chunk.pages.map((p) => (pageIdx: p.pageIdx, text: p.text)).toList(),
    );
    final prompt = formatOnDevicePrompt(model.promptFormat, buildSystemPrompt(),
        model.id.startsWith('qwen3-') ? '$userMessage\n/no_think' : userMessage);

    final result = Map<String, dynamic>.from(await _request({
      'command': 'generate', 'prompt': prompt, 'chunk': chunk.chunkIdx + 1}) as Map);
    final response = result.remove('text') as String;
    lastGenerationStats = result;
    lastRawResponse = response;
    if (response.trim().isEmpty) {
      throw OnDeviceCompilerException('on-device generation returned empty output for chunk ${chunk.chunkIdx}');
    }
    return parseCompiledChunkResponse(response, nextFormulaNumber: nextFormulaNumber);
  }

  Future<void> dispose() async {
    if (_commands != null) {
      try { await _request({'command': 'dispose'}); } catch (_) {}
    }
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _commands = null;
    _replies?.close();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(StateError('Local compiler disposed'));
    }
    _pending.clear();
  }
}

// Flutter foreground engines can share Android's platform thread. Keep all
// blocking native model work in a real Dart worker isolate, with no plugins.
void _llamaWorker(SendPort replies) async {
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  Llama? llama;
  await for (final dynamic message in commands) {
    final request = message as Map;
    try {
      if (request['command'] == 'load') {
        replies.send({'progress': 'loading model in background worker'});
        Llama.lib.ggml_backend_load_all();
        final devices = Llama.lib.ggml_backend_dev_count();
        replies.send({'progress': 'native backends: $devices device(s)'});
        llama = Llama(request['path'] as String,
          modelParams: ModelParams()..nGpuLayers = request['gpuLayers'] as int,
          contextParams: ContextParams()
            ..nCtx = 4096 ..nBatch = 1536 ..nUbatch = 128
            ..nThreads = 4 ..nThreadsBatch = 4 ..nPredict = 2400,
          samplerParams: SamplerParams()..temp = 0.2..seed = 42,
          verbose: false);
        replies.send({'result': true, 'id': request['id']});
      } else if (request['command'] == 'dispose') {
        llama?.dispose();
        llama = null;
        replies.send({'result': true, 'id': request['id']});
      } else if (request['command'] == 'generate') {
        final engine = llama!;
        engine.clear();
        replies.send({'progress': 'chunk ${request['chunk']}: reading source text'});
        final watch = Stopwatch()..start();
        engine.setPrompt(request['prompt'] as String);
        final output = StringBuffer();
        var tokens = 0;
        int? firstTokenMs;
        var contextLimit = false;
        var hitTokenLimit = false;
        while (true) {
          final (piece, done, limit) = engine.getNextWithStatus();
          contextLimit = limit;
          if (done || limit) break;
          firstTokenMs ??= watch.elapsedMilliseconds;
          output.write(piece);
          tokens++;
          if (tokens == 1 || tokens % 32 == 0) {
            replies.send({'progress': 'chunk ${request['chunk']}: generated $tokens tokens'});
            await Future<void>.delayed(Duration.zero);
          }
          if (tokens >= 2400) { hitTokenLimit = true; break; }
        }
        replies.send({'result': {'text': output.toString(),
          'generated_tokens': tokens, 'first_token_ms': firstTokenMs,
          'generation_ms': watch.elapsedMilliseconds,
          'context_limit': contextLimit, 'token_limit': hitTokenLimit},
          'id': request['id']});
      }
    } catch (error) {
      replies.send({'error': error.toString(), 'id': request['id']});
    }
  }
}

class OnDeviceCompilerException implements Exception {
  final String message;
  OnDeviceCompilerException(this.message);
  @override
  String toString() => 'OnDeviceCompilerException: $message';
}
