import 'dart:convert';
import 'package:dio/dio.dart';
import '../llm/llm_endpoint.dart';
import 'character_traits.dart';

class CharacterResearchResult {
  final Map<String, CharacterTraits> traits;
  final List<String> sources; // Wikipedia article titles used
  final List<String> missing; // characters the LLM could not describe
  final String source;
  final String? skipped; // why nothing was applied, in plain words

  const CharacterResearchResult(this.traits, {this.sources = const [], this.missing = const [], this.skipped, this.source = 'Wikipedia'});

  String? get sourceTitle => sources.isEmpty ? null : sources.join(' + ');

  Map<String, dynamic> toJson() => {
        'status': skipped == null ? 'applied' : 'skipped',
        if (skipped != null) 'reason': skipped,
        'source': source,
        'articles': sources,
        'described': traits.length,
        if (missing.isNotEmpty) 'not_described': missing,
        'characters': {for (final e in traits.entries) e.key: e.value.toJson()},
      };
}

/// Looks the book up on Wikipedia (the novel's article and any "characters"
/// list) and has the user's LLM read the character descriptions, so every
/// named speaker gets an age and temperament and therefore a distinct audio
/// pattern. Characters are researched in batches, each given the paragraphs
/// that actually mention them, so a cast of dozens is covered, not just the
/// first few.
///
/// Privacy: only the book TITLE and the character NAMES (to Wikipedia and to the
/// LLM provider) and the public article text (to the LLM provider) leave the
/// device. None of the book's own text is sent. Any failure is non-fatal: the
/// conversion simply continues without research.
class CharacterResearcher {
  final LlmEndpoint llm;
  final String model;
  final Dio _dio;
  final int batchSize;

