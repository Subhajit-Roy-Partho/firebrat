import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebrat_app/screens/information_screen.dart';

void main() {
  testWidgets(
    'public privacy, deletion and support links work without signing in',
    (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: InformationScreen(
            openLink: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      );
      for (final entry in {
        'Privacy policy': 'privacy',
        'Data use & safety': 'data-safety',
        'Request account deletion': 'delete-account',
        'Conversion guide': 'help',
        'Support & bug reports': 'support',
      }.entries) {
        await tester.ensureVisible(find.text(entry.key));
        await tester.tap(find.text(entry.key));
        await tester.pump();
        expect(
          opened.last.toString(),
          'https://subhajit-roy-partho.github.io/firebrat/${entry.value}/',
        );
      }
    },
  );
  testWidgets(
    'large text wraps and a browser failure leaves a usable address',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: InformationScreen(openLink: (_) async => false),
        ),
      );
    await tester.scrollUntilVisible(find.text('Privacy policy'), 250,
        scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Privacy policy'));
      await tester.pump();
      expect(find.textContaining('Could not open the page.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
