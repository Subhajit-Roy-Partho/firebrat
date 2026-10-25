import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:firebrat_app/services/avatar_store.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Uint8List> _png(int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF3355FF));
  final img = await rec.endRecording().toImage(w, h);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('avatar-'));
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('wide photo is square-cropped and downscaled', (tester) async {
    await tester.runAsync(() async {
      final store = AvatarStore(directory: dir);
      final f = await store.save('uid-1', await _png(2000, 1000));
      final codec = await ui.instantiateImageCodec(await f.readAsBytes());
      final img = (await codec.getNextFrame()).image;
      expect((img.width, img.height), (AvatarStore.size, AvatarStore.size));
      expect(f.path.contains('uid-1'), isFalse); // account id never in the filename
    });
  });

  testWidgets('small photo is kept, avatars are per account, remove works', (tester) async {
    await tester.runAsync(() async {
      final store = AvatarStore(directory: dir);
      await store.save('a', await _png(100, 100));
      expect(await store.load('a'), isNotNull);
      expect(await store.load('b'), isNull);
      await store.remove('a');
      expect(await store.load('a'), isNull);
    });
  });

  testWidgets('non-image bytes are rejected', (tester) async {
    await tester.runAsync(() async {
      final store = AvatarStore(directory: dir);
      await expectLater(store.save('a', Uint8List.fromList([1, 2, 3])), throwsFormatException);
      expect(await store.load('a'), isNull);
    });
  });
}
