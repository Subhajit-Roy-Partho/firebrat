import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';

class _Local extends OnDeviceCompiler {
  int calls = 0;
  @override
  Future<CompiledChunkOutput> compileChunk(PageChunk chunk, {required int Function() nextFormulaNumber}) async {
    calls++;
    return const CompiledChunkOutput(sections: [CompiledSection(title: 'Relationship', sourcePages: [99],
      segments: [CompiledSegment(type: SegmentKind.prose, text: 'The period is one over the frequency.')])]);
  }
}
void main() {
  test('math stays local without credentials and source pages are corrected', () async {
    const settings = OnDeviceModeSettings();
    expect(settings.allowCloudFallback, isFalse);
    expect(settings.llmApiKey, isEmpty);
    final local = _Local();
    const chunk = PageChunk(chunkIdx: 0, pages: [RawPage(pageIdx: 2, text: 'T = 1/f')]);
    expect(needsCloudModel(chunk), isTrue);
    final sections = await CompilationRouter(onDeviceCompiler: local).compileAll([chunk]);
    expect(local.calls, 1);
    expect(sections.single.sourcePages, [2]);
  });
  test('local chunking bounds dense pages and preserves every character', () {
    final text = List.generate(900, (i) => 'word$i ').join();
    final chunks = chunkLocalPages([RawPage(pageIdx: 7, text: text)]);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.pages.single.text.length <= 2000), isTrue);
    expect(chunks.every((c) => c.pages.single.pageIdx == 7), isTrue);
    expect(chunks.map((c) => c.pages.single.text).join(), text);
  });
  test('conversion request persists offline policy', () {
    const request = ConversionRequest(pdfPath: 'a.pdf', booksRootDir: 'books', modelsDir: 'models', llmBaseUrl: '', llmApiKey: '', llmModel: '');
    expect(ConversionRequest.fromJson(request.toJson()).allowCloudFallback, isFalse);
    expect(ConversionRequest.fromJson({...request.toJson(), 'allowCloudFallback': true}).allowCloudFallback, isTrue);
  });
}
