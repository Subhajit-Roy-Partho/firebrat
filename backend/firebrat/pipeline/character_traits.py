"""Voice-relevant traits of a novel character (age, temperament, gender).

Mirrors mobile-Backend/lib/src/novel/character_traits.dart so a book converted
on the server and one converted on the phone are cast the same way. Traits
come from web research or from the operator; they shape delivery (pitch and
expressiveness) on top of the gender-based reference voice.
"""
AGES = ("child", "young", "adult", "elder")
TEMPERAMENTS = ("calm", "cheerful", "stern", "gruff", "gentle", "energetic", "mysterious")
GENDERS = ("male", "female")

_AGE_SEMITONES = {"child": 4, "young": 1, "adult": 0, "elder": -2}
_TEMPERAMENT_SEMITONES = {"cheerful": 1, "energetic": 1, "gruff": -1, "stern": -1, "mysterious": -1}
_TEMPERAMENT_EXAGGERATION = {"energetic": 0.65, "cheerful": 0.6, "mysterious": 0.5, "gentle": 0.4,
                             "stern": 0.35, "calm": 0.3, "gruff": 0.3}


def unknown(source="none"):
    return {"gender": "unknown", "age": "unknown", "temperament": "unknown", "source": source}


def from_json(obj, source="web"):
    """Keep only known vocabulary from whatever an LLM returned."""
    def pick(value, allowed):
        value = str(value or "").strip().lower()
        return value if value in allowed else "unknown"
    obj = obj if isinstance(obj, dict) else {}
    return {"gender": pick(obj.get("gender"), GENDERS), "age": pick(obj.get("age"), AGES),
            "temperament": pick(obj.get("temperament"), TEMPERAMENTS), "source": source}


def parse_spec(spec):
    """'Michael, elder gruff' -> (voice_word_or_None, traits_or_None).

    Words from the vocabulary are traits; any other word is returned as the
    voice name (reserved for parity with the app's Kokoro presets; the
    Chatterbox pipeline selects reference clips by gender, not by name).
    """
    words = [w for w in str(spec or "").replace(",", " ").split() if w]
    traits, found, voice = unknown("user"), False, None
    for word in words:
        w = word.lower()
        if w in GENDERS:
            traits["gender"], found = w, True
        elif w in AGES:
            traits["age"], found = w, True
        elif w in TEMPERAMENTS:
            traits["temperament"], found = w, True
        elif voice is None:
            voice = word
    return voice, (traits if found else None)


def _norm(text):
    return " ".join(str(text).lower().split())


def lookup(name, mapping):
    """Entry of `mapping` that applies to a speaker name: exact ignoring case and
    spacing, else a unique whole-word match ("Mad Hatter" reaches "Hatter" and
    vice versa). Returns (key, value) or (None, None)."""
    n = _norm(name)
    for key in mapping:
        if _norm(key) == n:
            return key, mapping[key]
    words = set(n.split())
    hits = [key for key in mapping
            if _norm(key) and (set(_norm(key).split()) >= words or words >= set(_norm(key).split()))]
    return (hits[0], mapping[hits[0]]) if len(hits) == 1 else (None, None)


def has_style(traits):
    return traits.get("age", "unknown") != "unknown" or traits.get("temperament", "unknown") != "unknown"


def merge(primary, fallback):
    """Known fields of `primary` win; gaps are filled from `fallback`."""
    out = {}
    for key in ("gender", "age", "temperament"):
        out[key] = primary.get(key) if primary.get(key, "unknown") != "unknown" else fallback.get(key, "unknown")
    out["source"] = primary.get("source") if primary.get("source", "none") != "none" else fallback.get("source", "none")
    return out


def style_adjustments(traits):
    """(extra pitch semitones, exaggeration override or None) for a character."""
    semitones = _AGE_SEMITONES.get(traits.get("age"), 0) + _TEMPERAMENT_SEMITONES.get(traits.get("temperament"), 0)
    return semitones, _TEMPERAMENT_EXAGGERATION.get(traits.get("temperament"))
