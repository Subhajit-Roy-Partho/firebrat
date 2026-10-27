import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
// The raw struct for llama_chat_apply_template is not re-exported by the package.
// ignore: implementation_imports
import 'package:llama_cpp_dart/src/llama_cpp.dart' show llama_chat_message;
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
    case PromptFormatKind.auto:
      // Normally formatted inside the worker with the model's own template;
      // this ChatML form is only the fallback when llama.cpp cannot apply it.
      return ChatMLFormat().formatMessages([
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userMessage},
      ]);
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
    bool allowDownload = true,
  }) async {
    if (_worker != null) return;
    _progress = onProgress;
    final path = '$modelsDir/${model.fileName}';
    if (!allowDownload) {
      final file = File(path);
      if (!await file.exists() || ((await file.length()) - model.approxSizeBytes).abs() >= model.approxSizeBytes * 0.02) {
        throw OnDeviceCompilerException('Download or import ${model.displayName} before local character research.');
      }
    } else {
      await _downloader.ensureDownloaded(model, modelsDir, onProgress: onProgress);
    }
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
    final response = await generateText(systemPrompt: buildSystemPrompt(), userMessage: userMessage,
        label: 'chunk ${chunk.chunkIdx + 1}', maxTokens: 2400);
    if (response.trim().isEmpty) {
      throw OnDeviceCompilerException('on-device generation returned empty output for chunk ${chunk.chunkIdx}');
    }
    return parseCompiledChunkResponse(response, nextFormulaNumber: nextFormulaNumber);
  }

  /// General local inference, also used for grounded novel character enrichment.
  /// No network calls; ensureReady(allowDownload: false) enforces offline setup.
  Future<String> generateText({required String systemPrompt, required String userMessage,
      int maxTokens = 1200, String label = 'local analysis'}) async {
    if (_commands == null) throw StateError('Load a local model before generation');
    final auto = model.promptFormat == PromptFormatKind.auto;
    final user = model.id.startsWith('qwen3-') ? '$userMessage\n/no_think' : userMessage;
    final prompt = formatOnDevicePrompt(model.promptFormat, systemPrompt, user);
    final result = Map<String, dynamic>.from(await _request({
      'command': 'generate', 'prompt': prompt, 'label': label,
      'maxTokens': maxTokens.clamp(1, 2400),
      if (auto) ...{'system': systemPrompt, 'user': user, 'assistantPrefix': model.assistantPrefix},
    }) as Map);
    final response = result.remove('text') as String;
    lastGenerationStats = result;
    lastRawResponse = response;
    return response;
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
        Llama open(int layers) => Llama(request['path'] as String,
          modelParams: ModelParams()..nGpuLayers = layers,
          contextParams: ContextParams()
            ..nCtx = 4096 ..nBatch = 1536 ..nUbatch = 128
            ..nThreads = 4 ..nThreadsBatch = 4 ..nPredict = 2400,
          samplerParams: SamplerParams()..temp = 0.2..seed = 42,
          verbose: false);
        final wanted = request['gpuLayers'] as int;
        var used = wanted;
        try {
          llama = open(wanted);
        } catch (error) {
          // Accelerator unavailable or out of memory: degrade to CPU instead
          // of failing the conversion.
          if (wanted == 0) rethrow;
          replies.send({'progress': 'GPU load failed ($error); falling back to CPU'});
          used = 0;
          llama = open(0);
        }
        replies.send({'progress': 'language model running on: ${used > 0 ? 'GPU (Vulkan/OpenCL, $used layers requested)' : 'CPU'}'});
        replies.send({'result': true, 'id': request['id']});
      } else if (request['command'] == 'dispose') {
        llama?.dispose();
        llama = null;
        replies.send({'result': true, 'id': request['id']});
      } else if (request['command'] == 'generate') {
        final engine = llama!;
        engine.clear();
        replies.send({'progress': '${request['label']}: reading source text'});
        final watch = Stopwatch()..start();
        var prompt = request['prompt'] as String;
        if (request['system'] != null) {
          // The model's own chat template (GGUF metadata) through llama.cpp; ChatML if it cannot be applied.
          prompt = (_applyModelTemplate(engine, request['system'] as String, request['user'] as String) ?? prompt) +
              ((request['assistantPrefix'] as String?) ?? '');
        }
        final promptTokens = _countTokens(engine, prompt);
        engine.setPrompt(prompt);
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
            replies.send({'progress': '${request['label']}: generated $tokens tokens'});
            await Future<void>.delayed(Duration.zero);
          }
          if (tokens >= (request['maxTokens'] as int? ?? 2400)) { hitTokenLimit = true; break; }
        }
        replies.send({'result': {'text': output.toString(),
          'generated_tokens': tokens, 'first_token_ms': firstTokenMs, 'prompt_tokens': promptTokens,
          'generation_ms': watch.elapsedMilliseconds,
          'context_limit': contextLimit, 'token_limit': hitTokenLimit},
          'id': request['id']});
      }
    } catch (error) {
      replies.send({'error': error.toString(), 'id': request['id']});
    }
  }
}

/// Prompt length in tokens (for throughput reporting); -1 when it cannot be counted.
int _countTokens(Llama engine, String text) {
  final bytes = text.toNativeUtf8();
  try {
    final n = Llama.lib.llama_tokenize(engine.vocab, bytes.cast<Char>(), bytes.length, nullptr, 0, true, true);
    return n < 0 ? -n : n;
  } catch (_) {
    return -1;
  } finally {
    malloc.free(bytes);
  }
}

/// Formats [system]/[user] with the template stored in the model file. Null if
/// the model has none or llama.cpp's template matcher does not know it.
String? _applyModelTemplate(Llama engine, String system, String user) {
  final lib = Llama.lib;
  final tmpl = lib.llama_model_chat_template(engine.model, nullptr);
  if (tmpl == nullptr) return null;
  final roles = ['system', 'user'].map((r) => r.toNativeUtf8()).toList();
  final contents = [system, user].map((c) => c.toNativeUtf8()).toList();
  final messages = malloc<llama_chat_message>(2);
  try {
    for (var i = 0; i < 2; i++) {
      final slot = (messages + i).ref;
      slot.role = roles[i].cast<Char>();
      slot.content = contents[i].cast<Char>();
    }
    final capacity = (system.length + user.length) * 4 + 4096;
    final buffer = malloc<Uint8>(capacity);
    try {
      final n = lib.llama_chat_apply_template(tmpl, messages, 2, true, buffer.cast<Char>(), capacity);
      if (n <= 0 || n > capacity) return null;
      return utf8.decode(buffer.asTypedList(n), allowMalformed: true);
    } finally {
      malloc.free(buffer);
    }
  } finally {
    malloc.free(messages);
    for (final p in [...roles, ...contents]) {
      malloc.free(p);
    }
  }
}

class OnDeviceCompilerException implements Exception {
  final String message;
  OnDeviceCompilerException(this.message);
  @override
  String toString() => 'OnDeviceCompilerException: $message';
}
