import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/util/ids.dart';

void main() {
  group('sanitizeBookId', () {
    test('strips extension and lowercases', () {
      expect(sanitizeBookId('My Book.pdf'), 'my-book');
    });
    test('collapses illegal characters to a single dash, but keeps underscores (matches backend regex)', () {
      expect(sanitizeBookId('a!!!b___c.pdf'), 'a-b___c');
    });
    test('falls back to "book" if nothing survives', () {
      expect(sanitizeBookId('!!!.pdf'), 'book');
    });
  });

  test('id minting matches the 4-digit / 3-digit conventions', () {
    expect(makeFigureId(1), 'fig_0001');
    expect(makeFormulaId(42), 'formula_0042');
    expect(makeTableId(7), 'tbl_0007');
    expect(makeSectionId(3), 'sec_0003');
    expect(makeSegmentId('sec_0003', 0), 'sec_0003_seg_001');
    expect(makeSegmentId('sec_0003', 11), 'sec_0003_seg_012');
  });

  test('validRefPattern accepts real ids and rejects hallucinated ones', () {
    expect(validRefPattern.hasMatch('fig_0001'), isTrue);
    expect(validRefPattern.hasMatch('formula_0042'), isTrue);
    expect(validRefPattern.hasMatch('tbl_0007'), isTrue);
    expect(validRefPattern.hasMatch('fig_1.15'), isFalse);
    expect(validRefPattern.hasMatch('figure_0001'), isFalse);
  });
}
