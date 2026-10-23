import 'package:firebrat_app/screens/source_pdf_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final sample in [
    (100, 0, 1.0),
    (100, 8, 8.0),
    (0, 8, 1.0),
    (100, 1, 1.0),
  ]) {
    testWidgets(
      'PDF page ${sample.$1} with count ${sample.$2} stays in slider bounds',
      (tester) async {
        int? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SourcePdfPageSlider(
                currentPage: sample.$1,
                pageCount: sample.$2,
                onPageSelected: (value) => selected = value,
              ),
            ),
          ),
        );
        final slider = tester.widget<Slider>(find.byType(Slider));
        expect(tester.takeException(), isNull);
        expect(slider.value, sample.$3);
        if (sample.$2 <= 1) {
          expect(slider.onChanged, isNull);
        } else {
          slider.onChanged!(3);
          expect(selected, 3);
        }
      },
    );
  }
}