  CharacterResearcher({required this.llm, required this.model, Dio? dio, this.batchSize = 10})
      : _dio = dio ?? Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          // Wikipedia asks API clients to identify themselves.
          headers: {'User-Agent': 'Firebrat/1.7 (https://github.com/Subhajit-Roy-Partho/firebrat)'},
        ));

  static const _api = 'https://en.wikipedia.org/w/api.php';
  static const _honorifics = {
    'mr', 'mrs', 'miss', 'ms', 'dr', 'lady', 'lord', 'sir', 'colonel', 'captain',
    'major', 'professor', 'reverend', 'uncle', 'aunt', 'the', 'of', 'de', 'van', 'von',
  };

  static const _system = 'You help cast an audiobook. Using ONLY the reference text, describe each listed '
      'character. A listed name may be a nickname, a title or a surname (for example "Lizzy" is '
      'Elizabeth Bennet, and "Mr. Darcy" is Fitzwilliam Darcy): match it to the right person in the text. '
      'Answer with one JSON object mapping each name exactly as given to '
      '{"gender":"male|female|unknown","age":"child|young|adult|elder|unknown",'
      '"temperament":"calm|cheerful|stern|gruff|gentle|energetic|mysterious|unknown"}. '
      'Use "unknown" whenever the text does not say. No commentary, JSON only.';

  Future<CharacterResearchResult> research({
    required String title,
    required List<String> names,
    void Function(String status)? onProgress,
  }) async {
    if (names.isEmpty) return const CharacterResearchResult({}, skipped: 'no named speakers were found');
    try {
      onProgress?.call('looking up "$title" on Wikipedia');
      final articles = await _findArticles(title, names);
      if (articles.isEmpty) {
        return const CharacterResearchResult({}, skipped: 'no matching Wikipedia article mentions these characters');
      }
      final out = <String, CharacterTraits>{};
      LlmEndpointException? lastError;
      final batches = [for (var i = 0; i < names.length; i += batchSize) names.sublist(i, i + batchSize > names.length ? names.length : i + batchSize)];
      for (var b = 0; b < batches.length; b++) {
        onProgress?.call('describing characters ${b * batchSize + 1}-${b * batchSize + batches[b].length} of ${names.length}');
        final context = contextFor(batches[b], articles);
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final reply = await llm.chat(
              model: model,
              maxTokens: 3000,
              messages: [
                {'role': 'system', 'content': attempt == 0 ? _system : '$_system Reply with the JSON object and nothing else.'},
                {'role': 'user', 'content': 'Characters: ${batches[b].join(', ')}\n\nReference text:\n$context'},
              ],
            );
            final parsed = parseTraitsJson(reply, batches[b]);
            if (parsed.isNotEmpty) {
              out.addAll(parsed);
              break;
            }
          } on LlmEndpointException catch (e) {
            lastError = e;
            break; // the endpoint already retried rate limits; don't hammer it
          }
        }
      }
      final sources = [for (final a in articles) a.title];
      if (out.isEmpty) {
        return CharacterResearchResult({}, sources: sources,
            skipped: lastError?.message ?? 'the model returned no usable character descriptions');
      }
      return CharacterResearchResult(out, sources: sources, missing: [for (final n in names) if (!out.containsKey(n)) n]);
    } on LlmEndpointException catch (e) {
      return CharacterResearchResult({}, skipped: e.message);
    } on DioException {
      return const CharacterResearchResult({}, skipped: 'Wikipedia could not be reached');
    } catch (e) {
      return CharacterResearchResult({}, skipped: 'character research failed: $e');
    }
  }

  /// The paragraphs most useful for [names]: those that mention any of their
  /// name words, from every article, capped to keep each request modest. Falls
  /// back to the start of the best article when no name word matches (aliases).
  static String contextFor(List<String> names, List<({String title, String url, String text})> articles,
      {int maxChars = 9000}) {
    final words = {
      for (final n in names)
        for (final w in n.split(RegExp(r'[\s.\-]+')))
          if (w.length >= 3 && !_honorifics.contains(w.toLowerCase())) w.toLowerCase(),
    };
    // Whole-word matches only: "Ann" must not pull in every "Anne" paragraph.
    final matchers = [for (final w in words) RegExp('\\b${RegExp.escape(w)}\\b', caseSensitive: false)];
    final picked = StringBuffer();
    for (final a in articles) {
      for (final paragraph in a.text.split(RegExp(r'\n+'))) {
        if (paragraph.trim().length > 20 && matchers.any((m) => m.hasMatch(paragraph))) {
          if (picked.length + paragraph.length > maxChars) return picked.toString();
          picked.writeln(paragraph);
        }
      }
    }
    if (picked.isEmpty) {
      final text = articles.first.text;
      return text.substring(0, text.length < 4000 ? text.length : 4000);
    }
    return picked.toString();
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

  Future<List<({String title, String url, String text})>> _findArticles(String title, List<String> names) async {
    final titles = <String>[];
    for (final q in ['"$title" novel', 'characters in "$title"']) {
      final search = await _dio.get<dynamic>(_api, queryParameters: {
        'action': 'query', 'list': 'search', 'format': 'json', 'srlimit': 3, 'srsearch': q,
      });
      for (final hit in ((search.data as Map?)?['query']?['search'] as List?) ?? const []) {
        final t = (hit as Map)['title'].toString();
        if (!titles.contains(t)) titles.add(t);
      }
    }
    final lowerNames = [for (final n in names) n.toLowerCase()];
    final found = <({String title, String url, String text})>[];
    for (final pageTitle in titles.take(5)) {
      final page = await _dio.get<dynamic>(_api, queryParameters: {
        'action': 'query', 'prop': 'extracts', 'explaintext': 1, 'format': 'json', 'titles': pageTitle,
      });
      final pages = ((page.data as Map?)?['query']?['pages'] as Map?)?.values ?? const [];
      final extract = pages.isEmpty ? '' : ((pages.first as Map)['extract'] ?? '').toString();
      if (extract.isEmpty) continue;
      // Guard against an unrelated article: it must mention at least one speaker.
      final lower = extract.toLowerCase();
      final nameWords = {for (final n in lowerNames) ...n.split(RegExp(r'[\s.\-]+')).where((w) => w.length >= 4 && !_honorifics.contains(w))};
      if (!nameWords.any(lower.contains)) continue;
      found.add((
        title: pageTitle,
        url: 'https://en.wikipedia.org/wiki/${Uri.encodeComponent(pageTitle.replaceAll(' ', '_'))}',
        text: extract.length > 60000 ? extract.substring(0, 60000) : extract,
      ));
      if (found.length >= 3) break;
    }
    return found;
  }
}
