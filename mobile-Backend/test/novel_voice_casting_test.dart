import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/background/conversion_request.dart';
import 'package:mobile_backend_pipeline/src/novel/novel_analyzer.dart';
import 'package:mobile_backend_pipeline/src/models/raw_page.dart';
import 'package:mobile_backend_pipeline/src/tts/kokoro_tts_engine.dart';

void main() {
  NovelBookPlan plan(String text, {Map<String, String> overrides = const {}}) =>
    NovelBookPlan.analyze([RawPage(pageIdx: 0, text: text)], voiceOverrides: overrides);
  const tags = ' “Ready,” Alice said. “Go,” Bob replied.';
  test('book evidence selects configured male and female presets', () {
    final p = plan('Alice smiled as she waved. Bob nodded as he left.$tags');
    expect(p.characters.map((c) => c.voiceGender), ['female', 'male']);
    expect(resolveKokoroCharacterVoice(p.characters[0], narrator: 'Bella', male: 'Michael', female: 'Nicole'), 'Nicole');
    expect(resolveKokoroCharacterVoice(p.characters[1], narrator: 'Bella', male: 'Michael', female: 'Nicole'), 'Michael');
  });
  test('name alone, quoted pronouns and unrelated reported speech cannot cast', () {
    final p = plan('Alice said that he left. Bob heard that she left.$tags');
    expect(p.characters.every((c) => c.voiceGender == 'unknown'), isTrue);
    expect(resolveKokoroCharacterVoice(p.characters[0], narrator: 'Bella', male: 'Adam', female: 'Sarah'), 'Bella');
  });
  test('conflicting evidence stays unknown and override has priority', () {
    final p = plan('Alice smiled as she waved. Alice nodded as he left.$tags', overrides: {'Alice':'Michael'});
    expect(p.characters.first.voiceGender, 'unknown');
    expect(p.characters.first.genderEvidence, hasLength(2));
    expect(resolveKokoroCharacterVoice(p.characters.first, narrator: 'Bella', male: 'Adam', female: 'Sarah'), 'Michael');
  });
  test('roles are evidence and voice settings survive background serialization', () {
    final p = plan('Alice was a woman. Bob was a man.$tags');
    expect(p.characters.map((c) => c.voiceGender), ['female', 'male']);
    const request = ConversionRequest(pdfPath: 'story.pdf', booksRootDir: 'books', modelsDir: 'models', llmBaseUrl: '', llmApiKey: '', llmModel: '', maleVoice: 'Michael', femaleVoice: 'Nicole', characterVoices: {'Alice':'Sarah'});
    final restored = ConversionRequest.fromJson(request.toJson());
    expect(restored.maleVoice, 'Michael');
    expect(restored.femaleVoice, 'Nicole');
    expect(restored.characterVoices, {'Alice':'Sarah'});
  });
}
