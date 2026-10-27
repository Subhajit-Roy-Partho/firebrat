"""Offline tests for compile_cast.py (stdlib + unittest only)."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from firebrat_cast.compile_cast import compile_cast_dict, compile_cast_file


RAW = {"book_id": "pp", "pages": [
    {"page_idx": 0, "text": "\u201cHello,\u201d Elizabeth said. It was morning."},
    {"page_idx": 1, "text": ""},
    {"page_idx": 2, "title": "Chapter 2", "text": "Rain fell. \u201cIndeed.\u201d"},
]}

CAST = {"book_id": "pp",
        "characters": [{"id": "char_001", "name": "Elizabeth Bennet", "aliases": ["Lizzy"],
                        "gender": "female", "description": "Young female voice."}],
        "utterances": [{"page": 0, "idx": 0, "speaker": "char_001",
                        "emotion": "joy", "delivery": "brightly"},
                       {"page": 2, "idx": 1, "speaker": "char_999",
                        "emotion": "ecstatic", "delivery": "x" * 100}],
        "page_mood": {"0": {"emotion": "tenderness", "delivery": "softly"},
                      "2": {"emotion": "bogus", "delivery": ""}}}


class CompileCastTest(unittest.TestCase):
    def test_sections_mirror_novel_shape(self):
        compiled = compile_cast_dict(RAW, CAST)
        self.assertEqual(compiled["book_id"], "pp")
        self.assertEqual(compiled["content_mode"], "novel")
        self.assertEqual(compiled["formulas"], [])
        self.assertEqual(len(compiled["sections"]), 2)  # blank page skipped
        sec0 = compiled["sections"][0]
        self.assertEqual(sec0["section_id"], "sec_0001")
        self.assertEqual(sec0["title"], "Page 1")
        self.assertEqual(sec0["source_pages"], [0])
        self.assertEqual(compiled["sections"][1]["title"], "Chapter 2")

    def test_speakers_and_voice_styles(self):
        compiled = compile_cast_dict(RAW, CAST)
        quote, narration = compiled["sections"][0]["segments"][:2]
        self.assertEqual(quote["speaker_id"], "char_001")
        self.assertEqual(quote["voice_style"],
                         {"voice_id": "char_001", "emotion": "joy", "delivery": "brightly"})
        self.assertEqual(narration["speaker_id"], "narrator")
        self.assertEqual(narration["voice_style"]["emotion"], "tenderness")  # page mood
        # Unknown speaker id -> narrator, off-vocab emotion -> neutral, delivery cut.
        mystery = compiled["sections"][1]["segments"][1]
        self.assertEqual(mystery["speaker_id"], "narrator")
        self.assertEqual(mystery["voice_style"]["emotion"], "neutral")
        self.assertLessEqual(len(mystery["voice_style"]["delivery"]), 60)
        for sec in compiled["sections"]:
            for seg in sec["segments"]:
                self.assertEqual(seg["type"], "prose")
                self.assertIsNone(seg["ref"])

    def test_roster_and_stats(self):
        compiled = compile_cast_dict(RAW, CAST)
        self.assertEqual(compiled["character_roster"][0]["character_id"], "char_001")
        self.assertEqual(compiled["character_roster"][0]["voice_gender"], "female")
        self.assertEqual(compiled["dialogue_stats"], {"total": 2, "attributed": 1})

    def test_empty_raises(self):
        with self.assertRaises(ValueError):
            compile_cast_dict({"book_id": "x", "pages": []}, CAST)

    def test_file_round_trip(self):
        tmp = tempfile.mkdtemp()
        raw_path = os.path.join(tmp, "raw_pages.json")
        cast_path = os.path.join(tmp, "cast.json")
        out_path = os.path.join(tmp, "compiled.json")
        import json
        for path, obj in ((raw_path, RAW), (cast_path, CAST)):
            with open(path, "w", encoding="utf-8") as f:
                json.dump(obj, f)
        compiled = compile_cast_file(raw_path, cast_path, out_path)
        with open(out_path, encoding="utf-8") as f:
            self.assertEqual(json.load(f), compiled)


if __name__ == "__main__":
    unittest.main()
