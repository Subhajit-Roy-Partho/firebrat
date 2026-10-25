import 'package:mobile_backend_pipeline/src/models/manifest_models.dart';
import 'package:flutter_test/flutter_test.dart';

ManifestSection section(int n) => ManifestSection(
      sectionId: 'sec_$n',
      order: n,
      title: 'Chapter $n',
      audioPath: 'sections/sec_$n/audio.wav',
      segmentsPath: 'sections/sec_$n/segments.json',
      durationMs: 1000 * n,
      figureRefs: const ['fig_1'],
      formulaRefs: const [],
      tableRefs: const [],
      sourcePages: [n],
    );

Manifest manifest({required bool partial}) => Manifest(
      bookId: 'book',
      title: 'Book',
      sourcePdf: 'book.pdf',
      generatedAt: '2026-01-01T00:00:00Z',
      totalDurationMs: 3000,
      sections: [section(1), section(2)],
      figures: const [],
      formulas: const [],
      tables: const [],
      narratorEngine: 'kokoro_onnx',
      partial: partial,
      sectionsPlanned: 10,
    );

void main() {
  test('a partial manifest says how many sections are planned', () {
    final json = manifest(partial: true).toJson();
    expect(json['partial'], true);
    expect(json['sections_planned'], 10);
    expect((json['sections'] as List).length, 2);
  });

  test('a finished manifest keeps its original shape', () {
    final json = manifest(partial: false).toJson();
    expect(json.containsKey('partial'), isFalse);
    expect(json.containsKey('sections_planned'), isFalse);
  });

  test('sections and formulas survive a save and reload, so a conversion can resume', () {
    final saved = section(2).toJson();
    final back = ManifestSection.fromJson(saved);
    expect(back.toJson(), saved);
    const formula = ManifestFormula(
        formulaId: 'f1', latex: 'x^2', imagePath: '', spokenText: 'x squared', visuallyEssential: true, page: 4);
    expect(ManifestFormula.fromJson(formula.toJson()).toJson(), formula.toJson());
  });
}
