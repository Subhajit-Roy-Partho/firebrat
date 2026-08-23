import 'dart:convert';
import '../models/compiled_models.dart';
import '../util/ids.dart';

/// Turns raw LLM output text into a validated [CompiledChunkOutput], with
/// formula ids minted and bad segments defused — mirrors `compile_llm.py`'s
/// `_normalize_wrapper` / `_sanitize_refs` / `_fill_blank_titles` and the
/// formula-id-minting step, so on-device output is exactly as trustworthy
/// (or as honestly untrustworthy) as the server's.
class LlmResponseParseException implements Exception {
  final String message;
  LlmResponseParseException(this.message);
  @override
  String toString() => 'LlmResponseParseException: $message';
}

/// [nextFormulaNumber] is called once per formula_callout segment that has
/// non-empty latex, in encounter order, and must return a monotonically
/// increasing 1-based counter shared across the whole book (not just this
/// chunk) — same invariant as the server's `formula_counter`.
CompiledChunkOutput parseCompiledChunkResponse(
  String rawText, {
  required int Function() nextFormulaNumber,
}) {
  final jsonText = _stripCodeFences(rawText).trim();
  late final dynamic decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException catch (e) {
    throw LlmResponseParseException('not valid JSON: $e');
  }
  if (decoded is! Map<String, dynamic>) {
    throw LlmResponseParseException('top-level JSON is not an object');
  }

  // Guard against the model hallucinating a JSON Schema instead of an
  // instance (seen in real runs server-side — see backend/tests/test_schema.py).
  if (decoded.containsKey('properties') && !decoded.containsKey('sections')) {
    throw LlmResponseParseException('LLM returned a JSON Schema instead of an instance');
  }

  final normalized = _normalizeWrapper(decoded);
  final parsed = CompiledChunkOutput.fromJson(normalized);

  final sections = <CompiledSection>[];
  for (var i = 0; i < parsed.sections.length; i++) {
    final section = parsed.sections[i];
    final title = section.title.trim().isEmpty ? 'Untitled section ${i + 1}' : section.title.trim();

    final segments = <CompiledSegment>[];
    for (final seg in section.segments) {
      if (seg.type == SegmentKind.formulaCallout) {
        if (seg.latex == null || seg.latex!.trim().isEmpty) {
          // No real formula authored — demote to prose rather than drop
          // it silently, same as the server's handling of an empty latex.
          segments.add(CompiledSegment(type: SegmentKind.prose, text: seg.text));
        } else {
          final id = makeFormulaId(nextFormulaNumber());
          segments.add(seg.copyWith(ref: id));
        }
      } else if (seg.type == SegmentKind.figureCallout || seg.type == SegmentKind.tableCallout) {
        // This pipeline has no figure/table catalog (see
        // pdf_text_extractor.dart's documented limitation) — any ref the
        // model invents here is necessarily hallucinated, so the segment
        // is demoted to prose rather than shipped with a dangling ref.
        segments.add(CompiledSegment(type: SegmentKind.prose, text: seg.text));
      } else {
        segments.add(seg);
      }
    }
    sections.add(CompiledSection(title: title, sourcePages: section.sourcePages, segments: segments));
  }

  return CompiledChunkOutput(sections: sections);
}

String _stripCodeFences(String text) {
  final trimmed = text.trim();
  final fenceMatch = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(trimmed);
  return fenceMatch != null ? fenceMatch.group(1)! : trimmed;
}

/// Some models wrap the real payload in an envelope like
/// `{"response": {...}}` or return `{"sections": [...]}` directly already
/// — pass the latter through, unwrap the former. Mirrors
/// `_normalize_wrapper` server-side.
Map<String, dynamic> _normalizeWrapper(Map<String, dynamic> decoded) {
  if (decoded.containsKey('sections')) return decoded;
  for (final key in const ['response', 'result', 'output', 'data']) {
    final inner = decoded[key];
    if (inner is Map<String, dynamic> && inner.containsKey('sections')) return inner;
  }
  return decoded;
}
