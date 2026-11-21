import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:firebrat_app/widgets/pdf_image_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'drag a PDF region and return a PNG crop; cancel returns no selection',
    (tester) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 400, 400),
        Paint()..color = Colors.red,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(400, 400);
      picture.dispose();
      Uint8List? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<Uint8List>(
                    MaterialPageRoute(
                      builder: (_) => PdfImageSelection(image: image),
                    ),
                  );
                },
                child: const Text('Select'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      final bounds = tester.getRect(find.byType(RawImage));
      await tester.dragFrom(
        bounds.center - const Offset(60, 60),
        const Offset(120, 120),
      );
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Use selected image'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final codec = await tester.runAsync(
        () => ui.instantiateImageCodec(result!),
      );
      final frame = await tester.runAsync(() => codec!.getNextFrame());
      expect(frame!.image.width, lessThan(400));
      expect(frame.image.height, lessThan(400));
      frame.image.dispose();
      codec!.dispose();
      result = null;
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.pumpWidget(const SizedBox());
      image.dispose();
    },
  );
}
