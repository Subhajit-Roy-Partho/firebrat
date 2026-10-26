import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/models/raw_page.dart';
import 'package:mobile_backend_pipeline/src/novel/local_character_research.dart';
import 'package:mobile_backend_pipeline/src/novel/novel_analyzer.dart';

void main() {
  test('local evidence rejects invented quotations', () async {
    final researcher = LocalCharacterResearcher(generate: (system, prompt) async {
      final name = (jsonDecode(prompt)['characters'] as List).single;
      return jsonEncode({name: {'gender': name == 'Alice' ? 'female' : 'male',
        'gender_evidence': name == 'Alice' ? 'Alice was a woman.' : 'Bob was a brave man.'}});
    });
    final result = await researcher.research(pages: [const RawPage(pageIdx: 0, text: 'Alice was a woman. Bob was a man.')], names: ['Alice', 'Bob']);
    expect(result.traits['Alice']?.gender, 'female');
    expect(result.traits.containsKey('Bob'), false);
  });
  test('standalone honorific is not a character', () {
    final p = NovelBookPlan.analyze([const RawPage(pageIdx: 0, text: '“Hello,” said Mr.\nBennet.')]);
    expect(p.characters.any((c) => c.name == 'Mr'), false);
  });
  test('missing evidence does not invent traits', () {
    expect(LocalCharacterResearcher.parseGroundedTraits('{"Alice":{"gender":"female"}}', ['Alice'], 'Alice arrived.'), isEmpty);
  });
}
