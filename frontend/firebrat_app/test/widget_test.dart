// Smoke test: the app widget tree builds without throwing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firebrat_app/app.dart';

void main() {
  testWidgets('FirebratApp builds and shows the library app bar', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: FirebratApp()));
    await tester.pump();
    expect(find.text('Firebrat'), findsOneWidget);
  });
}
