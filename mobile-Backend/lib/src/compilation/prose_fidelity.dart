import '../models/compiled_models.dart';
import '../models/raw_page.dart';

class ProseFidelityResult {
  final List<CompiledSection> sections;
  final List<int> sourceFallbackPages;
  const ProseFidelityResult(this.sections, this.sourceFallbackPages);
}

/// Ordinary prose must not become a summary or change names/pronouns/numbers.
/// Keep model structure when wording is faithful; otherwise narrate the source.
/// This is deliberately not a semantic validator for mathematical rewrites or
/// ambiguously aligned multi-page sections.
ProseFidelityResult preserveOrdinaryProse(
  List<CompiledSection> sections,
  List<RawPage> pages,
) {
  final replacements = <int, CompiledSection>{};
  final affected = <int>[];
  for (final page in pages) {
    final matching = sections
        .where((s) => s.sourcePages.contains(page.pageIdx))
        .toList();
    if (matching.isEmpty ||
        matching.any((s) => s.sourcePages.length != 1) ||
        matching
            .expand((s) => s.segments)
            .any((s) => s.type == SegmentKind.formulaCallout) ||
        RegExp(r'[=<>∑∫±]').hasMatch(page.text)) {
      continue;
    }
    final lines = page.text.trim().split('\n');
    if (lines.length > 1 && lines.last.trim() == '${page.pageIdx + 1}') {
      lines.removeLast();
    }
    final source = lines.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (source.isEmpty) continue;
    final spoken = matching
        .expand((s) => s.segments)
        .where((s) => s.type != SegmentKind.heading)
        .map((s) => s.text)
        .join(' ');
    String words(String text) => RegExp(
      r'[\p{L}\p{N}]+',
      unicode: true,
    ).allMatches(text.toLowerCase()).map((m) => m.group(0)!).join(' ');
    if (words(source) == words(spoken)) continue;
    replacements[page.pageIdx] = CompiledSection(
      title: matching.first.title,
      sourcePages: [page.pageIdx],
      segments: [CompiledSegment(type: SegmentKind.prose, text: source)],
    );
    affected.add(page.pageIdx);
  }
  final emitted = <int>{};
  return ProseFidelityResult([
    for (final section in sections)
      if (section.sourcePages.length == 1 &&
          replacements.containsKey(section.sourcePages.single)) ...[
        if (emitted.add(section.sourcePages.single))
          replacements[section.sourcePages.single]!,
      ] else
        section,
  ], affected);
}
