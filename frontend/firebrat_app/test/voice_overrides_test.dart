import 'package:firebrat_app/screens/conversion_settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts voices, traits, or both; rejects typos', () {
    expect(parseVoiceOverrides('Alice=Nicole'), {'Alice': 'Nicole'});
    expect(parseVoiceOverrides('Alice=child cheerful\nMad Hatter=Michael, elder, gruff\nQueen of Hearts=female stern'), {
      'Alice': 'child, cheerful',
      'Mad Hatter': 'Michael, elder, gruff',
      'Queen of Hearts': 'female, stern',
    });
    expect(parseVoiceOverrides(''), isEmpty);
    expect(parseVoiceOverrides('Bob=grumpy'), isNull);
    expect(parseVoiceOverrides('Bob=Michael Adam'), isNull); // two voices
    expect(parseVoiceOverrides('no equals'), isNull);
  });
}
