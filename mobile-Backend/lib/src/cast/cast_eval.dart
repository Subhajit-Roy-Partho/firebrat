/// Evaluation of on-device LLMs on the real casting task, against the
/// reference set `test/fixtures/cast_eval_sample.json` (labels made by
/// Qwen3.5-9B on the server, NOT human-verified: scores are only meaningful
/// relative to each other).
///
/// Pure Dart: the model is a [CastGenerate] callback, so the same code scores a
/// fake in unit tests and a GGUF model on the phone (see the integration test
/// `llm_cast_eval_test.dart` in the app). Roster quality and attribution
/// quality are measured separately: attribution is given the REFERENCE roster
/// so a weak roster does not hide a good attributor.
library;

import 'dart:convert';

import '../models/model_tier.dart';
import '../models/raw_page.dart';
import 'cast_engine.dart';
import 'cast_json.dart';
import 'cast_models.dart';
import 'cast_prompts.dart';

class EvalLabel {
  final int segIdx; // the fixture's quote_index == segment idx of the passage
  final String speaker; // 'NARRATOR' or a character name
  final String emotion;
  const EvalLabel(this.segIdx, this.speaker, this.emotion);
}

class EvalCase {
  final String book;
  final int page;
  final String text;
  final List<EvalLabel> labels;
  const EvalCase(this.book, this.page, this.text, this.labels);
}

class EvalBook {
  final String key;
  final String title;
  final List<CastCharacter> roster;
  final List<EvalCase> cases;
  const EvalBook(this.key, this.title, this.roster, this.cases);
}

List<EvalBook> parseCastEvalFixture(String jsonText) {
  final root = jsonDecode(jsonText) as Map;
  final books = <EvalBook>[];
  for (final e in (root['books'] as Map).entries) {
    final b = e.value as Map;
    final roster = <CastCharacter>[];
    for (final r in (b['roster'] as List)) {
      final c = sanitizeCharacter(r);
      if (c == null) continue;
      roster.add(c);
    }
    // de-duplicate fixture entries such as "The Gryphon" / "Gryphon"
    final merged = assignIds(mergeCharacters([], roster));
    books.add(EvalBook(e.key as String, b['title'].toString(), merged, [
      for (final c in (b['cases'] as List))
        EvalCase(e.key as String, (c['page'] as num).toInt(), c['text'].toString(), [
          for (final l in (c['labels'] as List))
            EvalLabel((l['quote_index'] as num).toInt(), l['speaker'].toString(), l['emotion'].toString())
        ])
    ]));
  }
  return books;
}

/// Coarse emotion classes (valence/arousal) for a forgiving second score.
const kEmotionGroups = <String, String>{
  'neutral': 'neutral',
  'joy': 'warm', 'tenderness': 'warm', 'awe': 'warm',
  'sadness': 'low-negative', 'disgust': 'low-negative',
  'anger': 'high-arousal', 'fear': 'high-arousal', 'surprise': 'high-arousal', 'suspense': 'high-arousal', 'sarcasm': 'high-arousal',
};

class EvalTotals {
  int quotes = 0, speakerOk = 0, emotionExact = 0, emotionGroup = 0, missing = 0;

  /// Quotes whose reference speaker is a named character (not the narrator),
  /// and how many of those were attributed to that character.
  int named = 0, namedOk = 0;
  Map<String, num> toJson() => {
        'quotes': quotes,
        'speaker_acc': quotes == 0 ? 0 : speakerOk / quotes,
        'named_quotes': named,
        'named_speaker_acc': named == 0 ? 0 : namedOk / named,
        'emotion_exact': quotes == 0 ? 0 : emotionExact / quotes,
        'emotion_group': quotes == 0 ? 0 : emotionGroup / quotes,
        'not_answered': missing,
      };
}

/// Does predicted [name] denote the same speaker as the fixture's [expected]?
bool sameSpeaker(String expected, String predicted) {
  final e = expected.trim().toLowerCase(), p = predicted.trim().toLowerCase();
  if (e == 'narrator' || e == 'n') return p == 'narrator' || p == 'n' || p.isEmpty;
  if (p == 'narrator') return false;
  final ne = normName(expected), np = normName(predicted);
  if (ne == np) return true;
  final we = ne.split(' ').toSet(), wp = np.split(' ').toSet();
  return we.containsAll(wp) || wp.containsAll(we);
}

