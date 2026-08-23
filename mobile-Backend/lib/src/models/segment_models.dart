import 'compiled_models.dart';

/// Timed segment — the `sections/{id}/segments.json` shape from
/// `docs/DATA_SCHEMA.md`, identical to `frontend/firebrat_app/lib/models/segment.dart`'s
/// `Segment`/`SegmentsFile`. Kept as a separate copy here (rather than a
/// shared dependency) so this package has zero dependency on the app —
/// see package README for why that separation is deliberate.
class TimedSegment {
  final String segmentId;
  final int index;
  final SegmentKind type;
  final String text;
  final String? ref;
  final int startMs;
  final int endMs;
  final bool visuallyEssential;

  const TimedSegment({
    required this.segmentId,
    required this.index,
    required this.type,
    required this.text,
    required this.ref,
    required this.startMs,
    required this.endMs,
    required this.visuallyEssential,
  });

  Map<String, dynamic> toJson() => {
        'segment_id': segmentId,
        'index': index,
        'type': segmentKindToString(type),
        'text': text,
        'ref': ref,
        'start_ms': startMs,
        'end_ms': endMs,
        'visually_essential': visuallyEssential,
      };
}

class SegmentsFile {
  final String sectionId;
  final int sampleRate;
  final int pauseMsBetweenSegments;
  final List<TimedSegment> segments;

  const SegmentsFile({
    required this.sectionId,
    required this.sampleRate,
    required this.pauseMsBetweenSegments,
    required this.segments,
  });

  Map<String, dynamic> toJson() => {
        'section_id': sectionId,
        'sample_rate': sampleRate,
        'pause_ms_between_segments': pauseMsBetweenSegments,
        'segments': segments.map((s) => s.toJson()).toList(),
      };
}
