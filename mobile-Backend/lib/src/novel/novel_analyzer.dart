import '../models/raw_page.dart';
import 'character_traits.dart';

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

  /// Age/temperament (and gender) from web research or the user. Drives the
  /// delivery style on top of the narrator-or-male/female voice.
  final CharacterTraits traits;

  /// How many quoted lines the book attributes to this character.
  final int lines;
  const NovelCharacter(this.id, this.name, this.evidencePages, this.style,
    {this.voiceGender = 'unknown', this.genderEvidence = const [], this.voiceOverride,
     this.traits = const CharacterTraits(), this.lines = 0});

  NovelCharacter copyWith({CharacterVoiceStyle? style, String? voiceGender,
      List<String>? genderEvidence, CharacterTraits? traits}) =>
    NovelCharacter(id, name, evidencePages, style ?? this.style,
      voiceGender: voiceGender ?? this.voiceGender,
      genderEvidence: genderEvidence ?? this.genderEvidence,
      voiceOverride: voiceOverride, traits: traits ?? this.traits, lines: lines);
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'evidence_pages': evidencePages,
    'style': style.toJson(),
    'voice_gender': voiceGender, 'gender_evidence': genderEvidence,
    'voice_override': voiceOverride,
    'traits': traits.toJson(),
    'lines': lines,
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

  /// User override names that matched no speaker found in the book (usually a
  /// typo, or a name the book never tags as speaking).
  final List<String> unmatchedOverrides;

  /// Every quoted line in the book, and how many of them a named speaker was
  /// found for. The rest are read by the narrator. This is the honest measure of
  /// how much of the dialogue the casting actually covers.
  final int dialogueTotal;
  final int dialogueAttributed;
  const NovelBookPlan(this.characters, this.scannedPages,
      {this.unmatchedOverrides = const [], this.dialogueTotal = 0, this.dialogueAttributed = 0});

  static final _dialogue = RegExp(r'“[^”\n]+”|"[^"\n]+"');
  static const _verbs =
      r'(?:said|asked|replied|answered|whispered|shouted|cried|exclaimed|murmured|called|remarked|continued|added)';
  // An optional title ('Mr. Darcy', 'Lady Catherine', 'Colonel Fitzwilliam') so
  // the speaker is the whole name, not just 'Mr'.
  static const _name =
      r'(?:(?:Mr|Mrs|Miss|Ms|Dr|Lady|Lord|Sir|Colonel|Captain|Major|Professor|Reverend|Uncle|Aunt)\.?\s+)?[A-Z][a-z]+(?:[ -][A-Z][a-z]+){0,2}';
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
    'Mr', 'Mrs', 'Miss', 'Ms', 'Dr', 'Lady', 'Lord', 'Sir',
    'Colonel', 'Captain', 'Major', 'Professor', 'Reverend', 'Uncle', 'Aunt',
  };

  /// The quoted-speech pattern shared with the expressive casting module.
  static RegExp get dialoguePattern => _dialogue;

  /// Speaker named by an adjacent dialogue tag ('said Alice'), or null. Public
  /// so the casting fallback uses exactly the same regex rules as novel mode.
  static String? taggedSpeaker(String text, RegExpMatch match) => _speaker(text, match);

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
    final lineCounts = <String, int>{};
    var total = 0, attributed = 0;
    for (final page in pages) {
      for (final quote in _dialogue.allMatches(page.text)) {
        total++;
        final name = _speaker(page.text, quote);
        if (name != null) {
          attributed++;
          lineCounts[name] = (lineCounts[name] ?? 0) + 1;
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
          lines: lineCounts[name] ?? 0,
          voiceOverride: _splitOverride(voiceOverrides[matchOverrideKey(name, voiceOverrides)]).voice,
          traits: _splitOverride(voiceOverrides[matchOverrideKey(name, voiceOverrides)]).traits ?? const CharacterTraits(),
        ),
      );
    }
    final matched = <String>{};
    for (final name in names) {
      final key = matchOverrideKey(name, voiceOverrides);
      if (key != null) matched.add(key);
    }
    final plan = NovelBookPlan(characters, pages.length,
        unmatchedOverrides: [for (final k in voiceOverrides.keys) if (!matched.contains(k)) k],
        dialogueTotal: total, dialogueAttributed: attributed);
    // User-supplied traits apply immediately; web research layers beneath them.
    return plan.withResearch(const {});
  }

  static String _norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// The override key that applies to [name]: an exact match ignoring case and
  /// spacing, otherwise a unique whole-word match, so "Mad Hatter" reaches the
  /// speaker the book tags as "Hatter" (and vice versa). Null when none/ambiguous.
  static String? matchOverrideKey(String name, Map<String, String> overrides) {
    final n = _norm(name);
    for (final k in overrides.keys) {
      if (_norm(k) == n) return k;
    }
    final nw = n.split(' ').toSet();
    final hits = [
      for (final k in overrides.keys)
        if (_norm(k).isNotEmpty &&
            (_norm(k).split(' ').toSet().containsAll(nw) ||
                nw.containsAll(_norm(k).split(' ').toSet())))
          k,
    ];
    return hits.length == 1 ? hits.single : null;
  }

  /// "Michael, elder, gruff" -> voice "Michael" + traits. Words from the
  /// trait vocabulary are traits; the first remaining word is the voice.
  static ({String? voice, CharacterTraits? traits}) _splitOverride(String? raw) {
    if (raw == null || raw.trim().isEmpty) return (voice: null, traits: null);
    final words = raw.split(RegExp(r'[,\s]+')).where((w) => w.isNotEmpty).toList();
    final traits = CharacterTraits.parseWords(words);
    final voice = words.where((w) => CharacterTraits.parseWords([w]) == null).firstOrNull;
    return (voice: voice, traits: traits);
  }

  /// Merges researched [traits] (keyed by character name) under whatever the
  /// user already set, then re-derives each character's delivery style.
  /// Researched gender only fills in an `unknown` voice gender.
  NovelBookPlan withResearch(Map<String, CharacterTraits> researched) {
    final out = <NovelCharacter>[];
    for (final c in characters) {
      final merged = c.traits.orElse(researched[c.name] ?? const CharacterTraits());
      var gender = c.voiceGender;
      var evidence = c.genderEvidence;
      if (gender == 'unknown' && merged.gender != 'unknown') {
        gender = merged.gender;
        evidence = [...evidence, merged.source == 'user'
            ? 'set by the user' : merged.source == 'local_book'
            ? 'local model evidence from this book' : 'web research about this book'];
      }
      out.add(c.copyWith(
        traits: merged,
        voiceGender: gender,
        genderEvidence: evidence,
        style: merged.hasStyle ? CharacterVoiceStyle(
          (c.style.pitch * merged.pitchFactor).clamp(0.6, 1.4).toDouble(),
          (c.style.rate * merged.speedFactor).clamp(0.3, 0.75).toDouble(),
          c.style.voiceIndex,
        ) : c.style,
      ));
    }
    return NovelBookPlan(out, scannedPages,
        unmatchedOverrides: unmatchedOverrides, dialogueTotal: dialogueTotal, dialogueAttributed: dialogueAttributed);
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
    'dialogue': {'total': dialogueTotal, 'attributed': dialogueAttributed},
    if (unmatchedOverrides.isNotEmpty) 'unmatched_overrides': unmatchedOverrides,
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
