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


class ConsolidateRosterTest(unittest.TestCase):
    @staticmethod
    def _cast(chars, counts):
        return {"characters": [{"id": f"char_{i:03d}", "name": n, "gender": g, "aliases": [], "description": f"d{i}"}
                               for i, (n, g) in enumerate(chars, 1)],
                "utterances": [{"page": 0, "idx": k, "speaker": f"char_{i:03d}"}
                               for i, c in enumerate(counts, 1) for k in range(c)]}

    def test_variants_of_one_person_share_a_voice(self):
        from firebrat_cast.compile_cast import consolidate_roster

        cast = self._cast([("Jo March", "female"), ("Josephine 'Jo' March", "female"),
                           ("The Hatter", "male"), ("Hatter", "male"), ("Meg March", "female")],
                          [30, 2, 10, 1, 5])
        new, merges = consolidate_roster(cast)
        names = [c["name"] for c in new["characters"]]
        self.assertEqual(sorted(names), ["Jo March", "Meg March", "The Hatter"])
        self.assertEqual(merges, {"char_002": "char_001", "char_004": "char_003"})
        self.assertTrue(all(u["speaker"] in {"char_001", "char_003", "char_005"} for u in new["utterances"]))
        self.assertIn("Josephine 'Jo' March", new["characters"][0]["aliases"])

    def test_accents_parentheses_and_titles(self):
        from firebrat_cast.compile_cast import consolidate_roster

        cast = self._cast([("Mr. Svidrigaïlov", "male"), ("The Man (Svidrigailov)", "male"),
                           ("Mr. Rochester", "male"), ("Edward Rochester", "male")], [50, 5, 10, 90])
        new, merges = consolidate_roster(cast)
        self.assertEqual(len(new["characters"]), 2)
        self.assertEqual(merges["char_002"], "char_001")
        self.assertEqual(merges["char_003"], "char_004")

    def test_gender_and_ambiguity_block_merges(self):
        from firebrat_cast.compile_cast import consolidate_roster

        cast = self._cast([("Mr. Bennet", "male"), ("Mrs. Bennet", "female"), ("Jane Bennet", "female"),
                           ("Elizabeth Bennet", "female")], [20, 15, 30, 40])
        new, merges = consolidate_roster(cast)
        self.assertEqual(merges, {})  # Mr. Bennet is ambiguous / male; Mrs. Bennet ambiguous
        self.assertEqual(len(new["characters"]), 4)

    def test_narrator_entries_and_unused_characters(self):
        from firebrat_cast.compile_cast import consolidate_roster

        cast = self._cast([("Narrator (Lucy's Letter)", "female"), ("Nobody", "male"), ("Lucy", "female")],
                          [3, 0, 4])
        new, merges = consolidate_roster(cast)
        self.assertEqual([c["name"] for c in new["characters"]], ["Lucy"])
        self.assertEqual(merges["char_001"], "narrator")
        self.assertEqual([u["speaker"] for u in new["utterances"]].count("narrator"), 3)


class BoilerplateTest(unittest.TestCase):
    @staticmethod
    def _segs(texts):
        return [{"page": i // 5, "idx": i % 5, "kind": "narration", "text": t} for i, t in enumerate(texts)]

    def test_licence_title_page_and_contents_are_skipped(self):
        from firebrat_cast.compile_cast import strip_boilerplate

        story = "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do. " * 2
        segs = self._segs([
            "The Project Gutenberg eBook of Alice\n\nThis eBook is for the use of anyone anywhere",
            "Title: Alice\n\nRelease date: June 27, 2008\n\nLanguage: English",
            "***\n\nAlice\n\nContents\n\nCHAPTER I. Down\n\nCHAPTER II. Pool",
            "CHAPTER III. Race\n\nCHAPTER IV. Rabbit",
            "CHAPTER I.\n\nDown the Rabbit-Hole\n\n" + story,
            story, story,
            "Lastly, she pictured the happy summer days.\n\nTHE END",
        ])
        first, last, trim = strip_boilerplate(segs)
        self.assertEqual((first, last, trim), (4, 7, 0))

    def test_preface_is_skipped_and_heading_glued_to_list_is_trimmed(self):
        from firebrat_cast.compile_cast import strip_boilerplate

        prose = "It is a truth universally acknowledged that a single man in possession of a good fortune. " * 3
        segs = self._segs([
            "*** START OF THE PROJECT GUTENBERG EBOOK PRIDE ***",
            "PREFACE. " + prose,
            prose,
            "466\n\nHeading to Chapter LXI.472\n\nThe End476\n\nChapter I.\n\nIT is a truth universally acknowledged. " + prose,
            prose,
        ])
        first, last, trim = strip_boilerplate(segs + self._segs([prose] * 10), head_scan=3)
        self.assertEqual((first, last), (3, 14))
        self.assertTrue(segs[3]["text"][trim:].startswith("Chapter I."))

    def test_trailing_ads_and_transcriber_notes_dropped_but_never_the_whole_book(self):
        from firebrat_cast.compile_cast import strip_boilerplate

        prose = "They lived happily ever after in the old house by the river, and never regretted it. " * 3
        segs = self._segs(["CHAPTER I.\n\n" + prose, prose, prose,
                           "SILVER PITCHERS\n\n16mo. $1.25.\n\nPROVERB STORIES\n\n16mo. $1.25.",
                           "\"Little Men\"", "Transcriber's Note: On page 12, change of to off."])
        first, last, _ = strip_boilerplate(segs)
        self.assertEqual((first, last), (0, 2))
        junk = self._segs(["Project Gutenberg licence", "Transcriber note on page 3"])
        self.assertEqual(strip_boilerplate(junk), (0, 1, 0))

    def test_compile_drops_boilerplate_but_keeps_cast_keys(self):
        raw = {"book_id": "b", "pages": [
            {"page_idx": 0, "text": "The Project Gutenberg eBook of B. Release date: 2008. Language: English.\n\nCHAPTER I.\n\n“Hello,” she said. It was morning, and the sun rose over the hills."},
        ]}
        cast = {"book_id": "b", "characters": [], "utterances": []}
        compiled = compile_cast_dict(raw, cast)
        texts = " ".join(s["text"] for sec in compiled["sections"] for s in sec["segments"])
        self.assertNotIn("Gutenberg", texts)
        self.assertIn("morning", texts)
        self.assertIn("boilerplate", compiled)
