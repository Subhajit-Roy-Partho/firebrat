"""Natural-reading text normalisation for TTS input (pure stdlib).

Every rewrite preserves content: digits/abbreviations/symbols become spoken
words, dash/ellipsis runs become comma pauses. Nothing is deleted except
abbreviation periods and separator punctuation (replaced, never dropped).

Roman-numeral choice: headings like "Chapter IV" become "Chapter four"
(spoken cardinal words, not bare digits) so output is directly speakable.
Only numerals after heading keywords (chapter/part/...) or alone on a line
are converted, so words like "I" or "mix" are never touched.

Year rule: 4-digit 1100-2099 read as years ("1999" -> "nineteen
ninety-nine", "2005" -> "two thousand five", "2015" -> "twenty fifteen");
other magnitudes are plain cardinals. A spaced hyphen ("5 - 3") is treated
as a prose pause, not subtraction.
"""

from __future__ import annotations

import re

_ONES = [
    "zero", "one", "two", "three", "four", "five", "six", "seven",
    "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
    "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
]
_TENS = ["", "", "twenty", "thirty", "forty", "fifty",
         "sixty", "seventy", "eighty", "ninety"]
_ORD_ONES = {1: "first", 2: "second", 3: "third", 5: "fifth",
             8: "eighth", 9: "ninth", 12: "twelfth"}
_ORD_TENS = {20: "twentieth", 30: "thirtieth", 40: "fortieth",
             50: "fiftieth", 60: "sixtieth", 70: "seventieth",
             80: "eightieth", 90: "ninetieth"}
_DECADES = {10: "tens", 20: "twenties", 30: "thirties", 40: "forties",
            50: "fifties", 60: "sixties", 70: "seventies",
            80: "eighties", 90: "nineties"}
_SCALES = [(10**12, "trillion"), (10**9, "billion"),
           (10**6, "million"), (10**3, "thousand")]


def _num_words(n: int) -> str:
    """Cardinal words for any non-negative int (e.g. 42 -> "forty-two")."""
    if n < 0:
        return "minus " + _num_words(-n)
    if n < 20:
        return _ONES[n]
    if n < 100:
        q, r = divmod(n, 10)
        return _TENS[q] if r == 0 else f"{_TENS[q]}-{_ONES[r]}"
    if n < 1000:
        q, r = divmod(n, 100)
        head = f"{_ONES[q]} hundred"
        return head if r == 0 else f"{head} {_num_words(r)}"
    for scale, name in _SCALES:
        if n >= scale:
            q, r = divmod(n, scale)
            head = f"{_num_words(q)} {name}"
            return head if r == 0 else f"{head} {_num_words(r)}"
    raise ValueError(f"number out of range: {n}")  # unreachable


def _ordinal_words(n: int) -> str:
    """Ordinal words (e.g. 22 -> "twenty-second", 100 -> "one hundredth")."""
    if n in _ORD_ONES:
        return _ORD_ONES[n]
    if n in _ORD_TENS:
        return _ORD_TENS[n]
    if n < 20:
        return _ONES[n] + "th"
    if n < 100:
        q, r = divmod(n, 10)
        return f"{_TENS[q]}-{_ordinal_words(r)}"
    if n < 1000:
        q, r = divmod(n, 100)
        head = f"{_ONES[q]} hundred"
        return head + "th" if r == 0 else f"{head} {_ordinal_words(r)}"
    for scale, name in _SCALES:
        if n >= scale:
            q, r = divmod(n, scale)
            head = f"{_num_words(q)} {name}"
            return head + "th" if r == 0 else f"{head} {_ordinal_words(r)}"
    raise ValueError(f"number out of range: {n}")  # unreachable


def _year_tail(lo: int) -> str:
    return "oh " + _ONES[lo] if lo < 10 else _num_words(lo)


def _year_words(n: int) -> str:
    """Year pronunciation for 1100-2099, else plain cardinal."""
    if n < 1100 or n > 2099:
        return _num_words(n)
    if n == 2000:
        return "two thousand"
    if 2001 <= n <= 2009:
        return f"two thousand {_num_words(n - 2000)}"
    hi, lo = divmod(n, 100)
    if lo == 0:
        return f"{_num_words(hi)} hundred"
    return f"{_num_words(hi)} {_year_tail(lo)}"


_ROMAN_RE = re.compile(
    r"^M{0,4}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$")
