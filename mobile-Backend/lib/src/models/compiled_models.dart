/// Stage-2-shaped output — what the compilation LLM (on-device or cloud)
/// returns for one chunk, before formula ids are minted or timing exists.
/// Mirrors `compiled.json`'s pre-timing shape in `docs/DATA_SCHEMA.md`.
library;

enum SegmentKind { heading, prose, figureCallout, formulaCallout, tableCallout }

SegmentKind segmentKindFromString(String s) => switch (s) {
      'heading' => SegmentKind.heading,
      'figure_callout' => SegmentKind.figureCallout,
      'formula_callout' => SegmentKind.formulaCallout,
      'table_callout' => SegmentKind.tableCallout,
      _ => SegmentKind.prose,
    };

String segmentKindToString(SegmentKind k) => switch (k) {
      SegmentKind.heading => 'heading',
      SegmentKind.prose => 'prose',
      SegmentKind.figureCallout => 'figure_callout',
      SegmentKind.formulaCallout => 'formula_callout',
      SegmentKind.tableCallout => 'table_callout',
    };

class CompiledSegment {
  final SegmentKind type;
  final String text;
  final String? ref; // set for figure/table callouts, null for formula (minted after)
  final String? latex; // set for formula callouts only
  final bool visuallyEssential;

  const CompiledSegment({
    required this.type,
    required this.text,
    this.ref,
    this.latex,
    this.visuallyEssential = false,
  });

  factory CompiledSegment.fromJson(Map<String, dynamic> json) => CompiledSegment(
        type: segmentKindFromString(json['type'] as String? ?? 'prose'),
        text: (json['text'] as String? ?? '').trim(),
        ref: json['ref'] as String?,
        latex: json['latex'] as String?,
        visuallyEssential: json['visually_essential'] as bool? ?? false,
      );

  CompiledSegment copyWith({String? ref}) => CompiledSegment(
        type: type,
        text: text,
        ref: ref ?? this.ref,
        latex: latex,
        visuallyEssential: visuallyEssential,
      );
}

class CompiledSection {
  final String title;
  final List<int> sourcePages;
  final List<CompiledSegment> segments;

  const CompiledSection({required this.title, required this.sourcePages, required this.segments});

  factory CompiledSection.fromJson(Map<String, dynamic> json) => CompiledSection(
        title: (json['title'] as String? ?? '').trim(),
        sourcePages: (json['source_pages'] as List? ?? const []).map((e) => e as int).toList(),
        segments: (json['segments'] as List? ?? const [])
            .map((e) => CompiledSegment.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class CompiledChunkOutput {
  final List<CompiledSection> sections;
  const CompiledChunkOutput({required this.sections});

  factory CompiledChunkOutput.fromJson(Map<String, dynamic> json) => CompiledChunkOutput(
        sections: (json['sections'] as List? ?? const [])
            .map((e) => CompiledSection.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