/// The reference roster of [book] plus every speaker the labels of [c] name
/// that the book roster lacks (the fixture roster is incomplete: minor speakers
/// such as the Dodo or the Duck only appear in the labels). This is the roster a
/// perfect roster pass would hand to attribution.
List<CastCharacter> caseRoster(EvalBook book, EvalCase c) {
  final out = [...book.roster];
  for (final l in c.labels) {
    if (l.speaker.trim().toLowerCase() == 'narrator') continue;
    if (out.any((r) => sameSpeaker(l.speaker, r.name))) continue;
    out.add(CastCharacter(id: 'extra_${out.length + 1}', name: l.speaker, importance: 1));
  }
  return out;
}

/// Scores one case: casts [c] with the reference [roster] and compares.
Future<EvalTotals> scoreAttributionCase(EvalCase c, List<CastCharacter> roster, CastEngine engine) async {
  final result = await engine.cast([RawPage(pageIdx: c.page, text: c.text)], fixedRoster: roster);
  final nameById = {for (final ch in result.characters) ch.id: ch.name};
  final byIdx = {for (final u in result.utterances) u.idx: u};
  final totals = EvalTotals();
  for (final l in c.labels) {
    totals.quotes++;
    final u = byIdx[l.segIdx];
    if (u == null) {
      totals.missing++;
      continue;
    }
    final predicted = u.speaker == kNarratorId ? 'narrator' : (nameById[u.speaker] ?? 'narrator');
    final named = l.speaker.trim().toLowerCase() != 'narrator';
    if (named) totals.named++;
    if (sameSpeaker(l.speaker, predicted)) {
      totals.speakerOk++;
      if (named) totals.namedOk++;
    }
    if (u.emotion == l.emotion) totals.emotionExact++;
    if (kEmotionGroups[u.emotion] == kEmotionGroups[l.emotion]) totals.emotionGroup++;
  }
  return totals;
}

class RosterScore {
  final bool validJson;
  final int expected;
  final int found;
  final int invented;
  const RosterScore(this.validJson, this.expected, this.found, this.invented);
}

/// Roster pass on one passage: which reference characters that appear in the
/// passage text (by name) did the model list, and how many unknown names did it add.
Future<RosterScore> scoreRosterCase(EvalCase c, List<CastCharacter> reference, CastGenerate generate) async {
  final text = c.text.toLowerCase();
  final present = [
    for (final r in reference)
      if (text.contains(normName(r.name).split(' ').last)) r
  ];
  Map<String, dynamic>? obj;
  try {
    obj = extractJsonObject(await generate(kRosterSystem, buildRosterUser(c.text), maxTokens: 700, label: 'eval roster'));
  } catch (_) {
    return RosterScore(false, present.length, 0, 0);
  }
  final listed = [for (final x in (obj['characters'] as List? ?? const [])) ?sanitizeCharacter(x)];
  var found = 0;
  for (final r in present) {
    if (listed.any((l) => sameSpeaker(r.name, l.name) || l.aliases.any((a) => sameSpeaker(r.name, a)))) found++;
  }
  var invented = 0;
  for (final l in listed) {
    if (!reference.any((r) => sameSpeaker(r.name, l.name) || l.aliases.any((a) => sameSpeaker(r.name, a)))) invented++;
  }
  return RosterScore(true, present.length, found, invented);
}

/// Evenly spaced indices (at most [n]) for sub-sampling passages.
List<int> evenIndices(int total, int n) {
  if (n <= 0) return const [];
  if (total <= n) return [for (var i = 0; i < total; i++) i];
  if (n == 1) return const [0];
  return {for (var i = 0; i < n; i++) (i * (total - 1) / (n - 1)).round()}.toList()..sort();
}

/// The limits used while evaluating (one passage = one or two chunks).
CastLimits evalLimits() => CastLimits.forTier(ModelTier.balanced);

String describeEval(Map<String, Object?> row) => jsonEncode(row);
