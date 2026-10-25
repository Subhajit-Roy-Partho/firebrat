// Smoke test: the app widget tree builds without throwing. Network/disk
// providers are overridden with fixed values so the test doesn't depend on
// real platform channels (path_provider, dio) that aren't available under
// flutter_test's harness.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firebrat_app/app.dart';
import 'package:firebrat_app/models/book.dart';
import 'package:firebrat_app/state/library_providers.dart';
import 'package:firebrat_app/state/tour_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('FirebratApp opens the offline library without requiring sign-in', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({TourStore.preferenceKey: true});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        catalogProvider.overrideWith((ref) async => const <BookSummary>[]),
        localBooksProvider.overrideWith((ref) async => const <BookSummary>[]),
      ],
      child: const FirebratApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Firebrat'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsNothing);
    expect(find.text('Import a book file'), findsOneWidget);
    expect(find.textContaining('server'), findsNothing);
  });
}
