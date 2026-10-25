import 'dart:io';
import 'package:firebrat_app/screens/conversion_settings_screen.dart';
import 'package:firebrat_app/screens/llm_key_guide_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('guide lists OpenRouter, Groq and Google AI Studio with steps and URLs', (tester) async {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: LlmKeyGuideScreen()));
    for (final name in ['OpenRouter', 'Groq', 'Google AI Studio (Gemini)']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('https://openrouter.ai/api/v1'), findsOneWidget);
    expect(find.text('https://api.groq.com/openai/v1'), findsOneWidget);
    expect(find.textContaining('20 requests a minute'), findsOneWidget);
    expect(find.textContaining('Character research sends only the book title and character names'), findsOneWidget);
    expect(find.text('Use this URL'), findsNWidgets(3));
  });

  testWidgets('Conversion settings opens the guide and fills in the chosen URL', (tester) async {
    SharedPreferences.setMockInitialValues({
      'conversion.mode': 'onDevice',
      'conversion.contentMode': 'novel',
      'conversion.allowCloudFallback': true,
    });
    final support = Directory.systemTemp.createTempSync('firebrat-guide-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => support.path);
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: ConversionSettingsScreen())));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('How to get a free API key'), 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('How to get a free API key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('How to get a free API key'));
    await tester.pumpAndSettle();
    expect(find.text('Get a free API key'), findsOneWidget);
    await tester.tap(find.text('Use this URL').first); // OpenRouter, listed first
    await tester.pumpAndSettle();
    expect(find.text('URL filled in. Paste your API key, then tap Load models.'), findsOneWidget);
    // The URL field is above the buttons in the (lazy) list: scroll back up to it.
    await tester.scrollUntilVisible(find.text('https://openrouter.ai/api/v1'), -200, scrollable: find.byType(Scrollable).first);
    expect(find.text('https://openrouter.ai/api/v1'), findsOneWidget); // now in the LLM URL field
  });
}
