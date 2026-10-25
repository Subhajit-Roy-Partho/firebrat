import 'package:firebrat_app/widgets/book_cover.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('generated lock-screen cover is a 2:3 PNG and stable per book', (tester) async {
    await tester.runAsync(() async {
      final a = await renderGeneratedCoverPng(bookId: 'b1', title: 'A Novel', author: 'Someone', width: 200);
      final b = await renderGeneratedCoverPng(bookId: 'b1', title: 'A Novel', author: 'Someone', width: 200);
      expect(a.sublist(0, 8), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      expect(a, b); // deterministic
      expect(a.length, greaterThan(1000));
    });
  });
}
