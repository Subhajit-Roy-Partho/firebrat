import 'package:firebrat_app/app.dart';
import 'package:firebrat_app/models/book.dart';
import 'package:firebrat_app/screens/conversions_screen.dart';
import 'package:firebrat_app/screens/sign_in_screen.dart';
import 'package:firebrat_app/state/conversions_providers.dart';
import 'package:firebrat_app/state/guest_access_provider.dart';
import 'package:firebrat_app/state/library_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ForbiddenGuestJobs extends JobsNotifier {
  @override
  build() => throw StateError('Guest must never poll authenticated jobs');
}

void main() {
  test('guest choice survives restart and explicit sign-in clears it', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    first.read(guestAccessProvider);
    await first.read(guestAccessProvider.notifier).setGuest(true);
    first.dispose();
    final restarted = ProviderContainer();
    restarted.read(guestAccessProvider);
    await Future<void>.delayed(Duration.zero);
    expect(restarted.read(guestAccessProvider), isTrue);
    await restarted.read(guestAccessProvider.notifier).setGuest(false);
    expect((await SharedPreferences.getInstance()).getBool(GuestAccessNotifier.preferenceKey), isFalse);
    restarted.dispose();
  });

  testWidgets('guest entry works on narrow screens with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var chosen = false;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.8)), child: child!),
      home: SignInScreen(onContinueAsGuest: () => chosen = true),
    ));
    await tester.ensureVisible(find.text('Continue as guest'));
    await tester.tap(find.text('Continue as guest'));
    expect(chosen, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved guest can open server library without Firebase login', (tester) async {
    SharedPreferences.setMockInitialValues({
      'conversion.mode': 'cloud', GuestAccessNotifier.preferenceKey: true,
    });
    await tester.pumpWidget(ProviderScope(overrides: [
      catalogProvider.overrideWith((ref) async => const <BookSummary>[]),
      localBooksProvider.overrideWith((ref) async => const <BookSummary>[]),
    ], child: const FirebratApp()));
    await tester.pumpAndSettle();
    expect(find.text('Continue as guest'), findsNothing);
    expect(find.text('Import a book file'), findsOneWidget);
  });

  testWidgets('guest server conversion explains login and never polls jobs', (tester) async {
    SharedPreferences.setMockInitialValues({'conversion.mode': 'cloud'});
    await tester.pumpWidget(ProviderScope(overrides: [
      jobsProvider.overrideWith(ForbiddenGuestJobs.new),
    ], child: const MaterialApp(home: ConversionsScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Sign in for server conversion'), findsOneWidget);
    expect(find.text('Use on-device conversion'), findsOneWidget);
    expect(find.text('Convert a PDF or ZIP'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
