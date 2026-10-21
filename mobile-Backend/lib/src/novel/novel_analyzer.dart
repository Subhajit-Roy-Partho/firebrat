import '../models/raw_page.dart';

/// Stable, bounded stock TTS settings. These distinguish delivery, not cloned
/// actors; voices are selected only from the engine's installed offline voices.
class CharacterVoiceStyle {
  final double pitch;
  final double rate;
  final int voiceIndex;
  const CharacterVoiceStyle(this.pitch, this.rate, this.voiceIndex);
  Map<String, dynamic> toJson() => {
    'pitch': pitch,
    'rate': rate,
    'voice_index': voiceIndex,
  };
}

class NovelCharacter {
  final String id;
  final String name;
  final List<int> evidencePages;
  final CharacterVoiceStyle style;
  final String voiceGender;
  final List<String> genderEvidence;
  final String? voiceOverride;
  const NovelCharacter(this.id, this.name, this.evidencePages, this.style,
    {this.voiceGender = 'unknown', this.genderEvidence = const [], this.voiceOverride});
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'evidence_pages': evidencePages,
    'style': style.toJson(),
    'voice_gender': voiceGender, 'gender_evidence': genderEvidence,
    'voice_override': voiceOverride,
  };
}

class NovelUtterance {
  final String text;
  final NovelCharacter? character;
  const NovelUtterance(this.text, this.character);
  String get characterId => character?.id ?? 'narrator';
  CharacterVoiceStyle get style =>
      character?.style ?? const CharacterVoiceStyle(1, 0.48, 0);
}

/// Scans every extracted page before assigning any voice. Only explicit named
/// speech tags are evidence: pronouns, alternating speakers, and names merely
/// mentioned in the story never determine who speaks. Uncertain dialogue uses
/// the narrator. Text is retained verbatim, including punctuation and spaces.
class NovelBookPlan {
  final List<NovelCharacter> characters;
  final int scannedPages;
  const NovelBookPlan(this.characters, this.scannedPages);

  static final _dialogue = RegExp(r'“[^”\n]+”|"[^"\n]+"');
  static const _verbs =
      r'(?:said|asked|replied|answered|whispered|shouted|cried|exclaimed|murmured|called|remarked|continued|added)';
  static const _name = r'[A-Z][a-z]+(?:[ -][A-Z][a-z]+){0,2}';
  static final _after = RegExp(
    '^\\s*[,;:—-]?\\s*(?:($_verbs)\\s+($_name)|($_name)\\s+($_verbs))(?=[\\s.,;:!?]|\$)',
  );
  static final _before = RegExp(
    '(?:($_name)\\s+$_verbs|$_verbs\\s+($_name))\\s*[:,—-]?\\s*\$',
  );
  static final _nonNames = {
    'He',
    'She',
    'They',
    'It',
    'I',
    'We',
    'You',
    'The',
    'Then',
    'Someone',
    'Nobody',
  };

  static String? _speaker(String text, RegExpMatch match) {
    // The tag must be adjacent to this quote, within the same paragraph.
    final tail = text.substring(match.end).split('\n').first;
    final after = _after.firstMatch(tail);
    String? name = after?.group(2) ?? after?.group(3);
    if (name == null) {
      final head = text.substring(0, match.start).split('\n').last;
      final before = _before.firstMatch(head);
      name = before?.group(1) ?? before?.group(2);
    }
    if (name == null || _nonNames.contains(name)) return null;
    return name;
  }

  factory NovelBookPlan.analyze(List<RawPage> pages, {Map<String, String> voiceOverrides = const {}}) {
    final evidence = <String, Set<int>>{};
    for (final page in pages) {
      for (final quote in _dialogue.allMatches(page.text)) {
        final name = _speaker(page.text, quote);
        if (name != null) {
          evidence.putIfAbsent(name, () => {}).add(page.pageIdx);
        }
      }
    }
    // Alphabetic allocation is independent of the chunking and encounter order.
    final names = evidence.keys.toList()..sort();
    final characters = <NovelCharacter>[];
    for (var i = 0; i < names.length; i++) {
      final name = names[i];
      final inferred = inferCharacterVoiceGender(name, names, pages);
      characters.add(
        NovelCharacter(
          'character_${name.toLowerCase().replaceAll(RegExp('[^a-z]+'), '_')}',
          name,
          evidence[name]!.toList()..sort(),
          CharacterVoiceStyle(
            [0.90, 1.08, 0.97, 1.15, 0.84][i % 5],
            [0.46, 0.50, 0.44, 0.48][i % 4],
            i + 1,
          ),
          voiceGender: inferred.gender, genderEvidence: inferred.evidence,
          voiceOverride: voiceOverrides[name],
        ),
      );
    }
    return NovelBookPlan(characters, pages.length);
  }

