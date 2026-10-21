import 'dart:io';

import 'package:flutter/services.dart';
import 'package:firebrat_app/screens/conversion_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('mode choices wrap on a narrow screen with large text', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final support = Directory.systemTemp.createTempSync('firebrat-layout-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel, (_) async => support.path,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
        child: child!,
      ),
      home: const ConversionSettingsScreen(),
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('On-device'), 160, scrollable: find.byType(Scrollable).first);
    expect(find.byType(ChoiceChip), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Server'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Novel / characters'), 100, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Novel / characters'));
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getString('conversion.contentMode'), 'novel');
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('On-device'), -160, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('On-device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('On-device'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Exercise every part of the lazy settings list; constructing only its
    // first viewport misses the long model labels and voice dropdown.
    await tester.scrollUntilVisible(find.text('Device acceleration'), 160, scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Kokoro (on-device neural)'), 160, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Kokoro (on-device neural)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kokoro (on-device neural)'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Kokoro voice'), 160, scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('male-character-voice')), 160, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.byKey(const ValueKey('male-character-voice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('male-character-voice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Michael').last);
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getString('conversion.maleVoice'), 'Michael');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('character-voice-overrides')), 160, scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byKey(const ValueKey('character-voice-overrides')), 'Alice=Nicole');
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getString('conversion.characterVoices'), contains('Nicole'));
    await tester.scrollUntilVisible(find.text('Save'), 160, scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });
}
