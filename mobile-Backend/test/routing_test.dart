import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/compilation/routing.dart';
import 'package:mobile_backend_pipeline/src/models/raw_page.dart';

PageChunk _chunk(List<String> pageTexts) => PageChunk(
      chunkIdx: 0,
      pages: [for (var i = 0; i < pageTexts.length; i++) RawPage(pageIdx: i, text: pageTexts[i])],
    );

void main() {
  test('pure prose stays on-device', () {
    final chunk = _chunk(['This is plain narration text with no equations anywhere in it.']);
    expect(needsCloudModel(chunk), isFalse);
  });

  test('a stated equation routes to the cloud model', () {
    final chunk = _chunk(['The clock period tCK = 1/f = 10 ns for this design.']);
    expect(needsCloudModel(chunk), isTrue);
  });

  test('2+ figures/tables routes to the cloud model even with no equation', () {
    final chunk = _chunk(['Plain prose describing the design in words.']);
    expect(needsCloudModel(chunk, figuresAndTablesCount: 2), isTrue);
    expect(needsCloudModel(chunk, figuresAndTablesCount: 1), isFalse);
  });
}
