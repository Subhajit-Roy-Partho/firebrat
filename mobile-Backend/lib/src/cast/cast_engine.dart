/// On-device expressive casting: a Dart port of backend/firebrat_cast/cast.py
/// sized for a phone. Pass 1 builds a character roster from a budget of
/// evenly spaced windows; pass 2 attributes every quote and tags emotion +
/// delivery in small chunks. Both are JSON-validated with a repair retry, cache
/// every LLM answer on disk (an interrupted conversion resumes), and fall back
/// to the deterministic dialogue-tag regex of novel mode, then to the narrator.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/model_tier.dart';
import '../models/raw_page.dart';
import '../novel/novel_analyzer.dart';
import 'cast_json.dart';
import 'cast_models.dart';
import 'cast_prompts.dart';
import 'cast_segmenter.dart';

/// Runs one LLM call. [maxTokens] bounds the answer; implementations must not
/// throw for an empty answer (return '').
typedef CastGenerate = Future<String> Function(String system, String user,
    {required int maxTokens, required String label});

typedef CastProgress = void Function(String status, double fraction);

abstract class CastCacheStore {
  Future<Object?> get(String key);
  Future<void> put(String key, Object value);
}

class MemoryCastCache implements CastCacheStore {
  final Map<String, Object> data = {};
  @override
  Future<Object?> get(String key) async => data[key];
  @override
  Future<void> put(String key, Object value) async => data[key] = value;
}

