/// Data shapes of the expressive (multi-voice) casting pipeline. They mirror
/// the server's `cast.json` (backend/firebrat_cast/cast.py) so every client
/// reads the same manifest `cast` key and the same utterance records.
library;

const kCastEmotions = [
  'neutral', 'joy', 'sadness', 'anger', 'fear', 'surprise', 'tenderness',
  'sarcasm', 'disgust', 'awe', 'suspense',
];
const kCastGenders = ['male', 'female', 'unknown'];
const kCastAges = ['child', 'young', 'adult', 'elder'];
const kCastAccents = ['british', 'american', 'other'];
const kNarratorId = 'narrator';

/// One quote or narration span of a page, keyed by (page, idx) exactly like
/// the server's segmenter so casting and narration agree on every span.
class CastSeg {
  final int page;
  final int idx;
  final bool isQuote;
  final String text;
  const CastSeg(this.page, this.idx, this.isQuote, this.text);
}

class CastCharacter {
  final String id;
  final String name;
  final List<String> aliases;
  final String gender;
  final String age;
  final String temperament;
  final String accent;
  final String description;
  final int importance;
  const CastCharacter({
    required this.id,
    required this.name,
    this.aliases = const [],
    this.gender = 'unknown',
    this.age = 'adult',
    this.temperament = '',
    this.accent = 'british',
    this.description = '',
    this.importance = 1,
  });

  CastCharacter copyWith({String? id, List<String>? aliases, String? gender, String? age, String? temperament,
          String? accent, String? description, int? importance}) =>
      CastCharacter(
        id: id ?? this.id,
        name: name,
        aliases: aliases ?? this.aliases,
        gender: gender ?? this.gender,
        age: age ?? this.age,
        temperament: temperament ?? this.temperament,
        accent: accent ?? this.accent,
        description: description ?? this.description,
        importance: importance ?? this.importance,
      );

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'aliases': aliases, 'gender': gender, 'age': age,
        'temperament': temperament, 'accent': accent, 'description': description, 'importance': importance,
      };

  factory CastCharacter.fromJson(Map j) => CastCharacter(
        id: j['id'].toString(),
        name: j['name'].toString(),
        aliases: [for (final a in (j['aliases'] as List? ?? const [])) a.toString()],
        gender: j['gender']?.toString() ?? 'unknown',
        age: j['age']?.toString() ?? 'adult',
        temperament: j['temperament']?.toString() ?? '',
        accent: j['accent']?.toString() ?? 'british',
        description: j['description']?.toString() ?? '',
        importance: (j['importance'] as num?)?.toInt() ?? 1,
      );
}

class CastUtterance {
  final int page;
  final int idx;
  final String speaker; // character id or 'narrator'
  final String emotion;
  final String delivery;
  const CastUtterance(this.page, this.idx, this.speaker, this.emotion, this.delivery);
  Map<String, dynamic> toJson() => {
        'page': page, 'idx': idx, 'speaker': speaker, 'emotion': emotion, 'delivery': delivery,
      };
  factory CastUtterance.fromJson(Map j) => CastUtterance(
        (j['page'] as num).toInt(), (j['idx'] as num).toInt(), j['speaker'].toString(),
        j['emotion']?.toString() ?? 'neutral', j['delivery']?.toString() ?? '');
}

class CastNarrator {
  final String description;
  final String accent;
  const CastNarrator({this.description = '', this.accent = 'british'});
  Map<String, dynamic> toJson() => {'description': description, 'accent': accent};
}

/// What the casting pass produced, plus an honest account of how.
class CastResult {
  final CastNarrator narrator;
  final List<CastCharacter> characters;
  final List<CastUtterance> utterances;
  final Map<int, ({String emotion, String delivery})> pageMood;
  final String llmModel;

  /// Quote counts: total, decided by the LLM, decided by the regex fallback.
  final int quotesTotal;
  final int quotesByLlm;
  final int quotesByRegex;
  final int llmCalls;
  final List<String> notes;
  const CastResult({
    required this.narrator,
    required this.characters,
    required this.utterances,
    required this.pageMood,
    required this.llmModel,
    this.quotesTotal = 0,
    this.quotesByLlm = 0,
    this.quotesByRegex = 0,
    this.llmCalls = 0,
    this.notes = const [],
  });

  Map<String, dynamic> toJson() => {
        'llm': {'backend': 'on_device_llama_cpp', 'model': llmModel},
        'narrator': narrator.toJson(),
        'characters': [for (final c in characters) c.toJson()],
        'utterances': [for (final u in utterances) u.toJson()],
        'page_mood': {for (final e in pageMood.entries) '${e.key}': {'emotion': e.value.emotion, 'delivery': e.value.delivery}},
        'stats': {
          'quotes_total': quotesTotal, 'quotes_by_llm': quotesByLlm, 'quotes_by_regex': quotesByRegex,
          'llm_calls': llmCalls,
        },
        'notes': notes,
      };

  factory CastResult.fromJson(Map j) {
    final stats = (j['stats'] as Map?) ?? const {};
    final llm = (j['llm'] as Map?) ?? const {};
    final mood = (j['page_mood'] as Map?) ?? const {};
    final narr = (j['narrator'] as Map?) ?? const {};
    return CastResult(
      narrator: CastNarrator(description: narr['description']?.toString() ?? '', accent: narr['accent']?.toString() ?? 'british'),
      characters: [for (final c in (j['characters'] as List? ?? const [])) CastCharacter.fromJson(c as Map)],
      utterances: [for (final u in (j['utterances'] as List? ?? const [])) CastUtterance.fromJson(u as Map)],
      pageMood: {
        for (final e in mood.entries)
          int.parse(e.key.toString()): (emotion: (e.value as Map)['emotion'].toString(), delivery: (e.value as Map)['delivery'].toString())
      },
      llmModel: llm['model']?.toString() ?? '',
      quotesTotal: (stats['quotes_total'] as num?)?.toInt() ?? 0,
      quotesByLlm: (stats['quotes_by_llm'] as num?)?.toInt() ?? 0,
      quotesByRegex: (stats['quotes_by_regex'] as num?)?.toInt() ?? 0,
      llmCalls: (stats['llm_calls'] as num?)?.toInt() ?? 0,
      notes: [for (final n in (j['notes'] as List? ?? const [])) n.toString()],
    );
  }
}
