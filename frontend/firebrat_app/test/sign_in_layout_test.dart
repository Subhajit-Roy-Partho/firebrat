import 'package:firebrat_app/screens/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sign in stays reachable on a narrow screen with keyboard', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.8)),
        child: child!,
      ),
      home: SignInScreen(onContinueAsGuest: () {}),
    ));
    expect(tester.takeException(), isNull);
    final register = find.text('New here? Create an account');
    await tester.ensureVisible(register);
    await tester.tap(register);
    await tester.pump();
    expect(find.text('Create account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
