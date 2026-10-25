import 'package:firebrat_app/app.dart';
import 'package:firebrat_app/models/book.dart';
import 'package:firebrat_app/screens/tour_screen.dart';
import 'package:firebrat_app/state/library_providers.dart';
import 'package:firebrat_app/state/tour_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app() => ProviderScope(
      overrides: [
        catalogProvider.overrideWith((ref) async => const <BookSummary>[]),
        localBooksProvider.overrideWith((ref) async => const <BookSummary>[]),
      ],
      child: const FirebratApp(),
    );

void main() {
  testWidgets('first launch shows the guide; finishing remembers it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Firebrat'), findsOneWidget);

    for (var i = 0; i < 7; i++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();

    expect(find.byType(TourScreen), findsNothing);
    expect(await TourStore.hasSeen(), isTrue);
  });

  testWidgets('skipping is remembered and the guide does not reopen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.byType(TourScreen), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byType(TourScreen), findsNothing);
  });

  testWidgets('guide can be reopened from the drawer', (tester) async {
    SharedPreferences.setMockInitialValues({TourStore.preferenceKey: true});
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byType(TourScreen), findsNothing);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('App guide'), 100,
        scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)));
    await tester.tap(find.text('App guide'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Firebrat'), findsOneWidget);
  });

  testWidgets('guide fits a narrow screen with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: const TourScreen(),
    ));
    for (var i = 0; i < 7; i++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
}
