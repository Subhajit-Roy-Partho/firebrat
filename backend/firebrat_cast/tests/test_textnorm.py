"""Tests for firebrat_cast.textnorm (stdlib only, runs fully offline)."""

from firebrat_cast.textnorm import normalize_text


def test_cardinal_numbers():
    assert normalize_text("She has 42 apples.") == "She has forty-two apples."
    assert "one thousand" in normalize_text("1,000 pages")


def test_years():
    assert "nineteen ninety-nine" in normalize_text("in 1999")
    assert "two thousand five" in normalize_text("2005")
    assert "twenty fifteen" in normalize_text("2015")
    assert "nineteen nineties" in normalize_text("the 1990s")


def test_currency_and_percent():
    assert normalize_text("It costs $5.") == "It costs five dollars."
    assert normalize_text("It costs $1.") == "It costs one dollar."
    out = normalize_text("Only $5.99!")
    assert out == "Only five dollars and ninety-nine cents!"
    assert normalize_text("50% off") == "fifty percent off"
    assert normalize_text("3.5%") == "three point five percent"


def test_decimals_and_negatives():
    assert normalize_text("pi is 3.14") == "pi is three point one four"
    assert normalize_text("-5 degrees") == "minus five degrees"


def test_ordinals():
    assert normalize_text("the 1st place") == "the first place"
    assert normalize_text("the 2nd try") == "the second try"
    assert normalize_text("the 3rd day") == "the third day"
    assert normalize_text("the 22nd of May") == "the twenty-second of May"
    assert normalize_text("his 100th game") == "his one hundredth game"


def test_roman_headings():
    assert normalize_text("Chapter IV") == "Chapter four"
    assert normalize_text("Part II") == "Part two"
    # ordinary words are untouched
    assert normalize_text("I saw him mix it") == "I saw him mix it"


def test_abbreviations():
    out = normalize_text("Mr. Smith met Dr. Jones on St. Lane.")
    assert out == "Mister Smith met Doctor Jones on Saint Lane."
    assert "Missus" in normalize_text("Mrs. Bennet")
    assert "etcetera" in normalize_text("apples, pears, etc.")
    assert "for example" in normalize_text("e.g. this")


def test_dashes_ellipsis_quotes():
    assert normalize_text("wait—what") == "wait, what"
    assert normalize_text("well -- indeed") == "well, indeed"
    assert normalize_text("pages 1940–1945") == "pages nineteen forty to nineteen forty-five"
    assert normalize_text("so... then") == "so, then"
    assert normalize_text("\u201chello,\u201d she said") == '"hello," she said'


def test_symbols():
    assert normalize_text("fish & chips") == "fish and chips"
    assert normalize_text("2 + 2") == "two plus two"
    assert normalize_text("his/her book") == "his or her book"


def test_no_words_dropped():
    text = "Mr. Darcy paid $5.99 for 42 green apples in 1999 — amazing... truly!"
    out = normalize_text(text).lower()
    for word in ("darcy", "paid", "green", "apples", "amazing", "truly"):
        assert word in out


def test_whitespace_collapse_and_empty():
    assert normalize_text("a   b\n\tc") == "a b c"
    assert normalize_text("") == ""
    assert normalize_text("   ") == ""
