import 'package:mobile_backend_pipeline/src/background/conversion_request.dart';
import 'package:mobile_backend_pipeline/src/extraction/pdf_text_extractor.dart';
import 'package:mobile_backend_pipeline/src/models/raw_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mergeExtractions', () {
    test('offsets page indices per file, preserving order', () {
      final merged = mergeExtractions([
        ExtractionResult(
          pages: const [RawPage(pageIdx: 0, text: 'ch1 p1'), RawPage(pageIdx: 1, text: 'ch1 p2')],
          ocrCandidatePageIndices: const [1],
        ),
        ExtractionResult(
          pages: const [RawPage(pageIdx: 0, text: 'ch2 p1')],
          ocrCandidatePageIndices: const [],
        ),
      ]);
      expect(merged.pages.map((p) => p.pageIdx).toList(), [0, 1, 2]);
      expect(merged.pages.map((p) => p.text).toList(), ['ch1 p1', 'ch1 p2', 'ch2 p1']);
      expect(merged.ocrCandidatePageIndices, [1]);
    });

    test('empty input merges to empty', () {
      final merged = mergeExtractions(const []);
      expect(merged.pages, isEmpty);
      expect(merged.ocrCandidatePageIndices, isEmpty);
    });
  });

  group('ConversionRequest multi-PDF', () {
    ConversionRequest base() => const ConversionRequest(
          pdfPath: '/a/ch1.pdf',
          booksRootDir: '/books',
          modelsDir: '/models',
          llmBaseUrl: '',
          llmApiKey: '',
          llmModel: '',
        );

    test('single-PDF request exposes just pdfPath', () {
      expect(base().sourcePdfPaths, ['/a/ch1.pdf']);
    });

    test('pdfPaths round-trip through JSON', () {
      final req = ConversionRequest(
        pdfPath: '/a/ch1.pdf',
        pdfPaths: const ['/a/ch1.pdf', '/a/ch2.pdf'],
        booksRootDir: '/books',
        modelsDir: '/models',
        llmBaseUrl: '',
        llmApiKey: '',
        llmModel: '',
      );
      final back = ConversionRequest.fromJson(req.toJson());
      expect(back.sourcePdfPaths, ['/a/ch1.pdf', '/a/ch2.pdf']);
    });

    test('old JSON without pdfPaths still parses', () {
      final back = ConversionRequest.fromJson({
        'pdfPath': '/a/ch1.pdf',
        'booksRootDir': '/books',
        'modelsDir': '/models',
        'llmBaseUrl': '',
        'llmApiKey': '',
        'llmModel': '',
      });
      expect(back.sourcePdfPaths, ['/a/ch1.pdf']);
    });
  });
}
