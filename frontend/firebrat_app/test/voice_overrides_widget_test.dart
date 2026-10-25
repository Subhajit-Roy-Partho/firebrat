import 'package:firebrat_app/screens/conversion_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('typing valid overrides line by line never shows an error at the end', (tester) async {
    SharedPreferences.setMockInitialValues({
      'conversion.mode': 'onDevice',
      'conversion.contentMode': 'novel',
      'conversion.voiceEngine': 'kokoroOnnx',
    });
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: ConversionSettingsScreen())));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('character-voice-overrides'));
    await tester.scrollUntilVisible(field, 200, scrollable: find.byType(Scrollable).first);
    for (final text in [
      'Alice=child cheerful',
      'Alice=child cheerful\nMad Hatter=Michael, elder, gruff',
      'Alice=child cheerful\nMad Hatter=Michael, elder, gruff\nQueen of Hearts=female stern',
    ]) {
      await tester.enterText(field, text);
      await tester.pumpAndSettle();
      expect(find.textContaining('Use Name=Voice'), findsNothing, reason: 'valid text "$text" must not show an error');
    }
    await tester.enterText(field, 'Alice=grumpy');
    await tester.pumpAndSettle();
    expect(find.textContaining('Use Name=Voice'), findsOneWidget);
    await tester.enterText(field, '');
    await tester.pumpAndSettle();
    expect(find.textContaining('Use Name=Voice'), findsNothing);
  });
}
