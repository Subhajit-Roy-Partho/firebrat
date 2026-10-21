import 'dart:io';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  test('separately positioned PDF words retain spaces in reading order', () async {
    final directory = await Directory.systemTemp.createTemp('firebrat-layout-');
    final document = PdfDocument();
    final page = document.pages.add();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
    var x = 20.0;
    for (final word in ['Voltage', 'margin', 'is', '1.02', 'V.']) {
      page.graphics.drawString(word, font, bounds: Rect.fromLTWH(x, 20, 100, 30));
      x += font.measureString(word).width + 5;
    }
    try {
      final pdf = File('${directory.path}/positioned.pdf');
      await pdf.writeAsBytes(await document.save());
      document.dispose();
      final extracted = await MobilePdfTextExtractor.extractPages(pdf.path);
      expect(extracted.pages.single.text, contains('Voltage margin is 1.02 V.'));
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
