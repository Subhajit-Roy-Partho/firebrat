import 'package:firebrat_app/screens/cast_screen.dart';
import 'package:firebrat_app/state/cast_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final phoneRoster = <String, dynamic>{
  'mode': 'novel',
  'scanned_pages': 400,
  'dialogue': {'total': 100, 'attributed': 87},
  'voice_engine': 'kokoroOnnx',
  'assigned_voices': {'Elizabeth': 'Bella', 'Mr. Darcy': 'Michael'},
  'research': {
    'status': 'applied', 'articles': ['Pride and Prejudice'], 'described': 2, 'not_described': ['Wickham'],
  },
  'unmatched_overrides': ['Lizzie'],
  'characters': [
    {'name': 'Mr. Darcy', 'lines': 40, 'evidence_pages': [11, 12, 30], 'voice_gender': 'male',
     'traits': {'gender': 'male', 'age': 'adult', 'temperament': 'stern', 'source': 'web'},
     'style': {'pitch': .95, 'rate': 0.48 * 0.95, 'voice_index': 1}},
    {'name': 'Elizabeth', 'lines': 120, 'evidence_pages': [3, 4], 'voice_gender': 'female',
     'traits': {'gender': 'female', 'age': 'young', 'temperament': 'cheerful', 'source': 'web'},
     'style': {'pitch': 1.08, 'rate': 0.48 * 1.09, 'voice_index': 2}},
    {'name': 'Wickham', 'lines': 3, 'evidence_pages': [20], 'voice_gender': 'unknown', 'traits': {},
     'style': {'pitch': 1, 'rate': 0.48, 'voice_index': 3}},
  ],
};

void main() {
  test('phone roster: sorted by lines, with traits, voice and speed', () {
    final cast = CastData.fromJson(phoneRoster);
    expect(cast.characters.map((c) => c.name), ['Elizabeth', 'Mr. Darcy', 'Wickham']);
    expect(cast.coverage, closeTo(.87, .001));
    final lizzie = cast.characters.first;
    expect((lizzie.lines, lizzie.pagesSeen, lizzie.firstPage), (120, 2, 4));
    expect(lizzie.voice, contains('Bella'));
    expect(lizzie.voice, contains('speed 1.09x'));
    expect(cast.characters[1].voice, 'Michael, speed 0.95x');
    expect(cast.characters.last.voice, 'narrator voice'); // no assigned Kokoro voice
    expect(cast.described, 2);
    expect(cast.notDescribed, ['Wickham']);
    expect(cast.unmatchedOverrides, ['Lizzie']);
  });

  test('server roster (Chatterbox styles) parses too', () {
    final cast = CastData.fromJson({
      'engine': 'chatterbox',
      'dialogue': {'total': 10, 'attributed': 4},
      'research': {'status': 'skipped', 'reason': 'no LLM key is configured on this server (MODEL_API_KEY)'},
      'characters': [
        {'name': 'Bob', 'lines': 4, 'evidence_pages': [0], 'voice_gender': 'male', 'traits': {'age': 'elder', 'temperament': 'gruff', 'source': 'user'},
         'voice_style': {'pitch_semitones': -3, 'exaggeration': .3}},
      ],
    });
    expect(cast.characters.single.voice, 'male voice, pitch -3');
    expect(cast.characters.single.traitSource, 'user');
    expect(cast.researchStatus, 'skipped');
    expect(cast.researchReason, contains('MODEL_API_KEY'));
  });

  testWidgets('screen shows coverage, research, warnings and every character', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [castProvider('b').overrideWith((ref) async => CastData.fromJson(phoneRoster))],
      child: const MaterialApp(home: CastScreen(bookId: 'b')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('3 speakers found'), findsOneWidget);
    expect(find.textContaining('87 of 100 spoken lines (87%)'), findsOneWidget);
    expect(find.text('Web research used'), findsOneWidget);
    expect(find.textContaining('Not described: Wickham'), findsOneWidget);
    expect(find.textContaining('Overrides that matched nobody: Lizzie'), findsOneWidget);
    expect(find.byKey(const ValueKey('cast-Elizabeth')), findsOneWidget);
    expect(find.textContaining('120 lines'), findsOneWidget);
    expect(find.textContaining('female, young, cheerful · from web research'), findsOneWidget);
  });

  testWidgets('a book with no cast says so', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [castProvider('b').overrideWith((ref) async => null)],
      child: const MaterialApp(home: CastScreen(bookId: 'b')),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('No cast was recorded'), findsOneWidget);
  });
}
