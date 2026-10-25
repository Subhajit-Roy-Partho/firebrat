/// Voice-relevant traits of a novel character: more than male/female.
/// They come from three places, weakest first: the text itself (pronoun
/// evidence), web research about the book, and the user's own overrides.
const kCharacterAges = ['child', 'young', 'adult', 'elder'];
const kCharacterTemperaments = [
  'calm', 'cheerful', 'stern', 'gruff', 'gentle', 'energetic', 'mysterious',
];

class CharacterTraits {
  final String gender; // male | female | unknown
  final String age; // child | young | adult | elder | unknown
  final String temperament; // see kCharacterTemperaments | unknown
  final String source; // none | web | user

  const CharacterTraits({
    this.gender = 'unknown',
    this.age = 'unknown',
    this.temperament = 'unknown',
    this.source = 'none',
  });

  /// True when age or temperament is known, i.e. there is a delivery style
  /// to apply beyond the plain narrator-or-male/female voice.
  bool get hasStyle => age != 'unknown' || temperament != 'unknown';

  /// Fills this object's unknown fields from [fallback]; known fields win.
  CharacterTraits orElse(CharacterTraits fallback) => CharacterTraits(
        gender: gender != 'unknown' ? gender : fallback.gender,
        age: age != 'unknown' ? age : fallback.age,
        temperament: temperament != 'unknown' ? temperament : fallback.temperament,
        source: source != 'none' ? source : fallback.source,
      );

  /// Accepts anything an LLM might return and keeps only known vocabulary.
  factory CharacterTraits.fromJson(Map<dynamic, dynamic> json, {String source = 'web'}) {
    String pick(Object? v, List<String> allowed) {
      final s = (v ?? '').toString().trim().toLowerCase();
      return allowed.contains(s) ? s : 'unknown';
    }

    return CharacterTraits(
      gender: pick(json['gender'], const ['male', 'female']),
      age: pick(json['age'], kCharacterAges),
      temperament: pick(json['temperament'], kCharacterTemperaments),
      source: source,
    );
  }

  /// Parses "elder gruff female" / "child, cheerful". Returns null when no
  /// word is recognised, so a plain voice name is not mistaken for traits.
  static CharacterTraits? parseWords(Iterable<String> words) {
    var gender = 'unknown', age = 'unknown', temperament = 'unknown';
    var found = false;
    for (final raw in words) {
      final w = raw.trim().toLowerCase();
      if (w == 'male' || w == 'female') {
        gender = w;
        found = true;
      } else if (kCharacterAges.contains(w)) {
        age = w;
        found = true;
      } else if (kCharacterTemperaments.contains(w)) {
        temperament = w;
        found = true;
      }
    }
    return found
        ? CharacterTraits(gender: gender, age: age, temperament: temperament, source: 'user')
        : null;
  }

  Map<String, dynamic> toJson() =>
      {'gender': gender, 'age': age, 'temperament': temperament, 'source': source};

  /// Delivery-speed multiplier: children and energetic characters speak
  /// quicker, elders and gruff or mysterious ones slower.
  double get speedFactor {
    const a = {'child': 1.12, 'young': 1.04, 'adult': 1.0, 'elder': 0.9};
    const t = {
      'energetic': 1.08, 'cheerful': 1.05, 'calm': 0.97, 'gentle': 0.95,
      'stern': 0.95, 'gruff': 0.92, 'mysterious': 0.9,
    };
    return (a[age] ?? 1.0) * (t[temperament] ?? 1.0);
  }

  /// Pitch multiplier for engines that support it (the stock Android TTS).
  double get pitchFactor {
    const a = {'child': 1.25, 'young': 1.08, 'adult': 1.0, 'elder': 0.9};
    const t = {
      'cheerful': 1.04, 'energetic': 1.04, 'gentle': 1.02,
      'stern': 0.95, 'gruff': 0.92, 'mysterious': 0.96,
    };
    return (a[age] ?? 1.0) * (t[temperament] ?? 1.0);
  }
}
