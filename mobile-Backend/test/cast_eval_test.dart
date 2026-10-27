import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_engine.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_eval.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_models.dart';
import 'package:mobile_backend_pipeline/src/cast/cast_segmenter.dart';
import 'package:mobile_backend_pipeline/src/models/model_tier.dart';

void main() {
  final books = parseCastEvalFixture(File('test/fixtures/cast_eval_sample.json').readAsStringSync());

  test('fixture: 2 books, 28 passages, 292 labelled quotes, labels line up with the segmenter', () {
    expect(books.length, 2);
    final cases = [for (final b in books) ...b.cases];
    expect(cases.length, 28);
    expect(cases.fold<int>(0, (a, c) => a + c.labels.length), 292);
    for (final c in cases) {
      final segs = segmentPageText(c.page, c.text);
      for (final l in c.labels) {
        final seg = segs.firstWhere((s) => s.idx == l.segIdx, orElse: () => const CastSeg(0, -1, false, ''));
        expect(seg.isQuote, isTrue, reason: 'page ${c.page} label idx ${l.segIdx}');
      }
    }
    expect(kCastEmotions, containsAll({for (final c in books.first.cases) for (final l in c.labels) l.emotion}));
  });

  test('an oracle that answers with the reference labels scores 100% (harness sanity)', () async {
    // The fake LLM reads the quotes from the prompt and answers with the labels.
    final total = EvalTotals();
    for (final book in books) {
      // Reference labels are model-made and sometimes name a speaker who is not in the passage at all
      // (e.g. "Mouse" on a Rabbit-only page); the oracle can only be exact where every labelled
      // speaker is actually named in the text the prompt shows.
      bool namedInText(EvalCase c) => c.labels.every((l) =>
          l.speaker == 'NARRATOR' || c.text.toLowerCase().contains(normName(l.speaker).split(' ').last));
      for (final c in book.cases.where(namedInText).take(8)) {
        final byText = {for (final s in segmentPageText(c.page, c.text)) s.text: s.idx};
        final labelByIdx = {for (final l in c.labels) l.segIdx: l};
        Future<String> oracle(String system, String user, {required int maxTokens, required String label}) async {
          final roster = RegExp(r'(c\d+)=([^;(]+?)(?: \(|;|$)').allMatches(user.split('\n').firstWhere((l) => l.startsWith('Roster:')));
          final idByName = {for (final m in roster) normName(m.group(2)!.trim()): m.group(1)!};
          final rows = <List<Object>>[];
          for (final m in RegExp(r'^\[(\d+)\] (.*)$', multiLine: true).allMatches(user)) {
            final text = m.group(2)!;
            final entry = byText.entries.firstWhere((e) => e.key.replaceAll(RegExp(r'\s+'), ' ').trim().startsWith(text.replaceAll('...', '').trim()), orElse: () => const MapEntry('', -1));
            final l = labelByIdx[entry.value];
            if (l == null) continue;
            rows.add([int.parse(m.group(1)!), l.speaker == 'NARRATOR' ? 'n' : (idByName[normName(l.speaker)] ?? 'n'), l.emotion, '']);
          }
          return jsonEncode({'utterances': rows});
        }

        final engine = CastEngine(generate: oracle, cache: MemoryCastCache(), limits: evalLimits(), modelId: 'oracle');
        final t = await scoreAttributionCase(c, caseRoster(book, c), engine);
        expect(t.quotes, c.labels.length);
        expect(t.emotionExact, t.quotes, reason: 'emotion, page ${c.page}');
        total.quotes += t.quotes;
        total.speakerOk += t.speakerOk;
      }
    }
    // Speaker: not 100% because of reference-label noise (a labelled speaker the prompt's
    // per-passage roster cannot offer); anything much lower means the harness is broken.
    expect(total.speakerOk / total.quotes, greaterThan(0.85));
  });

  test('a model that always fails scores like the regex fallback, never throws', () async {
    final c = books.first.cases.first;
    final engine = CastEngine(
        generate: (s, u, {required maxTokens, required label}) async => 'no idea',
        cache: MemoryCastCache(), limits: CastLimits.forTier(ModelTier.balanced), modelId: 'broken');
    final t = await scoreAttributionCase(c, books.first.roster, engine);
    expect(t.quotes, c.labels.length);
    expect(t.missing, 0);
    expect(engine.firstTryOk, 0);
  });

  test('speaker matching ignores honorifics and articles, treats narrator specially', () {
    expect(sameSpeaker('The Gryphon', 'Gryphon'), isTrue);
    expect(sameSpeaker('Mr. Darcy', 'darcy'), isTrue);
    expect(sameSpeaker('NARRATOR', 'narrator'), isTrue);
    expect(sameSpeaker('Alice', 'narrator'), isFalse);
    expect(sameSpeaker('Alice', 'Mouse'), isFalse);
  });

  test('coarse emotion groups cover every emotion', () {
    for (final e in kCastEmotions) {
      expect(kEmotionGroups.containsKey(e), isTrue, reason: e);
    }
    expect(evenIndices(28, 14).length, 14);
    expect(evenIndices(28, 1), [0]);
    expect(evenIndices(3, 10), [0, 1, 2]);
  });
}