_ROMAN_VAL = {"I": 1, "V": 5, "X": 10, "L": 50,
              "C": 100, "D": 500, "M": 1000}


def _roman_to_int(s: str) -> int:
    """Strict roman -> int; raises ValueError on invalid input (incl. "")."""
    if not s or not _ROMAN_RE.match(s):
        raise ValueError(f"not a roman numeral: {s!r}")
    total, prev = 0, 0
    for ch in reversed(s):
        val = _ROMAN_VAL[ch]
        if val < prev:
            total -= val
        else:
            total += val
            prev = val
    return total


_HEADING_RE = re.compile(
    r"\b(chapter|part|section|book|act|scene|volume|canto|phase|stage)s?"
    r"\s+([IVXLCDM]+)\b",
    re.IGNORECASE,
)
_STANDALONE_ROMAN_RE = re.compile(r"(?m)^\s*([IVXLCDM]{1,8})\s*$")


def _expand_roman_headings(text: str) -> str:
    """'Chapter IV' -> 'Chapter four'; lone-numeral lines likewise (<=100)."""
    def _head(m: re.Match[str]) -> str:
        try:
            val = _roman_to_int(m.group(2).upper())
        except ValueError:
            return m.group(0)
        return f"{m.group(1)} {_num_words(val)}"

    def _alone(m: re.Match[str]) -> str:
        token = m.group(1)
        if token == "I":  # pronoun, not a numeral
            return m.group(0)
        try:
            val = _roman_to_int(token)
        except ValueError:
            return m.group(0)
        return _num_words(val) if val <= 100 else m.group(0)

    text = _HEADING_RE.sub(_head, text)
    return _STANDALONE_ROMAN_RE.sub(_alone, text)


# Titles/ranks are expanded only as whole, capitalised tokens ("Dr", "Dr.", "St."), never as a
# prefix of a longer word ("Drew", "Stop", "Revived", "Colonel" must stay as written).
_TITLES = {
    "Mrs": "Missus", "Mr": "Mister", "Ms": "Miss", "Dr": "Doctor", "St": "Saint",
    "Prof": "Professor", "Rev": "Reverend", "Gen": "General", "Col": "Colonel",
    "Capt": "Captain", "Lt": "Lieutenant", "Sgt": "Sergeant", "Hon": "Honorable",
    "Jr": "Junior", "Sr": "Senior",
}
_TITLE_RE = re.compile(r"(?<![A-Za-z])(" + "|".join(sorted(_TITLES, key=len, reverse=True)) + r")(?![A-Za-z])\.?")
# Case-insensitive, whole-word only.
_ABBREV = [
    (r"(?<![A-Za-z])No\.(?=\s*\d)", "Number"),  # "No. 5"; bare "no" is a word
    (r"(?<![A-Za-z])vs\.?(?![A-Za-z])", "versus"),
    (r"(?<![A-Za-z])etc\.?(?![A-Za-z])", "etcetera"),
    (r"\be\.g\.", "for example"),
    (r"\bi\.e\.", "that is"),
    (r"\ba\.m\.", "A M"),
    (r"\bp\.m\.", "P M"),
]


def _expand_abbreviations(text: str) -> str:
    text = _TITLE_RE.sub(lambda m: _TITLES[m.group(1)], text)
    for pattern, repl in _ABBREV:
        text = re.sub(pattern, repl, text, flags=re.IGNORECASE)
    return text


_CURRENCY = {"$": ("dollar", "dollars", "cent", "cents"),
             "\u00a3": ("pound", "pounds", "penny", "pence"),
             "\u20ac": ("euro", "euros", "cent", "cents")}
_MONEY_RE = re.compile(r"([$£€])\s?(\d[\d,]*)(?:\.(\d{1,2}))?")
_PCT_RE = re.compile(r"\b(\d[\d,]*)(?:\.(\d+))?\s?%")
_DEC_RE = re.compile(r"\b\d[\d,]*\.\d+\b")
_ORD_RE = re.compile(r"\b(\d+)(st|nd|rd|th)\b", re.IGNORECASE)
_YEAR_RE = re.compile(r"\b(1[1-9]\d{2}|20\d{2})(s)?\b")
_INT_RE = re.compile(r"\b\d[\d,]*\b")


def _digits_to_words(frac: str) -> str:
    return " ".join(_ONES[int(d)] for d in frac)


