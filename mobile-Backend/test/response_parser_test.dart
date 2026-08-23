import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/compilation/response_parser.dart';
import 'package:mobile_backend_pipeline/src/models/compiled_models.dart';

int Function() _counterFrom(int start) {
  var n = start;
  return () => n++;
}

void main() {
  test('parses a well-formed response', () {
    final out = parseCompiledChunkResponse(
      '{"sections":[{"title":"Intro","source_pages":[0],"segments":['
      '{"type":"heading","text":"Introduction","ref":null,"latex":null,"visually_essential":false},'
      '{"type":"prose","text":"Some plain narration.","ref":null,"latex":null,"visually_essential":false}'
      ']}]}',
      nextFormulaNumber: _counterFrom(1),
    );
    expect(out.sections, hasLength(1));
    expect(out.sections.first.segments, hasLength(2));
    expect(out.sections.first.segments[0].type, SegmentKind.heading);
  });

  test('strips markdown code fences', () {
    final out = parseCompiledChunkResponse(
      '```json\n{"sections":[]}\n```',
      nextFormulaNumber: _counterFrom(1),
    );
    expect(out.sections, isEmpty);
  });

  test('unwraps a {"response": {...}} envelope', () {
    final out = parseCompiledChunkResponse(
      '{"response":{"sections":[{"title":"X","source_pages":[],"segments":[]}]}}',
      nextFormulaNumber: _counterFrom(1),
    );
    expect(out.sections, hasLength(1));
  });

  test('mints a real formula id and rewrites ref for a valid formula_callout', () {
    final out = parseCompiledChunkResponse(
      '{"sections":[{"title":"Math","source_pages":[0],"segments":['
      '{"type":"formula_callout","text":"T equals one over f.","ref":null,"latex":"T = 1/f","visually_essential":false}'
      ']}]}',
      nextFormulaNumber: _counterFrom(5),
    );
    final seg = out.sections.first.segments.first;
    expect(seg.type, SegmentKind.formulaCallout);
    expect(seg.ref, 'formula_0005');
  });

  test('demotes a formula_callout with no latex to prose', () {
    final out = parseCompiledChunkResponse(
      '{"sections":[{"title":"Math","source_pages":[0],"segments":['
      '{"type":"formula_callout","text":"No real formula here.","ref":null,"latex":null,"visually_essential":false}'
      ']}]}',
      nextFormulaNumber: _counterFrom(1),
    );
    expect(out.sections.first.segments.first.type, SegmentKind.prose);
  });

  test('demotes a hallucinated figure_callout to prose (no catalog in this pipeline)', () {
    final out = parseCompiledChunkResponse(
      '{"sections":[{"title":"Figures","source_pages":[0],"segments":['
      '{"type":"figure_callout","text":"As shown in the figure.","ref":"fig_0001","latex":null,"visually_essential":false}'
      ']}]}',
      nextFormulaNumber: _counterFrom(1),
    );
    expect(out.sections.first.segments.first.type, SegmentKind.prose);
  });

  test('blank titles get a fallback', () {
    final out = parseCompiledChunkResponse(
      '{"sections":[{"title":"  ","source_pages":[0],"segments":[]}]}',
      nextFormulaNumber: _counterFrom(1),
    );
    expect(out.sections.first.title, 'Untitled section 1');
  });

  test('rejects a JSON-Schema hallucination instead of an instance', () {
    expect(
      () => parseCompiledChunkResponse(
        '{"type":"object","properties":{"sections":{"type":"array"}},"required":["sections"]}',
        nextFormulaNumber: _counterFrom(1),
      ),
      throwsA(isA<LlmResponseParseException>()),
    );
  });

  test('rejects non-JSON text', () {
    expect(
      () => parseCompiledChunkResponse('not json at all', nextFormulaNumber: _counterFrom(1)),
      throwsA(isA<LlmResponseParseException>()),
    );
  });
}
