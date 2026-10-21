import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/models/raw_page.dart';
import 'package:mobile_backend_pipeline/src/novel/novel_analyzer.dart';

void main() {
  test('full book stable cast', () {
    final plan = NovelBookPlan.analyze([
      const RawPage(pageIdx: 0, text: '“Hello,” said Alice. Bob walked in.'),
      const RawPage(
        pageIdx: 1,
        text: '“Wait!” Bob shouted. “Yes,” Alice replied.',
      ),
    ]);
    expect(plan.scannedPages, 2);
    expect(plan.characters.map((c) => c.name), ['Alice', 'Bob']);
    expect(plan.characters.first.evidencePages, [0, 1]);
    expect(
      plan.split('“Hello,” said Alice.').first.characterId,
      plan.split('“Again,” Alice replied.').first.characterId,
    );
  });
  test('unknown dialogue stays narrator', () {
    final plan = NovelBookPlan.analyze([
      const RawPage(
        pageIdx: 0,
        text: 'Alice arrived. “Hello,” she said. “Wait,” He said. “Who?”',
      ),
    ]);
    expect(plan.characters, isEmpty);
  });
  test('exact text preserved', () {
    const text = 'Alice said, “Hello!”\n“Goodbye,” said Bob. The end.';
    final plan = NovelBookPlan.analyze([const RawPage(pageIdx: 0, text: text)]);
    final split = plan.split(text);
    expect(split.map((s) => s.text).join(), text);
    expect(
      split.where((s) => s.character != null).map((s) => s.character!.name),
      ['Alice', 'Bob'],
    );
  });
  test('offline voice selection filters network voices and is order stable', () {
    const utterance = NovelUtterance('Hello', null);
    final voices = <Map<Object?, Object?>>[
      {'name': 'Cloud', 'locale': 'en-US', 'network_required': true},
      {'name': 'B', 'locale': 'en-US', 'network_required': false},
      {'name': 'A', 'locale': 'en-US', 'network_required': false},
      {'name': 'Unknown', 'locale': 'en-US'},
    ];
    expect(resolveOfflineCharacterVoice(utterance, voices, locale: 'en-US')?['name'], 'A');
    expect(resolveOfflineCharacterVoice(utterance, voices.reversed.toList(), locale: 'en-US')?['name'], 'A');
    expect(resolveOfflineCharacterVoice(utterance, [voices.first], locale: 'en-US'), isNull);
  });

}
