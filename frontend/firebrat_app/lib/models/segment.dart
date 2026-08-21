/// A single narration segment within a section: one sentence/utterance,
/// timed against the section's combined audio track.
enum SegmentType { heading, prose, figureCallout, formulaCallout, tableCallout }

SegmentType segmentTypeFromString(String s) {
  switch (s) {
    case 'heading':
      return SegmentType.heading;
    case 'figure_callout':
      return SegmentType.figureCallout;
    case 'formula_callout':
      return SegmentType.formulaCallout;
    case 'table_callout':
      return SegmentType.tableCallout;
    case 'prose':
    default:
      return SegmentType.prose;
  }
}

class Segment {
  final String segmentId;
  final int index;
  final SegmentType type;
  final String text;
  final String? ref;
  final int startMs;
  final int endMs;
  final bool visuallyEssential;

  const Segment({
    required this.segmentId,
    required this.index,
    required this.type,
    required this.text,
    required this.ref,
    required this.startMs,
    required this.endMs,
    required this.visuallyEssential,
  });

  factory Segment.fromJson(Map<String, dynamic> json) => Segment(
        segmentId: json['segment_id'] as String,
        index: json['index'] as int,
        type: segmentTypeFromString(json['type'] as String),
        text: json['text'] as String,
        ref: json['ref'] as String?,
        startMs: json['start_ms'] as int,
        endMs: json['end_ms'] as int,
        visuallyEssential: json['visually_essential'] as bool? ?? false,
      );

  bool containsMs(int ms) => ms >= startMs && ms < endMs;
}

class SegmentsFile {
  final String sectionId;
  final int sampleRate;
  final int pauseMsBetweenSegments;
  final List<Segment> segments;

  const SegmentsFile({
    required this.sectionId,
    required this.sampleRate,
    required this.pauseMsBetweenSegments,
    required this.segments,
  });

  factory SegmentsFile.fromJson(Map<String, dynamic> json) => SegmentsFile(
        sectionId: json['section_id'] as String,
        sampleRate: json['sample_rate'] as int? ?? 24000,
        pauseMsBetweenSegments: json['pause_ms_between_segments'] as int? ?? 220,
        segments: (json['segments'] as List)
            .map((e) => Segment.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Binary search for the segment active at [ms], or null if before/after all segments.
  Segment? activeAt(int ms) {
    if (segments.isEmpty) return null;
    int lo = 0, hi = segments.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final s = segments[mid];
      if (ms < s.startMs) {
        hi = mid - 1;
      } else if (ms >= s.endMs) {
        lo = mid + 1;
      } else {
        return s;
      }
    }
    return null;
  }
}
