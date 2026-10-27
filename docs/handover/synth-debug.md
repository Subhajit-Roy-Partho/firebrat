# Audio stage (Qwen3-TTS) — what failed, what was fixed, how to resume

Written 2026-10-27 (MST) by the synth-debug agent. Scope: `backend/firebrat_cast/**` and `~/community-books` on the GPU server.
Nothing was uploaded to the Internet Archive or written to Firestore/GitHub; no git commands were run.

## 1. Result

- The expressive multi-voice audio stage works end to end on the RTX 4080:
  `cast.json -> compiled.json -> (per-character anchors) -> batched Qwen3-TTS -> sections/*/audio.m4a + segments.json -> manifest.json -> out/<slug>.zip + built.json`.
- First book (Alice, 94 sections, 2108 segments, ~2.6 h of audio): see section 6 for the measured numbers (WER, voice distinctness, loudness, bitrate).
- The remaining books run unattended in tmux (`cb-synth`, `cb-synth2`), log `~/community-books/autorun-synth.log` (see section 8 to resume/stop).

## 2. What failed and how it was fixed (in the order it was hit)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Every book failed at 00:05 with `TypeError: QwenVoiceEngine() missing voices_dir` | `queue_runner.make_tts_engine` built the engine without the required argument | `voices_dir` optional; `synthesize_book` calls `engine.bind_book(book_id, <pkg>/voices, descriptions)`, so anchors live in `<root>/out/<slug>/voices` and **cannot collide between books** even when one engine serves several (`make_tts_engine(kind, voices_dir=None)`) |
| 2 | `from_pretrained("Qwen/...")` crashes with `HF_HUB_OFFLINE=1` (`OfflineModeIsEnabled ... model_info`) | the qwen-tts tokenizer patch calls the hub for repo ids, not for local dirs | `_snapshot()` resolves the cached snapshot dir with `local_files_only=True` |
| 3 | Engine could not know character descriptions (it only had `descriptions={}`) | nothing passed the roster | `compile_cast` puts `narrator`, `title`, `author` and a `voice_prompt` per character into `compiled.json`; `synth._descriptions()` hands them to the engine |
| 4 | `synth._record_manifest` called `engine.anchor({"character_id": ..})` with a dict and minted anchors for the *whole* roster after synthesis (model swap) | contract mismatch | anchors are minted once up front for the speakers actually used; the manifest only lists existing anchor clips (relative `voices/<id>.wav`) |
| 5 | Resume never worked | `assemble_section` writes `segments.json` through `TimedSegment`, which drops `speaker_id/voice_style`; `_section_done` compared those fields | per-section sidecar `sections/<id>/synth.json` with a fingerprint of (text, speaker, emotion, delivery) |
| 6 | A stale `manifest.json` from a partial run was kept | `_record_manifest` only built it when missing | always rebuilt from the finished sections; sets `content_mode="cast"`, author, `narrator_voice.engine="qwen3-tts"`, `cast.speakers` |
| 7 | AAC bitrate unspecified (ffmpeg's mono default is below 96 kbps) | `audio_assemble` exports `format="ipod", codec="aac"` without a bitrate and `backend/firebrat/` must not be edited | `synth._aac_bitrate()` context manager defaults the AAC bitrate to 112k for the assembler call; mp3 fallback is now an error (not silently accepted) |
| 8 | Speed 0.2-0.3x real time (single line) | generation is CPU/launch-bound (GPU ~15% busy; nested HF `generate` for the 15-codebook sub-talker) | whole batches per call (`generate_voice_clone` takes lists): 96 rows / <= 12-24k frames per call, lines sorted by length, groups of 320 segments across sections. Wall time of a call is ~independent of the number of rows |
| 9 | OOM at 64 rows x 100 frames (14 GB peak) | the 12 Hz speech-tokenizer decoder upsamples the whole batch to 24 kHz at once | `patch_decoder_batching()` decodes 6 rows at a time: peak 5.8 GB at 64x100, 7.5 GB at 128x120; token budget + OOM fallback (retry as halves, outside the `except` block so the tensors can be freed) |
| 10 | Runaway/garbled lines would kill a whole book (old code raised after 3 attempts) | hard failure policy | `max_new_tokens` capped from the text length; duration bounds (0.035-0.25 s/char), max internal silence 1.6 s; retry with new seed; best-effort fallback; never fails the book (counted in `fallbacks`) |
| 11 | Wrong loudness behaviour / clipping | peak normalisation + hard clip | RMS target -21 dBFS with soft limiter (scale down, no clipping) |
| 12 | Unnatural pauses (fixed 260 ms everywhere) | one constant | assembler pause 120 ms + context tail baked into each wav: paragraph end 420 ms, sentence end 140 ms, mid-sentence fragment 30 ms |
| 13 | Text read aloud badly | the old regex normaliser | `synth.normalize_text` now uses `textnorm.normalize_text` (abbreviations, numerals, dashes -> pauses), strips quote marks / stray leading punctuation; punctuation-only segments become 250 ms of silence |
| 14 | The **same character got several voices** (Hatter/The Hatter, Jo March / Josephine 'Jo' March / ... — 38 used roster entries for 26 real characters in Alice; Meg x2, Jo x2, Laurie x3 in Little Women ...) | the casting LLM lists variants as separate characters | `compile_cast.consolidate_roster()` merges by accent/title-free name tokens (equal, or strict subset of exactly one other used entry, gender must not conflict, so Mr. Bennet never folds into Jane Bennet); `Narrator (...)` entries are read by the narrator; the merge map is saved as `compiled["roster_merges"]` |
| 15 | Same-gender characters sounded alike (Alice vs the Duchess: resemblyzer cosine 0.93-0.94) | VoiceDesign collapses to a few archetypes from free-text descriptions | `build_voice_prompt()` makes age/gender/accent explicit and gives each same-gender character its own timbre/pace (pitch only if the description states none); after minting, anchors are compared with the model's own mean-centred x-vectors and too-close ones are re-minted (new seed + gender-aware contrasting trait, max 2 rounds; the narrator is never re-minted) |
| 16 | **Project Gutenberg licence, title page, table of contents, publisher ads and transcriber notes were being narrated** (all 10 raw texts contain them; Alice section 1 was 99 s of licence text) | `fetch` boilerplate stripping had not been applied to these `raw_pages.json` | `compile_cast.strip_boilerplate()` drops head matter (licence/title/colophon/contents, then preface/dedication up to the first "Chapter I / Part I / Letter 1 / I." heading) and tail matter (ads, catalogues, transcriber notes) **by segment**; `(page, idx)` keys are untouched so the cast attributions stay aligned. Checked on all 10 books (heads/tails printed and inspected). Prefaces (e.g. Dorian Gray's, the translator's note in Crime and Punishment) are deliberately not read |
| 17 | Two GPU workers OOM-ed on first start | anchor minting (24 VoiceDesign rows) alone needed >7 GB | `ANCHOR_BATCH=8` with OOM halving; per-process VRAM cap `FIREBRAT_QWEN_VRAM_FRACTION=0.45`, token budget 12000 when two workers share the GPU |

Also fixed: `queue_runner.default_synth_one` recompiles `compiled.json` when `cast.json` is newer; `stage_proc` is unchanged (the engine is bound per book inside `synthesize_book`).

## 3. Design chosen and why (measured, Alice, 5 voices x 3 lines)

| path | same-voice cosine | different-voice cosine | speed |
|---|---|---|---|
| per-line VoiceDesign (description + emotion each line) | 0.70-0.73 | 0.56-0.60 | 2.1-2.6x |
| Base clone, ICL (anchor clip + text) | 0.90 | 0.58 | 3.2x |
| **Base clone, x-vector only** (default) | **0.89** | 0.58 | **3.8x** |

Per-line design is the most expressive but the pitch of one character drifted 90 -> 160 Hz between lines; a book needs a stable voice. So: VoiceDesign mints one 8-14 s anchor per character (`voices/<id>.wav/.json`), every line is spoken by the Base model cloning that anchor's speaker embedding. x-vector-only was kept over ICL (same consistency, faster, no reference bleed). `FIREBRAT_QWEN_MODE=design` selects the per-line design path; `FIREBRAT_QWEN_CLONE=icl` the ICL clone.

**Known limitation (honest):** the Base clone API takes no emotion/instruct string, so the cast's per-line `emotion`/`delivery` fields currently do **not** steer prosody; expression comes from the text and punctuation (the model reads "!" / "?" / dashes expressively, see the samples). Characters are distinct and consistent; per-line emotion is not implemented. Ideas if the owner wants it: per-emotion anchors (design the same description + emotion, clone in ICL mode — costs timbre consistency, measure first) or hybrid (design-per-line only for strongly emotional lines).

## 4. Measured speed

Measured from `autorun-synth.log` (RTX 4080; two workers share the GPU, so each figure is per worker):

| book | sections | segments | audio | wall | x real time | fallbacks |
|---|---|---|---|---|---|---|
| Alice (first run) | 94 | 2108 | 2.56 h | 28.4 min | 5.42 | 0 |
| Alice (rebuilt) | 93 | 2103 | 2.58 h | 25.9 min | 5.97 | 0 |
| Frankenstein | 304 | 1893 | 7.19 h | 66.6 min | 6.48 | 0 |
| Dorian Gray | 279 | 3246 | 7.53 h | 68.7 min | 6.58 | 0 |

Single batches reach x8 (e.g. 45 rows, 361.8 s of audio in 43.0 s). The remaining 7 books were still running when this was written.

## 5. Files touched

`backend/firebrat_cast/`: `tts_qwen.py` (rewritten), `synth.py` (rewritten), `compile_cast.py` (roster consolidation, voice prompts, boilerplate), `queue_runner.py` (`make_tts_engine`, stale compile), `autorun_synth.sh` (new driver, copy of `~/community-books/autorun-synth.sh`), tests `test_tts_qwen.py` (new), `test_synth.py`, `test_compile_cast.py`. `python3 -m pytest backend/firebrat_cast/tests -q` -> 135 passed.

## 6. Verification on the real model

`qa_package.py out/alices-adventures-in-wonderland-carroll 4` (run 2026-10-27, venv-asr, CPU ASR):

- manifest: 93 sections, 9,530,900 ms, engine `qwen3-tts`, mode `cast`; total decoded audio 9,532.8 s.
- format: AAC, 24 kHz mono for every section checked; bitrate 99-108 kb/s (the 112k target is a VBR ceiling).
- loudness: RMS -21.1 to -21.7 dBFS across sections (target -21).
- longest internal silence in the sections listed: 0.58-1.06 s (limit 1.6 s).
- ASR check: 4 random segments, word-weighted WER 0.000 (only punctuation differs). **This is a very small sample**, not a book-level WER.
- `ISSUES: none`.
- Only Alice was QA'd by script; Frankenstein and Dorian Gray are built (`built.json`) but not yet QA'd. No human listening was done.

## 6b. Abbreviation bug found after the first builds (fixed 2026-10-27)

`textnorm._expand_abbreviations` matched title abbreviations as case-insensitive *prefixes*, so "Stop" -> "Saintop", "Drew" -> "Doctorew", "Revived" -> "Reverendived", "Colonel" -> "Colonelonel". It sat in every book built before the fix (2,297 of 2,496 sections contained an affected word); the 4-segment WER sample missed it. Fixed in commit `bd8efbd` (whole-token, capitalised matches only; regression test `test_abbreviations_never_corrupt_longer_words`). All five finished books were invalidated (old zips kept in `~/community-books/old-bad-textnorm/`, **not** to be uploaded) and re-synthesized by deleting `sections/*/synth.json` for affected sections. Lesson: QA must read segments containing capitalised abbreviations, not random samples only.

## 7. Remaining risks

- Per-line emotion is not audible (section 3).
- Casting quality limits the result: some minor characters are still split into several roster entries when names differ too much (e.g. "Rodion" vs "Raskolnikov", "John Harker" vs "Jonathan Harker"); some spurious "characters" from prefaces exist in the casts of P&P/Jane Eyre (they are no longer read because the prefaces are dropped, but their roster rows may linger when attributed).
- Anchor distinctness is bounded by what VoiceDesign can produce: a few same-gender pairs stay similar (cosine ~0.86-0.94 for a handful of minor characters).
- Two workers share the GPU with a VRAM cap; an OOM is retried in halves, a stage failure is retried by the driver's second pass.
- Page-based sections: sections are the source "pages" (~1-2 min each), titled `Page N` / the first heading; chapter structure is not reconstructed.
- No human listening was possible; samples are listed in section 9.

## 8. Commands

Status / logs:
```sh
ssh docker 'tail -f ~/community-books/autorun-synth.log'          # driver + engine log
ssh docker 'cat ~/community-books/jobs/<slug>/state.json'          # per-book stage state
ssh docker 'ls ~/community-books/out/*.zip ~/community-books/out/*/built.json'
```
Resume / start (idempotent; skips books with `built.json`, resumes per section, claims books with lock dirs so any number of workers is safe):
```sh
ssh docker 'cd ~/community-books; tmux new-session -d -s cb-synth  "WORKER=A bash ~/community-books/autorun-synth.sh"'
ssh docker 'cd ~/community-books; tmux new-session -d -s cb-synth2 "WORKER=B bash ~/community-books/autorun-synth.sh"'   # optional 2nd worker
```
One book by hand (no driver):
```sh
cd ~/community-books; . ./cbenv.sh
venv-qwen/bin/python -m firebrat_cast.stage_proc synth-wave --catalog catalog10.json --root ~/community-books --tts qwen --slugs <slug>
~/Github/firebrat/.venvs/extract/bin/python -c "
from firebrat_cast import queue_runner as q
e=[x for x in q.load_catalog('catalog10.json') if x['slug']=='<slug>'][0]
print(q.default_package(e,'/home/roy/community-books'))"
```
`. ./cbenv.sh` exports `HF_HOME HF_HUB_OFFLINE=1 CUDA_MPS_PIPE_DIRECTORY=/tmp/firebrat-no-mps PYTHONUNBUFFERED PATH(ffmpeg) PYTHONPATH`. **Note:** tmux sessions do not inherit your shell exports; always source `cbenv.sh` inside the tmux command (the driver does).
Redo a book from scratch: `rm -rf out/<slug>/{sections,_segment_wavs,compiled.json,built.json,manifest.json} out/<slug>.zip` and remove `synth`/`package` from `jobs/<slug>/state.json` `done`. Keep `voices/` to keep the same voices (delete it to re-mint).
Deploy code: `rsync -aq --delete --exclude __pycache__ --exclude tests backend/firebrat_cast docker:community-books/code/`.
Stop: `ssh docker 'tmux kill-session -t cb-synth; tmux kill-session -t cb-synth2'` (safe; resumes per section).
Tunables (env): `FIREBRAT_QWEN_BATCH` (96), `FIREBRAT_QWEN_TOKEN_BUDGET` (24000; 12000 with two workers), `FIREBRAT_QWEN_VRAM_FRACTION`, `FIREBRAT_QWEN_MODE=design`, `FIREBRAT_QWEN_CLONE=icl`, `FIREBRAT_QWEN_TEMPERATURE`.

## 9. QA tooling and samples (server, `~/community-books`)

`qa_package.py <pkg_dir> [n]` (venv-asr: faster-whisper small.en + ffmpeg: bitrate/format/duration/monotone timestamps/silences/WER sample), `evalaudio.py <dir> <lines.json>` (WER + resemblyzer within/between cosine), `pairs.py`, `anchors_matrix.py`. venv `~/community-books/venv-asr` (faster-whisper, resemblyzer, jiwer, librosa; whisper weights in `asr-cache/`).
Samples: `~/community-books/samples/*.m4a` (listed in section 6).