/// One small JSON file per answer; atomic (write + rename), safe to kill.
class FileCastCache implements CastCacheStore {
  final String dir;
  FileCastCache(this.dir);
  File _file(String key) => File('$dir/$key.json');
  @override
  Future<Object?> get(String key) async {
    try {
      return jsonDecode(await _file(key).readAsString());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> put(String key, Object value) async {
    await Directory(dir).create(recursive: true);
    final tmp = File('${_file(key).path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(_file(key).path);
  }
}

/// Hard limits by device class. Casting is capped so a long novel on a modest
/// phone finishes in reasonable time: beyond the budget, quotes keep the
/// regex/narrator fallback (and the result says so).
class CastLimits {
  final int chunkWords;
  final int maxQuotesPerChunk;
  final int rosterWindows;
  final int windowWords;
  final int windowOverlap;
  final int maxLlmCalls;
  final int maxCharacters;
  const CastLimits({
    required this.chunkWords,
    required this.maxQuotesPerChunk,
    required this.rosterWindows,
    required this.windowWords,
    this.windowOverlap = 150,
    required this.maxLlmCalls,
    this.maxCharacters = 24,
  });

  factory CastLimits.forTier(ModelTier tier) => switch (tier) {
        ModelTier.light => const CastLimits(
            chunkWords: 180, maxQuotesPerChunk: 8, rosterWindows: 4, windowWords: 800, maxLlmCalls: 150, maxCharacters: 12),
        ModelTier.balanced => const CastLimits(
            chunkWords: 260, maxQuotesPerChunk: 12, rosterWindows: 10, windowWords: 1000, maxLlmCalls: 500, maxCharacters: 20),
        ModelTier.powerful => const CastLimits(
            chunkWords: 320, maxQuotesPerChunk: 14, rosterWindows: 20, windowWords: 1100, maxLlmCalls: 1200),
        ModelTier.desktopClass => const CastLimits(
            chunkWords: 400, maxQuotesPerChunk: 16, rosterWindows: 40, windowWords: 1200, maxLlmCalls: 3000),
      };

  /// Expressive casting is only offered from the Balanced class up.
  static bool allowedFor(ModelTier tier) => tier.index >= ModelTier.balanced.index;
}

/// Planned work and an honest time estimate for a book (no LLM involved).
class CastEstimate {
  final int rosterCalls;
  final int attributionCalls;
  final int quotes;
  final double minutes;
  const CastEstimate(this.rosterCalls, this.attributionCalls, this.quotes, this.minutes);
}

/// Estimates casting time from measured throughput: [promptTokensPerSecond]
/// (prefill) and [generationTokensPerSecond] of the chosen model on this phone.
CastEstimate estimateCasting(List<RawPage> pages, CastLimits limits,
    {required double promptTokensPerSecond, required double generationTokensPerSecond}) {
  final segs = segmentPages(pages);
  final windows = _makeWindows(segs, limits.windowWords, limits.windowOverlap).length;
  final rosterCalls = windows < limits.rosterWindows ? windows : limits.rosterWindows;
  final chunks = _makeChunks(segs, limits.chunkWords, limits.maxQuotesPerChunk).where((c) => c.any((s) => s.isQuote));
  final quotes = segs.where((s) => s.isQuote).length;
  var calls = chunks.length;
  if (calls > limits.maxLlmCalls - rosterCalls) calls = limits.maxLlmCalls - rosterCalls;
  const rosterPrompt = 1700, rosterOut = 350, attrPromptBase = 520, perQuotePrompt = 70, perQuoteOut = 18;
  final avgQuotes = chunks.isEmpty ? 0 : quotes / chunks.length;
  final seconds = rosterCalls * (rosterPrompt / promptTokensPerSecond + rosterOut / generationTokensPerSecond) +
      calls * ((attrPromptBase + avgQuotes * perQuotePrompt) / promptTokensPerSecond + (avgQuotes * perQuoteOut + 12) / generationTokensPerSecond);
  return CastEstimate(rosterCalls, calls, quotes, seconds / 60);
}

List<List<CastSeg>> _makeWindows(List<CastSeg> segs, int size, int overlap) {
  final windows = <List<CastSeg>>[];
  var current = <CastSeg>[];
  var total = 0;
  for (final seg in segs) {
    current.add(seg);
    total += wordCount(seg.text).clamp(1, 1 << 30);
    if (total >= size) {
      windows.add(current);
      final keep = <CastSeg>[];
      var kept = 0;
      for (final s in current.reversed) {
        keep.add(s);
        kept += wordCount(s.text).clamp(1, 1 << 30);
        if (kept >= overlap) break;
      }
      current = keep.reversed.toList();
      total = kept;
    }
  }
  if (current.isNotEmpty && (windows.isEmpty || !identical(current, windows.last)) && total > overlap) windows.add(current);
  if (windows.isEmpty && current.isNotEmpty) windows.add(current);
  return windows;
}

List<List<CastSeg>> _makeChunks(List<CastSeg> segs, int target, int maxQuotes) {
  final chunks = <List<CastSeg>>[];
  var current = <CastSeg>[];
  var total = 0, quotes = 0;
  for (final seg in segs) {
    final words = wordCount(seg.text).clamp(1, 1 << 30);
    if (current.isNotEmpty && (total + words > target || (seg.isQuote && quotes >= maxQuotes))) {
      chunks.add(current);
      current = [];
      total = 0;
      quotes = 0;
    }
    current.add(seg);
    total += words;
    if (seg.isQuote) quotes++;
  }
  if (current.isNotEmpty) chunks.add(current);
  return chunks;
}

// --- names ---

const _titleWords = {'mr', 'mrs', 'miss', 'ms', 'dr', 'lady', 'lord', 'sir', 'colonel', 'captain', 'major', 'professor', 'reverend', 'uncle', 'aunt', 'the'};

/// 'Mr. Darcy' -> 'darcy' (lowercase, honorifics and "the" dropped).
String normName(String? name) {
  final words = [
    for (final w in (name ?? '').trim().split(RegExp(r'\s+')))
      if (w.isNotEmpty) w.replaceAll(RegExp(r'^\.+|\.+$'), '').toLowerCase()
  ];
  return words.where((w) => w.isNotEmpty && !_titleWords.contains(w)).join(' ');
}

String _pick(Object? v, List<String> allowed, String fallback) {
  final s = (v ?? '').toString().trim().toLowerCase();
  return allowed.contains(s) ? s : fallback;
}

const _emotionSynonyms = {
  'happy': 'joy', 'happiness': 'joy', 'excited': 'joy', 'joyful': 'joy', 'cheerful': 'joy', 'delight': 'joy',
  'sad': 'sadness', 'sorrow': 'sadness', 'grief': 'sadness', 'melancholy': 'sadness',
  'angry': 'anger', 'furious': 'anger', 'irritated': 'anger', 'annoyed': 'anger', 'rage': 'anger',
  'afraid': 'fear', 'scared': 'fear', 'terrified': 'fear', 'anxious': 'fear', 'worried': 'fear', 'nervous': 'fear',
  'surprised': 'surprise', 'shock': 'surprise', 'astonished': 'surprise', 'amazed': 'surprise',
  'love': 'tenderness', 'gentle': 'tenderness', 'affection': 'tenderness', 'warm': 'tenderness', 'kind': 'tenderness',
  'sarcastic': 'sarcasm', 'ironic': 'sarcasm', 'mocking': 'sarcasm', 'teasing': 'sarcasm',
  'disgusted': 'disgust', 'contempt': 'disgust', 'scorn': 'disgust',
  'wonder': 'awe', 'amazement': 'awe', 'reverence': 'awe',
  'tense': 'suspense', 'mystery': 'suspense', 'ominous': 'suspense', 'urgent': 'suspense',
  'calm': 'neutral', 'none': 'neutral', 'plain': 'neutral', 'normal': 'neutral',
};

String normalizeEmotion(Object? raw) {
  final s = (raw ?? '').toString().trim().toLowerCase();
  if (kCastEmotions.contains(s)) return s;
  return _emotionSynonyms[s] ?? 'neutral';
}

CastCharacter? sanitizeCharacter(Object? raw) {
  if (raw is! Map) return null;
  final name = (raw['name'] ?? '').toString().trim();
  if (name.isEmpty || normName(name).isEmpty) return null;
  return CastCharacter(
    id: '',
    name: name,
    aliases: [
      for (final a in (raw['aliases'] as List? ?? const []))
        if (a.toString().trim().isNotEmpty) a.toString().trim()
    ].take(8).toList(),
    gender: _pick(raw['gender'], kCastGenders, 'unknown'),
    age: _pick(raw['age'], kCastAges, 'adult'),
    temperament: (raw['temperament'] ?? '').toString().trim().substring(0, (raw['temperament'] ?? '').toString().trim().length.clamp(0, 60)),
    accent: _pick(raw['accent'], kCastAccents, 'british'),
    importance: (int.tryParse('${raw['lines'] ?? raw['importance'] ?? 1}') ?? 1).clamp(0, 100000),
  );
}

/// Folds [added] characters into [roster], merging by name or alias.
List<CastCharacter> mergeCharacters(List<CastCharacter> roster, List<CastCharacter> added) {
  final out = [...roster];
  int? find(CastCharacter c) {
    final keys = {normName(c.name), ...c.aliases.map(normName)}..remove('');
    for (var i = 0; i < out.length; i++) {
      final known = {normName(out[i].name), ...out[i].aliases.map(normName)}..remove('');
      if (keys.intersection(known).isNotEmpty) return i;
      // a single-word name matching the last word of a fuller name ("Darcy")
      for (final k in keys) {
        for (final n in known) {
          if (k != n && (n.endsWith(' $k') || k.endsWith(' $n')) && !k.contains(' ') != !n.contains(' ')) return i;
        }
      }
    }
    return null;
  }

  for (final c in added) {
    final i = find(c);
    if (i == null) {
      out.add(c);
      continue;
    }
    final t = out[i];
    final known = {normName(t.name), ...t.aliases.map(normName)};
    final aliases = [...t.aliases];
    for (final a in [c.name, ...c.aliases]) {
      if (!known.contains(normName(a)) && aliases.length < 8) {
        aliases.add(a);
        known.add(normName(a));
      }
    }
    out[i] = t.copyWith(
      aliases: aliases,
      importance: c.importance > t.importance ? c.importance : t.importance,
      gender: t.gender == 'unknown' ? c.gender : null,
      age: t.age == 'adult' ? c.age : null,
      accent: t.accent == 'british' ? c.accent : null,
      temperament: t.temperament.isEmpty ? c.temperament : null,
    );
  }
  return out;
}

/// Stable ids `char_001...`, most important first.
List<CastCharacter> assignIds(List<CastCharacter> characters) {
  final ordered = [...characters]
    ..sort((a, b) => b.importance != a.importance ? b.importance.compareTo(a.importance) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return [
    for (var i = 0; i < ordered.length; i++)
      ordered[i].copyWith(
        id: 'char_${(i + 1).toString().padLeft(3, '0')}',
        description: ordered[i].description.isNotEmpty
            ? ordered[i].description
            : '${ordered[i].age} ${ordered[i].gender == 'unknown' ? '' : '${ordered[i].gender} '}voice'
                '${ordered[i].temperament.isEmpty ? '' : ', ${ordered[i].temperament}'}, ${ordered[i].accent} accent',
      )
  ];
}

String _hash(String s) => sha1.convert(utf8.encode(s)).toString().substring(0, 16);

typedef AttributionRow = ({int n, String speaker, String emotion, String delivery});

/// Validates LLM attribution rows. Lenient: returns whatever valid rows exist
/// (speaker ids may be 'c1', 'char_001', a name or 'n'); out-of-range numbers
/// and duplicates are dropped. Null when nothing usable was found.
/// [shortIds] is the roster the 'c1..cN' ids of the prompt refer to (the
/// per-chunk subset); names and `char_NNN` ids always resolve against [roster].
/// With [loose] a regex salvages rows from replies that are not valid JSON
/// (small models often break quoting).
List<AttributionRow>? parseAttributionRows(String? reply, int quoteCount, List<CastCharacter> roster,
    {List<CastCharacter>? shortIds, bool loose = true}) {
  final shortRoster = shortIds ?? roster;
  final byShort = {for (var i = 0; i < shortRoster.length; i++) 'c${i + 1}': shortRoster[i].id};
  final byId = {for (final c in roster) c.id: c.id};
  final byName = <String, String>{};
  for (final c in roster) {
    byName.putIfAbsent(normName(c.name), () => c.id);
    for (final a in c.aliases) {
      byName.putIfAbsent(normName(a), () => c.id);
    }
  }
  String resolve(Object? raw) {
    final s = (raw ?? '').toString().trim();
    final low = s.toLowerCase();
    if (low == 'n' || low == 'narrator' || low.isEmpty) return kNarratorId;
    return byShort[low] ?? byId[low] ?? byName[normName(s)] ?? kNarratorId;
  }

  List? rows;
  try {
    Object? value = extractJsonValue(reply);
    if (value is Map) {
      value = value['utterances'] ?? value['quotes'] ?? value['rows'];
    }
    if (value is List) {
      // [[[0,"c1",...],[1,...]]]: one level too many
      while (value is List && value.length == 1 && value.first is List && (value.first as List).isNotEmpty && (value.first as List).first is List) {
        value = value.first;
      }
      rows = value as List;
    }
  } on FormatException {
    rows = null;
  }
  final seen = <int>{};
  final out = <AttributionRow>[];
  void add(int? n, Object? speaker, Object? emotion, Object? delivery) {
    if (n == null || n < 0 || n >= quoteCount || !seen.add(n)) return;
    final d = (delivery ?? '').toString().trim();
    out.add((n: n, speaker: resolve(speaker), emotion: normalizeEmotion(emotion), delivery: d.length > 60 ? d.substring(0, 60) : d));
  }

  if (rows != null) {
    for (final row in rows) {
      if (row is List && row.length >= 2) {
        final n = row[0] is num ? (row[0] as num).toInt() : int.tryParse('${row[0]}'.replaceAll(RegExp(r'[^0-9]'), ''));
        add(n, row[1], row.length > 2 ? row[2] : 'neutral', row.length > 3 ? row[3] : '');
      } else if (row is Map) {
        final raw = row['n'] ?? row['number'] ?? row['quote'] ?? row['id'];
        add(raw is num ? raw.toInt() : int.tryParse('$raw'), row['speaker'] ?? row['character'], row['emotion'], row['delivery']);
      }
    }
  }
  if (out.isEmpty && loose && (reply ?? '').isNotEmpty) {
    final text = stripThinking(reply!);
    // [3,"c2","anger","muttered"]  /  [4,"c2","sadness,""]  /  3|c2|anger|muttered
    final re = RegExp(
        r'[\[\(]?\s*(\d{1,3})\s*[,|:]\s*["' "'" r']?([A-Za-z_][\w .' "'" r'-]{0,30}?)["' "'" r']?\s*[,|]\s*["' "'" r']?([A-Za-z]{3,12})[,"' "'" r']*\s*(?:[,|]\s*["' "'" r']?([^"' "'" r'\]\)\n]{0,60}))?');
    for (final m in re.allMatches(text)) {
      add(int.tryParse(m.group(1)!), m.group(2), m.group(3), m.group(4));
    }
  }
  return out.isEmpty ? null : out;
}

/// Characters worth listing for one chunk: named (or aliased) in its text, the
/// recent speakers, and the two lead characters; at most [max]. Order follows
/// the roster (importance), so prompt ids stay stable for the chunk.
List<CastCharacter> rosterForChunk(List<CastCharacter> roster, String chunkText, List<String> recentIds, {int max = 10, int minCount = 4}) {
  final text = chunkText.toLowerCase();
  bool mentioned(CastCharacter c) {
    for (final name in [c.name, ...c.aliases]) {
      final key = normName(name);
      if (key.isEmpty) continue;
      // match the most specific word of the name ("Elizabeth Bennet" -> "bennet" or "elizabeth")
      for (final w in key.split(' ')) {
        if (w.length >= 3 && RegExp('\\b${RegExp.escape(w)}').hasMatch(text)) return true;
      }
    }
    return false;
  }

  final picked = <CastCharacter>[];
  for (var i = 0; i < roster.length; i++) {
    final c = roster[i];
    if (mentioned(c) || recentIds.contains(c.id) || i < 2) picked.add(c);
  }
  // a very short passage may name nobody: pad with the next most important characters
  for (var i = 0; i < roster.length && picked.length < minCount; i++) {
    if (!picked.contains(roster[i])) picked.add(roster[i]);
  }
  picked.sort((a, b) => roster.indexOf(a).compareTo(roster.indexOf(b)));
  return picked.length <= max ? picked : picked.take(max).toList();
}

/// The casting engine. Inject [generate] (llama.cpp on a phone, a fake in tests).
class CastEngine {
  final CastGenerate generate;
  final CastCacheStore cache;
  final CastLimits limits;
  final String modelId;
  final CastProgress? onProgress;

  int _calls = 0;
  int get llmCalls => _calls;
  final List<String> notes = [];

  /// JSON health, for model evaluation: replies that parsed on the first try vs
  /// all first attempts (roster + attribution).
  int firstTryOk = 0;
  int firstTryTotal = 0;

  CastEngine({required this.generate, required this.cache, required this.limits, required this.modelId, this.onProgress});

  int get _budgetLeft => limits.maxLlmCalls - _calls;

  Future<String?> _ask(String system, String user, int maxTokens, String label) async {
    if (_budgetLeft <= 0) return null;
    _calls++;
    try {
      return await generate(system, user, maxTokens: maxTokens, label: label);
    } catch (e) {
      notes.add('$label failed: ${'$e'.split('\n').first}');
      return null;
    }
  }

  /// [fixedRoster] skips the roster pass (used to evaluate attribution alone).
  Future<CastResult> cast(List<RawPage> pages, {List<CastCharacter>? fixedRoster}) async {
    final segs = segmentPages(pages);
    final quoteSegs = segs.where((s) => s.isQuote).toList();
    // --- Pass 1: roster ---
    onProgress?.call('finding the characters', 0.0);
    var narratorAccent = 'british';
    var roster = <CastCharacter>[];
    final windows = fixedRoster != null ? <List<CastSeg>>[] : _makeWindows(segs, limits.windowWords, limits.windowOverlap);
    final picked = _evenlySpaced(windows.length, limits.rosterWindows);
    if (windows.length > picked.length) {
      notes.add('roster built from ${picked.length} of ${windows.length} passages (limit for this phone)');
    }
    for (var k = 0; k < picked.length; k++) {
      final w = windows[picked[k]];
      final text = w.map((s) => s.text).join();
      final key = 'roster_${picked[k].toString().padLeft(4, '0')}_${_hash('$kCastPromptVersion|$modelId|$text')}';
      Object? obj = await cache.get(key);
      if (obj == null) {
        final user = buildRosterUser(text);
        var reply = await _ask(kRosterSystem, user, 700, 'characters ${k + 1}/${picked.length}');
        Map<String, dynamic>? parsed;
        if (reply != null) {
          firstTryTotal++;
          try {
            parsed = extractJsonObject(reply);
            firstTryOk++;
          } on FormatException {
            final retry = await _ask(kRosterSystem,
                '$user\nYour previous reply was not valid JSON. Reply with exactly one JSON object.', 700, 'characters ${k + 1}/${picked.length} (retry)');
            if (retry != null) {
              try {
                parsed = extractJsonObject(retry);
              } on FormatException {
                parsed = null;
              }
            }
          }
        }
        if (parsed != null) {
          obj = parsed;
          await cache.put(key, parsed);
        }
      }
      if (obj is Map) {
        final n = obj['narrator'];
        if (n is Map && k == 0) narratorAccent = _pick(n['accent'], kCastAccents, 'british');
        roster = mergeCharacters(roster, [
          for (final c in (obj['characters'] as List? ?? const [])) ?sanitizeCharacter(c)
        ]);
      }
      onProgress?.call('finding the characters (${k + 1}/${picked.length})', 0.15 * (k + 1) / picked.length);
    }
    // Deterministic evidence: speakers named by dialogue tags join the roster.
    if (fixedRoster != null) {
      roster = fixedRoster;
    } else {
      final regexPlan = NovelBookPlan.analyze(pages);
      final regexChars = [
        for (final c in regexPlan.characters)
          CastCharacter(id: '', name: c.name, gender: c.voiceGender, importance: c.lines)
      ];
      if (roster.isEmpty) {
        notes.add('the language model produced no usable roster; using named dialogue tags only');
      }
      roster = mergeCharacters(roster, regexChars);
      roster = assignIds(roster);
    }
    if (roster.length > limits.maxCharacters) {
      notes.add('${roster.length - limits.maxCharacters} minor characters share the narrator voice (limit ${limits.maxCharacters})');
      roster = roster.take(limits.maxCharacters).toList();
    }
    // --- Pass 2: attribution + emotion ---
    final nameToId = <String, String>{};
    for (final c in roster) {
      nameToId.putIfAbsent(normName(c.name), () => c.id);
      for (final a in c.aliases) {
        nameToId.putIfAbsent(normName(a), () => c.id);
      }
    }
    final pageText = {for (final p in pages) p.pageIdx: p.text};
    final chunks = _makeChunks(segs, limits.chunkWords, limits.maxQuotesPerChunk);
    // Regex baseline for every quote (also the fallback).
    final regexDecision = <(int, int), String>{};
    final cursors = <int, int>{};
    for (final q in quoteSegs) {
      final text = pageText[q.page] ?? '';
      final pos = text.indexOf(q.text, cursors[q.page] ?? 0);
      var speaker = kNarratorId;
      if (pos >= 0) {
        cursors[q.page] = pos + q.text.length;
        final m = RegExp(RegExp.escape(q.text)).allMatches(text, pos).firstOrNull;
        final name = m == null ? null : NovelBookPlan.taggedSpeaker(text, m);
        if (name != null) speaker = nameToId[normName(name)] ?? kNarratorId;
      }
      regexDecision[(q.page, q.idx)] = speaker;
    }
    // Which chunks get the LLM when the budget is short: those with the most
    // untagged quotes first.
    final quoteChunks = [for (var i = 0; i < chunks.length; i++) if (chunks[i].any((s) => s.isQuote)) i];
    var allowed = quoteChunks.toSet();
    final budget = _budgetLeft;
    if (quoteChunks.length > budget) {
      final ranked = [...quoteChunks]..sort((a, b) {
          int untagged(int i) => chunks[i].where((s) => s.isQuote && regexDecision[(s.page, s.idx)] == kNarratorId).length;
          final d = untagged(b).compareTo(untagged(a));
          return d != 0 ? d : a.compareTo(b);
        });
      allowed = ranked.take(budget < 0 ? 0 : budget).toSet();
      notes.add('attributed ${allowed.length} of ${quoteChunks.length} dialogue passages with the language model (limit for this phone); '
          'the rest use dialogue tags only');
    }
    final result = <(int, int), ({String speaker, String emotion, String delivery})>{};
    var byLlm = 0, byRegex = 0;
    final recent = <String>[];
    final sig = roster.map((c) => c.id).join(',');
    var done = 0;
    for (var ci = 0; ci < chunks.length; ci++) {
      final chunk = chunks[ci];
      final items = _quoteItems(chunk);
      if (items.isEmpty) continue;
      done++;
      onProgress?.call('assigning voices to dialogue ($done/${quoteChunks.length})', 0.15 + 0.85 * done / quoteChunks.length);
      final snap = recent.length > 3 ? recent.sublist(recent.length - 3) : [...recent];
      final key = 'attr_${ci.toString().padLeft(5, '0')}_${_hash('$kCastPromptVersion|$modelId|$sig|${snap.join(',')}|${items.map((i) => i.seg.text).join('\u0001')}')}';
      List<AttributionRow>? rows;
      final cached = await cache.get(key);
      if (cached is List) {
        rows = parseAttributionRows(jsonEncode(cached), items.length, roster);
        if (rows != null && rows.length < items.length) rows = null;
      }
      var fromLlm = rows != null;
      if (rows == null && allowed.contains(ci)) {
        // Only the characters present in this passage (plus the latest speakers
        // and the lead characters) go into the prompt: shorter, and far fewer
        // wrong candidates for a small model to pick.
        final prevText = ci > 0 ? chunks[ci - 1].map((s) => s.text).join() : '';
        final promptRoster = rosterForChunk(roster, '$prevText ${chunk.map((s) => s.text).join()}', snap);
        final recentNames = [for (final id in snap) roster.firstWhere((c) => c.id == id, orElse: () => roster.first).name];
        final user = buildAttributionUser(ci + 1, items, promptRoster, recentNames);
        final maxTok = 60 + 24 * items.length;
        final reply = await _ask(kAttributionSystem, user, maxTok, 'dialogue $done/${quoteChunks.length}');
        final strict = reply == null ? null : parseAttributionRows(reply, items.length, roster, shortIds: promptRoster, loose: false);
        var got = strict ?? (reply == null ? null : parseAttributionRows(reply, items.length, roster, shortIds: promptRoster));
        if (reply != null) {
          firstTryTotal++;
          if (strict != null && strict.length == items.length) firstTryOk++;
        }
        if (reply != null && (got == null || got.length < items.length)) {
          final have = {for (final r in got ?? const <AttributionRow>[]) r.n};
          final missing = [for (var i = 0; i < items.length; i++) if (!have.contains(i)) i];
          final retry = await _ask(kAttributionSystem,
              buildAttributionUser(ci + 1, items, promptRoster, recentNames, only: missing) + attributionRepairSuffix(missing), maxTok,
              'dialogue $done/${quoteChunks.length} (retry)');
          final more = retry == null ? null : parseAttributionRows(retry, items.length, roster, shortIds: promptRoster);
          if (more != null) {
            final merged = {for (final r in got ?? const <AttributionRow>[]) r.n: r};
            for (final r in more) {
              merged.putIfAbsent(r.n, () => r);
            }
            got = merged.values.toList();
          }
        }
        rows = got;
        fromLlm = rows != null && rows.isNotEmpty;
        if (rows != null && rows.length == items.length) {
          await cache.put(key, [for (final r in rows) [r.n, r.speaker, r.emotion, r.delivery]]);
        }
      }
      final decided = {for (final r in rows ?? const <AttributionRow>[]) r.n: r};
      for (final it in items) {
        final r = decided[it.number];
        final k = (it.seg.page, it.seg.idx);
        if (r != null) {
          result[k] = (speaker: r.speaker, emotion: r.emotion, delivery: r.delivery);
          byLlm++;
        } else {
          result[k] = (speaker: regexDecision[k] ?? kNarratorId, emotion: 'neutral', delivery: '');
          byRegex++;
        }
      }
      if (fromLlm || result.isNotEmpty) {
        final spoken = [for (final it in items) result[(it.seg.page, it.seg.idx)]!.speaker].where((s) => s != kNarratorId);
        recent.addAll(spoken);
      }
    }
    final utterances = [
      for (final q in quoteSegs)
        if (result[(q.page, q.idx)] != null)
          CastUtterance(q.page, q.idx, result[(q.page, q.idx)]!.speaker, result[(q.page, q.idx)]!.emotion, result[(q.page, q.idx)]!.delivery)
    ];
    // Page mood: the most frequent non-neutral emotion of the page's quotes.
    final tally = <int, Map<String, int>>{};
    for (final u in utterances) {
      if (u.emotion == 'neutral') continue;
      final m = tally.putIfAbsent(u.page, () => {});
      m[u.emotion] = (m[u.emotion] ?? 0) + 1;
    }
    final mood = <int, ({String emotion, String delivery})>{};
    for (final e in tally.entries) {
      final best = e.value.entries.reduce((a, b) => b.value > a.value ? b : a);
      mood[e.key] = (emotion: best.key, delivery: '');
    }
    return CastResult(
      narrator: CastNarrator(description: 'Warm mature storyteller, steady unhurried pace', accent: narratorAccent),
      characters: roster,
      utterances: utterances,
      pageMood: mood,
      llmModel: modelId,
      quotesTotal: quoteSegs.length,
      quotesByLlm: byLlm,
      quotesByRegex: byRegex,
      llmCalls: _calls,
      notes: List.of(notes),
    );
  }

  static List<int> _evenlySpaced(int total, int want) {
    if (total <= want) return [for (var i = 0; i < total; i++) i];
    if (want <= 1) return [0];
    return {for (var i = 0; i < want; i++) (i * (total - 1) / (want - 1)).round()}.toList()..sort();
  }

  List<QuoteItem> _quoteItems(List<CastSeg> chunk) {
    final items = <QuoteItem>[];
    for (var i = 0; i < chunk.length; i++) {
      final seg = chunk[i];
      if (!seg.isQuote) continue;
      final before = StringBuffer();
      for (var j = i - 1; j >= 0 && before.length < 200; j--) {
        before.write(chunk[j].text.split('').reversed.join());
      }
      final after = StringBuffer();
      for (var j = i + 1; j < chunk.length && after.length < 200; j++) {
        after.write(chunk[j].text);
      }
      final b = before.toString().split('').reversed.join();
      items.add(QuoteItem(items.length, seg,
          b.length > 200 ? b.substring(b.length - 200) : b, after.length > 200 ? after.toString().substring(0, 200) : after.toString()));
    }
    return items;
  }
}
