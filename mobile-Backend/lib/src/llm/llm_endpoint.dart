import 'package:dio/dio.dart';

class LlmEndpointException implements Exception {
  final String message;
  LlmEndpointException(this.message);
  @override
  String toString() => message;
}

/// Minimal OpenAI-compatible client (OpenRouter, Groq, Gemini's OpenAI layer,
/// nano-gpt, OpenAI, ...). Used by the settings screen to list a provider's
/// models and test the key, and by character research for one short call.
class LlmEndpoint {
  final String baseUrl;
  final String apiKey;
  final Dio _dio;

  LlmEndpoint({required String baseUrl, required this.apiKey, Dio? dio})
      : baseUrl = normalizeBaseUrl(baseUrl),
        _dio = dio ?? Dio();

  /// Adds https:// when missing and drops trailing slashes, so
  /// "openrouter.ai/api/v1/" and "https://openrouter.ai/api/v1" are one thing.
  static String normalizeBaseUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (!u.contains('://')) u = 'https://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Options get _options => Options(
        headers: {
          if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
          'Content-Type': 'application/json',
        },
        sendTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
        validateStatus: (_) => true, // map every status to a readable message below
      );

  LlmEndpointException _problem(Response<dynamic> r, {String what = 'request'}) {
    final code = r.statusCode ?? 0;
    var detail = '';
    final data = r.data;
    if (data is Map) {
      final err = data['error'];
      detail = (err is Map ? err['message'] : err)?.toString() ?? data['message']?.toString() ?? '';
    }
    final hint = switch (code) {
      401 || 403 => 'The API key was rejected. Check that it is pasted in full and has not expired.',
      404 => 'Nothing at this URL. Most providers end in /v1 (OpenRouter: https://openrouter.ai/api/v1).',
      429 => 'The provider is rate-limiting this key (free tiers allow only a few requests). Wait a minute and retry.',
      >= 500 => 'The provider had a problem. Try again shortly.',
      _ => 'Unexpected answer from the provider.',
    };
    return LlmEndpointException(
        '$what failed ($code). $hint${detail.isEmpty ? '' : ' Provider said: ${detail.length > 200 ? '${detail.substring(0, 200)}…' : detail}'}');
  }

  LlmEndpointException _network(DioException e, String what) => LlmEndpointException(
      switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          '$what timed out. Check your connection and the URL.',
        _ => '$what could not reach ${Uri.tryParse(baseUrl)?.host ?? baseUrl}. Check the URL and your connection.',
      });

  /// Model ids this key can use, sorted with free ones (":free") first.
  Future<List<String>> listModels() async {
    if (baseUrl.isEmpty) throw LlmEndpointException('Enter the LLM URL first.');
    try {
      final r = await _dio.get<dynamic>('$baseUrl/models', options: _options);
      if (r.statusCode != 200) throw _problem(r, what: 'Loading models');
      final data = r.data;
      final list = data is Map ? (data['data'] ?? data['models']) : data;
      if (list is! List) {
        throw LlmEndpointException('Loading models failed: the provider did not return a model list.');
      }
      final ids = <String>{
        for (final m in list)
          if (m is Map && m['id'] != null) m['id'].toString().replaceFirst(RegExp(r'^models/'), '')
          else if (m is String) m,
      }.toList()
        ..sort((a, b) {
          final fa = a.endsWith(':free') ? 0 : 1, fb = b.endsWith(':free') ? 0 : 1;
          return fa != fb ? fa - fb : a.compareTo(b);
        });
      return ids;
    } on DioException catch (e) {
      throw _network(e, 'Loading models');
    }
  }

  /// One chat completion; returns the assistant text.
  Future<String> chat({
    required String model,
    required List<Map<String, String>> messages,
    int maxTokens = 1200,
    double temperature = 0,
  }) async {
    if (baseUrl.isEmpty) throw LlmEndpointException('Enter the LLM URL first.');
    if (model.trim().isEmpty) throw LlmEndpointException('Choose a model first.');
    try {
      final r = await _dio.post<dynamic>('$baseUrl/chat/completions',
          data: {
            'model': model.trim(),
            'messages': messages,
            'max_tokens': maxTokens,
            'temperature': temperature,
          },
          options: _options);
      if (r.statusCode != 200) throw _problem(r, what: 'The test call');
      final choices = (r.data is Map ? r.data['choices'] : null) as List?;
      final content = choices == null || choices.isEmpty ? null : choices.first['message']?['content'];
      if (content == null || content.toString().trim().isEmpty) {
        throw LlmEndpointException('The model answered with nothing. Pick a different model.');
      }
      return content.toString().trim();
    } on DioException catch (e) {
      throw _network(e, 'The test call');
    }
  }

  /// Round-trips a tiny prompt; returns a short human summary on success.
  Future<String> test({required String model}) async {
    final started = DateTime.now();
    final reply = await chat(
      model: model,
      messages: const [
        {'role': 'user', 'content': 'Reply with the single word: ready'},
      ],
      maxTokens: 96,
    );
    final ms = DateTime.now().difference(started).inMilliseconds;
    final shown = reply.length > 40 ? '${reply.substring(0, 40)}…' : reply;
    return 'Connected. $model answered "$shown" in ${(ms / 1000).toStringAsFixed(1)} s.';
  }
}
