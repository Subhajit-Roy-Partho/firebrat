import 'dart:convert';
import 'package:dio/dio.dart';
import '../llm/llm_endpoint.dart';
import 'character_traits.dart';

class CharacterResearchResult {
  final Map<String, CharacterTraits> traits;
  final String? sourceTitle;
  final String? sourceUrl;
  final String? skipped; // why nothing was applied, in plain words

  const CharacterResearchResult(this.traits, {this.sourceTitle, this.sourceUrl, this.skipped});

  Map<String, dynamic> toJson() => {
        'status': skipped == null ? 'applied' : 'skipped',
        if (skipped != null) 'reason': skipped,
        'source': 'Wikipedia',
        if (sourceTitle != null) 'article': sourceTitle,
        if (sourceUrl != null) 'url': sourceUrl,
        'characters': {for (final e in traits.entries) e.key: e.value.toJson()},
      };
}

/// Looks the book up on Wikipedia and has the user's LLM read the article's
/// character descriptions, so each named speaker gets an age and temperament
/// and therefore a distinct audio pattern.
///
/// Privacy: only the book TITLE and the character NAMES (to Wikipedia and to the
/// LLM provider) and the public article text (to the LLM provider) leave the
/// device. None of the book's own text is sent. Any failure is non-fatal: the
/// conversion simply continues without research.
class CharacterResearcher {
  final LlmEndpoint llm;
  final String model;
  final Dio _dio;

  CharacterResearcher({required this.llm, required this.model, Dio? dio})
      : _dio = dio ?? Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          // Wikipedia asks API clients to identify themselves.
          headers: {'User-Agent': 'Firebrat/1.7 (https://github.com/Subhajit-Roy-Partho/firebrat)'},
        ));

  static const _api = 'https://en.wikipedia.org/w/api.php';

  Future<CharacterResearchResult> research({
    required String title,
    required List<String> names,
  }) async {
    if (names.isEmpty) return const CharacterResearchResult({}, skipped: 'no named speakers were found');
    try {
      final found = await _findArticle(title, names);
      if (found == null) {
        return const CharacterResearchResult({}, skipped: 'no matching Wikipedia article mentions these characters');
      }
      final reply = await llm.chat(
        model: model,
        maxTokens: 1500,
        messages: [
          {
            'role': 'system',
            'content': 'You help cast an audiobook. Using ONLY the reference text, describe each listed '
                'character. Answer with one JSON object mapping each name exactly as given to '
                '{"gender":"male|female|unknown","age":"child|young|adult|elder|unknown",'
                '"temperament":"calm|cheerful|stern|gruff|gentle|energetic|mysterious|unknown"}. '
                'Use "unknown" whenever the text does not say. No commentary, JSON only.',
          },
          {
            'role': 'user',
            'content': 'Characters: ${names.join(', ')}\n\nReference text:\n${found.text}',
          },
        ],
      );
      final parsed = parseTraitsJson(reply, names);
      if (parsed.isEmpty) {
        return CharacterResearchResult({}, sourceTitle: found.title, sourceUrl: found.url,
            skipped: 'the model returned no usable character descriptions');
      }
      return CharacterResearchResult(parsed, sourceTitle: found.title, sourceUrl: found.url);
    } on LlmEndpointException catch (e) {
      return CharacterResearchResult({}, skipped: e.message);
    } on DioException {
      return const CharacterResearchResult({}, skipped: 'Wikipedia could not be reached');
    } catch (e) {
      return CharacterResearchResult({}, skipped: 'character research failed: $e');
    }
  }

  /// Pulls the JSON object out of a reply (models often wrap it in fences or
  /// prose) and keeps only recognised characters and vocabulary.
  static Map<String, CharacterTraits> parseTraitsJson(String reply, List<String> names) {
    final start = reply.indexOf('{');
    final end = reply.lastIndexOf('}');
    if (start < 0 || end <= start) return {};
    Object? decoded;
    try {
      decoded = jsonDecode(reply.substring(start, end + 1));
    } catch (_) {
      return {};
    }
    if (decoded is! Map) return {};
    final byLower = {for (final n in names) n.toLowerCase(): n};
    final out = <String, CharacterTraits>{};
    for (final e in decoded.entries) {
      final name = byLower[e.key.toString().trim().toLowerCase()];
      if (name == null || e.value is! Map) continue;
      final t = CharacterTraits.fromJson(e.value as Map);
      if (t.gender != 'unknown' || t.hasStyle) out[name] = t;
    }
    return out;
  }

  Future<({String title, String url, String text})?> _findArticle(String title, List<String> names) async {
    final search = await _dio.get<dynamic>(_api, queryParameters: {
      'action': 'query', 'list': 'search', 'format': 'json', 'srlimit': 3,
      'srsearch': '"$title" novel',
    });
    final hits = ((search.data as Map?)?['query']?['search'] as List?) ?? const [];
    for (final hit in hits) {
      final pageTitle = (hit as Map)['title'].toString();
      final page = await _dio.get<dynamic>(_api, queryParameters: {
        'action': 'query', 'prop': 'extracts', 'explaintext': 1, 'format': 'json',
        'titles': pageTitle,
      });
      final pages = ((page.data as Map?)?['query']?['pages'] as Map?)?.values ?? const [];
      final extract = pages.isEmpty ? '' : ((pages.first as Map)['extract'] ?? '').toString();
      if (extract.isEmpty) continue;
      // Guard against an unrelated article: it must mention at least one speaker.
      final lower = extract.toLowerCase();
      if (!names.any((n) => lower.contains(n.toLowerCase()))) continue;
      final section = extract.indexOf(RegExp(r'==\s*(Main )?[Cc]haracters?\s*==').stringMatch(extract) ?? '\u0000');
      final from = section >= 0 ? section : 0;
      final text = extract.substring(from, (from + 9000).clamp(0, extract.length));
      return (
        title: pageTitle,
        url: 'https://en.wikipedia.org/wiki/${Uri.encodeComponent(pageTitle.replaceAll(' ', '_'))}',
        text: text,
      );
    }
    return null;
  }
}
