import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/compilation/compilation_router.dart';
import 'package:mobile_backend_pipeline/src/compilation/on_device_compiler.dart';
import 'package:mobile_backend_pipeline/src/models/compiled_models.dart';
import 'package:mobile_backend_pipeline/src/models/raw_page.dart';

class CountingCompiler extends OnDeviceCompiler {
  int calls = 0;
  @override
  Future<CompiledChunkOutput> compileChunk(PageChunk chunk, {
    required int Function() nextFormulaNumber,
  }) async {
    calls++;
    return CompiledChunkOutput(sections: [CompiledSection(
      title: 'Section', sourcePages: [999], segments: [CompiledSegment(
        type: SegmentKind.formulaCallout, text: chunk.pages.first.text,
        latex: 'x=1', ref: 'formula_${nextFormulaNumber()}',
      )],
    )]);
  }
}

void main() {
  late Directory dir;
  setUp(() async {dir = await Directory.systemTemp.createTemp('firebrat-checkpoint-');});
  tearDown(() async {await dir.delete(recursive: true);});
  List<PageChunk> chunks([String text = 'First']) => [
    PageChunk(chunkIdx: 0, pages: [RawPage(pageIdx: 0, text: text)]),
    const PageChunk(chunkIdx: 1, pages: [RawPage(pageIdx: 1, text: 'Second')]),
  ];
  test('resume skips compiler and remints formula ids while sanitizing pages', () async {
    final initial = CountingCompiler();
    final first = await CompilationRouter(onDeviceCompiler: initial)
      .compileAll(chunks(), checkpointDir: dir.path);
    expect(initial.calls, 2);
    final resumed = CountingCompiler();
    final second = await CompilationRouter(onDeviceCompiler: resumed)
      .compileAll(chunks(), checkpointDir: dir.path);
    expect(resumed.calls, 0);
    expect(second.map((s) => s.segments.single.ref), ['formula_0001', 'formula_0002']);
    expect(second.map((s) => s.sourcePages.single), [0, 1]);
    expect(second.first.segments.single.ref, first.first.segments.single.ref);
  });
  test('source/model/policy changes invalidate matching checkpoints', () async {
    await CompilationRouter(onDeviceCompiler: CountingCompiler())
      .compileAll(chunks(), checkpointDir: dir.path, checkpointModelKey: 'model1');
    final source = CountingCompiler();
    await CompilationRouter(onDeviceCompiler: source)
      .compileAll(chunks('Changed'), checkpointDir: dir.path, checkpointModelKey: 'model1');
    expect(source.calls, 1);
    final model = CountingCompiler();
    await CompilationRouter(onDeviceCompiler: model)
      .compileAll(chunks('Changed'), checkpointDir: dir.path, checkpointModelKey: 'model2');
    expect(model.calls, 2);
    final policy = CountingCompiler();
    // Plain prose stays local, but enabling a cloud policy still invalidates.
    await CompilationRouter(onDeviceCompiler: policy, allowCloudFallback: true)
      .compileAll(chunks('Changed'), checkpointDir: dir.path, checkpointModelKey: 'model2');
    expect(policy.calls, 2);
  });
  test('partial corrupt checkpoint recompiles safely', () async {
    await File('${dir.path}/chunk_0.json').writeAsString('{');
    final compiler = CountingCompiler();
    await CompilationRouter(onDeviceCompiler: compiler)
      .compileAll(chunks(), checkpointDir: dir.path);
    expect(compiler.calls, 2);
  });
}