def _money_sub(m: re.Match[str]) -> str:
    major_s, major_p, minor_s, minor_p = _CURRENCY[m.group(1)]
    whole = int(m.group(2).replace(",", ""))
    major = f"{_num_words(whole)} {major_s if whole == 1 else major_p}"
    frac = m.group(3)
    if not frac:
        return major
    cents = int(frac.ljust(2, "0")[:2])
    if cents == 0:
        return major
    minor = f"{_num_words(cents)} {minor_s if cents == 1 else minor_p}"
    return f"{major} and {minor}"


def _pct_sub(m: re.Match[str]) -> str:
    whole = int(m.group(1).replace(",", ""))
    words = _num_words(whole)
    if m.group(2):
        words += " point " + _digits_to_words(m.group(2))
    return words + " percent"


def _dec_sub(m: re.Match[str]) -> str:
    intpart, frac = m.group(0).split(".")
    return f"{_num_words(int(intpart.replace(',', '')))} point {_digits_to_words(frac)}"


def _year_sub(m: re.Match[str]) -> str:
    n = int(m.group(1))
    if m.group(2) and m.group(1).endswith("0") and not m.group(1).endswith("00"):
        hi, lo = divmod(n, 100)  # "1990s" -> "nineteen nineties"
        return f"{_num_words(hi)} {_DECADES[lo]}"
    words = _year_words(n)
    if m.group(2) and words.endswith(("hundred", "thousand")):
        return words + "s"
    return words


def _expand_numbers(text: str) -> str:
    text = re.sub(r"-(?=\d)", "minus ", text)  # "-5" (before digits vanish)
    text = _MONEY_RE.sub(_money_sub, text)
    text = _PCT_RE.sub(_pct_sub, text)
    text = _DEC_RE.sub(_dec_sub, text)
    text = _ORD_RE.sub(lambda m: _ordinal_words(int(m.group(1))), text)
    text = _YEAR_RE.sub(_year_sub, text)
    text = _INT_RE.sub(lambda m: _num_words(int(m.group(0).replace(",", ""))), text)
    return text


def _straighten_quotes(text: str) -> str:
    return (text.replace("“", '"').replace("”", '"')
            .replace("‘", "'").replace("’", "'")
            .replace("«", '"').replace("»", '"'))


def _punct_to_pauses(text: str) -> str:
    """Ellipses and dashes (em/en/double/spaced hyphen) become comma pauses.
    An en dash between digits is a range ("1940-1945" -> "1940 to 1945")."""
    text = text.replace("…", ", ")
    text = re.sub(r"\.{2,}", ", ", text)
    text = re.sub(r"\s*--+\s*", ", ", text)
    text = re.sub(r"(?<=\d)\s*–\s*(?=\d)", " to ", text)
    text = text.replace("—", ", ").replace("–", ", ")
    text = re.sub(r"\s+-\s+", ", ", text)
    return text


def _expand_symbols(text: str) -> str:
    text = text.replace("+", " plus ")
    text = re.sub(r"\s*&\s*", " and ", text)
    text = re.sub(r"(?<=[A-Za-z])/(?=[A-Za-z])", " or ", text)  # his/her
    text = text.replace("/", " slash ")
    text = text.replace("@", " at ").replace("=", " equals ")
    text = re.sub(r"#(?=\d)", "number ", text)
    text = text.replace("#", " hash ")
    text = re.sub(r"(?<=\d)\s*\*\s*(?=\d)", " times ", text)
    text = text.replace("*", " star ")
    text = text.replace("%", " percent ")
    for sym, name in (("$", " dollars "), ("£", " pounds "), ("€", " euros ")):
        text = text.replace(sym, name)
    return text.replace("_", " ")


def normalize_text(text: str) -> str:
    """Full pipeline: quotes -> abbreviations -> roman -> numbers -> pauses.

    Never drops words; collapses whitespace and tidies space before
    punctuation / repeated commas at the end.
    """
    if not text:
        return ""
    text = _straighten_quotes(text)
    text = _expand_abbreviations(text)
    text = _punct_to_pauses(text)  # before numbers: digit lookarounds need digits
    text = _expand_roman_headings(text)
    text = _expand_numbers(text)
    text = _expand_symbols(text)
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\s+([,.;:!?])", r"\1", text)
    return re.sub(r",(\s*,)+", ",", text)
