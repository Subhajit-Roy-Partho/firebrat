import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/compilation/prose_fidelity.dart';
import 'package:mobile_backend_pipeline/src/models/compiled_models.dart';
import 'package:mobile_backend_pipeline/src/models/raw_page.dart';

CompiledSection section(
  String text, {
  List<int> pages = const [0],
  SegmentKind type = SegmentKind.prose,
}) => CompiledSection(
  title: 'Story',
  sourcePages: pages,
  segments: [CompiledSegment(type: type, text: text)],
);
void main() {
  test('wrong pronouns and summaries fall back to exact source wording', () {
    for (final text in [
      'Her father had an accident there.',
      'The speaker tells the child to leave.',
    ]) {
      final source = 'Your father had an accident there. Now run along.\n1';
      final r = preserveOrdinaryProse(
        [section(text)],
        [RawPage(pageIdx: 0, text: source)],
      );
      expect(r.sourceFallbackPages, [0]);
      expect(
        r.sections.single.segments.single.text,
        'Your father had an accident there. Now run along.',
      );
    }
  });
  test('preserves faithful wording, numbers and model section structure', () {
    final s = section('Four rabbits lived in a tree.');
    final r = preserveOrdinaryProse(
      [s],
      [RawPage(pageIdx: 0, text: 'Four rabbits lived in a tree.\n1')],
    );
    expect(r.sections.single, same(s));
    expect(r.sourceFallbackPages, isEmpty);
    final changed = preserveOrdinaryProse(
      [section('It costs 20 dollars.')],
      [RawPage(pageIdx: 0, text: 'It costs 12 dollars.')],
    );
    expect(changed.sections.single.segments.single.text, contains('12'));
  });
  test('does not guess math semantics or multi-page alignment', () {
    final s = section(
      'The period equals one over frequency.',
      type: SegmentKind.formulaCallout,
    );
    expect(
      preserveOrdinaryProse(
        [s],
        [RawPage(pageIdx: 0, text: 'T = 1/f')],
      ).sections.single,
      same(s),
    );
    final multi = section('Summary', pages: [0, 1]);
    expect(
      preserveOrdinaryProse(
        [multi],
        [RawPage(pageIdx: 0, text: 'Original words')],
      ).sections.single,
      same(multi),
    );
  });
  test(
    'a page split into several model sections is not duplicated on fallback',
    () {
      final r = preserveOrdinaryProse(
        [section('Short.'), section('Summary.')],
        [RawPage(pageIdx: 0, text: 'Original complete page.')],
      );
      expect(r.sections, hasLength(1));
      expect(r.sections.single.segments.single.text, 'Original complete page.');
    },
  );
  test('non-English text is compared rather than discarded from the check', () {
    final r = preserveOrdinaryProse(
      [section('小兔子')],
      [RawPage(pageIdx: 0, text: '四只小兔子')],
    );
    expect(r.sourceFallbackPages, [0]);
    expect(r.sections.single.segments.single.text, '四只小兔子');
  });
}