  List<NovelUtterance> split(String text) {
    final result = <NovelUtterance>[];
    var cursor = 0;
    for (final quote in _dialogue.allMatches(text)) {
      if (quote.start > cursor) {
        result.add(NovelUtterance(text.substring(cursor, quote.start), null));
      }
      final name = _speaker(text, quote);
      NovelCharacter? speaker;
      for (final character in characters) {
        if (character.name == name) {
          speaker = character;
          break;
        }
      }
      result.add(NovelUtterance(quote.group(0)!, speaker));
      cursor = quote.end;
    }
    if (cursor < text.length) {
      result.add(NovelUtterance(text.substring(cursor), null));
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
    'mode': 'novel',
    'scanned_pages': scannedPages,
    'attribution': 'explicit_named_speech_tags',
    'unknown_speaker': 'narrator',
    'characters': characters.map((c) => c.toJson()).toList(),
  };
}

/// Platform getVoices results are filtered to locally installed voices only.
/// Sorting makes allocation stable even when the platform changes list order.
/// Returns null when the platform cannot prove a voice is installed offline;
/// the caller must retain its verified offline narrator voice and apply style.
Map<String, String>? resolveOfflineCharacterVoice(
  NovelUtterance utterance,
  List<Map<Object?, Object?>> voices, {
  required String locale,
}) {
  final candidates =
      voices
          .where((v) {
            final network = v['network_required'] ?? v['networkRequired'];
            return (network == false ||
                    network == 'false' ||
                    network == 0 ||
                    network == '0') &&
                !v['features'].toString().contains('notInstalled') &&
                v['locale'] == locale &&
                v['name'] is String;
          })
          .map(
            (v) => <String, String>{
              'name': v['name'] as String,
              'locale': v['locale'] as String,
            },
          )
          .toList()
        ..sort((a, b) => a['name']!.compareTo(b['name']!));
  if (candidates.isEmpty) return null;
  return candidates[utterance.style.voiceIndex % candidates.length];
}

/// Conservative voice casting hint from narration, never a name-based gender guess.
/// A single named character in a narrative sentence may have explicit he/she or
/// reflexive pronoun evidence. Conflicting evidence leaves casting unknown.
({String gender, List<String> evidence}) inferCharacterVoiceGender(
    String name, List<String> cast, List<RawPage> pages) {
  final found = <String>{};
  final evidence = <String>[];
  for (final page in pages) {
    final narration = page.text.replaceAll(RegExp(r'“[^”]*”|"[^"\n]*"'), ' ');
    for (final match in RegExp(r'[^.!?\n]+').allMatches(narration)) {
      final sentence = match.group(0)!;
      final named = cast.where((n) => RegExp('\\b${RegExp.escape(n)}\\b').hasMatch(sentence)).toList();
      if (named.length != 1 || named.first != name) continue;
      final afterName = sentence.substring(sentence.indexOf(name) + name.length);
      for (final entry in {'male': r'^\s+\w+(?:\s+\w+){0,2}\s+(?:(?:as|while)\s+he|himself)\b|^\s+(?:was|is)\s+(?:a\s+)?(?:man|boy|male)\b', 'female': r'^\s+\w+(?:\s+\w+){0,2}\s+(?:(?:as|while)\s+she|herself)\b|^\s+(?:was|is)\s+(?:a\s+)?(?:woman|girl|female)\b'}.entries) {
        if (RegExp(entry.value, caseSensitive: false).hasMatch(afterName)) {
          found.add(entry.key);
          evidence.add('page ${page.pageIdx + 1}: ${entry.key} pronoun in single-character narration');
        }
      }
    }
  }
  return (gender: found.length == 1 ? found.single : 'unknown', evidence: evidence.toSet().toList());
}
