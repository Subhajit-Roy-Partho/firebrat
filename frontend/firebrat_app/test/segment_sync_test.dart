// Pure-Dart tests for the segment-timing sync logic that drives highlight
// state — the actual "highlight the formula while it's spoken" feature.
// No device/emulator needed.
import 'package:flutter_test/flutter_test.dart';
import 'package:firebrat_app/models/segment.dart';

SegmentsFile _buildFixture() {
  return SegmentsFile.fromJson({
    'section_id': 'sec_0001',
    'sample_rate': 24000,
    'pause_ms_between_segments': 220,
    'segments': [
      {'segment_id': 's1', 'index': 0, 'type': 'heading', 'text': 'Intro', 'ref': null, 'start_ms': 0, 'end_ms': 2000, 'visually_essential': false},
      {'segment_id': 's2', 'index': 1, 'type': 'prose', 'text': 'Some prose.', 'ref': null, 'start_ms': 2220, 'end_ms': 5000, 'visually_essential': false},
      {'segment_id': 's3', 'index': 2, 'type': 'formula_callout', 'text': 'A formula.', 'ref': 'formula_0001', 'start_ms': 5220, 'end_ms': 8000, 'visually_essential': true},
    ],
  });
}

void main() {
  group('SegmentsFile.activeAt', () {
    test('finds the segment containing a mid-segment timestamp', () {
      final f = _buildFixture();
      expect(f.activeAt(1000)?.segmentId, 's1');
      expect(f.activeAt(3000)?.segmentId, 's2');
      expect(f.activeAt(6000)?.segmentId, 's3');
    });

    test('returns null during inter-segment silence gaps', () {
      final f = _buildFixture();
      expect(f.activeAt(2100), isNull); // between s1.end (2000) and s2.start (2220)
    });

    test('returns null before the first segment and after the last', () {
      final f = _buildFixture();
      expect(f.activeAt(-1), isNull);
      expect(f.activeAt(999999), isNull);
    });

    test('segment end is exclusive (boundary belongs to next segment)', () {
      final f = _buildFixture();
      expect(f.activeAt(2000)?.segmentId, isNot('s1'));
    });

    test('formula_callout segment carries its ref for highlight/lookup', () {
      final f = _buildFixture();
      final s = f.activeAt(6000)!;
      expect(s.type, SegmentType.formulaCallout);
      expect(s.ref, 'formula_0001');
      expect(s.visuallyEssential, isTrue);
    });
  });

  group('Segment.containsMs', () {
    test('matches the half-open [start, end) interval', () {
      final seg = Segment(
        segmentId: 'x', index: 0, type: SegmentType.prose, text: 't',
        ref: null, startMs: 100, endMs: 200, visuallyEssential: false,
      );
      expect(seg.containsMs(100), isTrue);
      expect(seg.containsMs(199), isTrue);
      expect(seg.containsMs(200), isFalse);
      expect(seg.containsMs(99), isFalse);
    });
  });
}
