/// Prompts for the on-device casting passes. Deliberately short (the on-device
/// context is 4096 tokens, shared with the passage) and answer-format first so
/// 1-4B models stay on format. Bump [kCastPromptVersion] when changing them:
/// it is part of every cache key.
library;

import 'cast_models.dart';

const kCastPromptVersion = 'v1';

const kRosterSystem = '''You are casting a multi-voice audiobook. Read the excerpt and list every character who speaks or is clearly addressed.
Merge aliases into ONE person ("Lizzy" = "Elizabeth Bennet", "Mr. Darcy" = "Fitzwilliam Darcy"). Use only people in the text; skip groups and the narrator.
gender is male, female or unknown. age is child, young, adult or elder. accent is british, american or other (judge from setting and speech). temperament is 2-3 words (e.g. "proud, reserved"). lines is a rough count of their quoted lines in the excerpt.
Reply with ONE JSON object and nothing else:
{"narrator":{"accent":"british"},"characters":[{"name":"","aliases":[],"gender":"","age":"","temperament":"","accent":"","lines":0}]}''';

String buildRosterUser(String windowText) =>
    'Excerpt (novel prose; "..." marks dialogue):\n\n$windowText\n\nJSON only.';

const kAttributionSystem = '''You attribute dialogue for a multi-voice audiobook. For each numbered QUOTE decide who speaks it and how.
Use the dialogue tags, the context before/after, and conversation flow (in alternating dialogue an untagged line is usually the other participant). Use "n" only when the speaker is truly unknowable.
emotion MUST be one of: neutral, joy, sadness, anger, fear, surprise, tenderness, sarcasm, disgust, awe, suspense.
delivery is a short stage direction (max 5 words, e.g. "whispered, trembling") or "".
Reply with ONE JSON object and nothing else, one row per quote number:
{"utterances":[[0,"c1","joy","excited"],[1,"c2","neutral",""]]}''';

/// Compact one-line roster: `c1=Alice (female, child); ... ; n=narrator`.
String rosterLine(List<CastCharacter> characters) {
  final parts = <String>[];
  for (var i = 0; i < characters.length; i++) {
    final c = characters[i];
    final who = [if (c.gender != 'unknown') c.gender, if (c.age != 'adult') c.age].join(', ');
    parts.add('c${i + 1}=${c.name}${who.isEmpty ? '' : ' ($who)'}');
  }
  parts.add('n=narrator');
  return parts.join('; ');
}

String _oneLine(String text, int limit) {
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed.length <= limit ? collapsed : '${collapsed.substring(0, limit)}...';
}

class QuoteItem {
  final int number;
  final CastSeg seg;
  final String before;
  final String after;
  const QuoteItem(this.number, this.seg, this.before, this.after);
}

String buildAttributionUser(int chunkNo, List<QuoteItem> items, List<CastCharacter> roster, List<String> recent,
    {List<int>? only}) {
  final lines = <String>[
    'Chunk $chunkNo. ${only == null ? 'Attribute EVERY numbered quote.' : 'Attribute ONLY quotes ${only.join(', ')}.'}',
    'Roster: ${rosterLine(roster)}',
    'Recent speakers: ${recent.isEmpty ? 'none' : recent.join(', ')}',
    'Quotes:',
  ];
  for (final it in items) {
    if (only != null && !only.contains(it.number)) continue;
    lines.add('[${it.number}] ${_oneLine(it.seg.text, 260)}');
    lines.add('   before: ${_oneLine(it.before, 100)}');
    lines.add('   after: ${_oneLine(it.after, 100)}');
  }
  return lines.join('\n');
}

String attributionRepairSuffix(List<int> missing) =>
    '\nYour previous reply was unusable or incomplete. Reply again with exactly {"utterances":[[number,speaker,emotion,delivery],...]} '
    'covering quotes ${missing.join(', ')}.';
