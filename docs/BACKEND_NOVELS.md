# Backend novel conversion

Upload a PDF/ZIP using `POST /books/upload` with multipart `content_mode=novel`.
The existing `illustrated` mode remains the default. Invalid modes return 422.
Job responses include `content_mode`; the value is stored in SQLite and survives
retries, resume and server restarts. Existing databases migrate automatically,
with existing jobs retaining `illustrated` mode.

The equivalent CLI command is:

```sh
python backend/convert.py story.pdf --content-mode novel
```

Novel compilation bypasses the LLM and preserves the extracted text exactly,
including quotation marks, punctuation and order. Extraction/OCR still runs
normally. It scans all extracted pages before assigning a character roster,
then splits narration at quotes and into bounded utterances for TTS. Page
sections and source-page links are retained; illustration/table/formula callouts
are omitted. This is unabridged relative to **extracted text**: extraction quality
still determines whether the original PDF text is complete.

Speaker attribution supports explicit English tags such as `Alice said, “Hello.”`
and `“Hello,” Bob replied.` Names receive stable IDs sorted across the whole
book. Untagged dialogue, pronouns and ambiguous speakers remain the narrator.
This does not infer personalities, relationships or implicit turn-taking. Voice gender
is inferred only from explicit narrator statements such as `Alice was a woman`
or `Bob, a man, ...`, scanning the whole book. Names alone never determine it.
Quoted claims are ignored, and conflicting evidence resolves to `unknown`.
The roster records the classification and its evidence pages. Unknown characters
keep neutral style assignment; this is a conservative voice hint, not a claim
about identity.
The roster records the pages where each explicit character tag was found.

The existing Chatterbox narrator receives one of four deterministic styles:
small pitch shifts and generation exaggeration settings. Explicit male/female
evidence chooses lower/higher pitch respectively. These are variants of
the configured narrator, not independently cloned character identities. More
than four characters reuse styles. Pitch shifts also change speaking speed;
there is no claim of natural actor-quality character performance. Cached novel
utterances are checked against text, speaker, style and narrator reference path
before reuse. Failed synthesis stops conversion instead of reporting success
with missing speech. Whole-section reuse checks text, speaker/style and audio
existence. Reference file content hashes participate in cache reuse, so changing a reference
at the same path invalidates the matching narration cache.

Operators may supply independent local Chatterbox reference clips:

```sh
python backend/convert.py story.pdf --content-mode novel \
  --voice-ref /local/voices/narrator.wav \
  --male-voice-ref /local/voices/male.wav \
  --female-voice-ref /local/voices/female.wav
```

These files must exist locally; remote URLs are rejected. These options select
reference audio for the same Chatterbox model, not different TTS models. If no
matching reference is supplied, the narrator reference is used with the character
style. Unknown characters retain the narrator reference. The HTTP upload API
does not accept server filesystem paths. Operators should supply reference clips
they are entitled to use; no male/female reference audio is bundled by this change.

The manifest adds `content_mode` and `character_roster`. Timed segments add
`speaker_id` and `voice_style`; older packages default to the narrator and
illustrated mode. Existing clients may ignore these additive fields.

Tests cover verbatim text, full-book stable roster, conservative pronoun handling,
long utterances, empty sources, metadata/no visual callouts, old database
migration, upload validation and persisted mode reaching the conversion runner.
Real Chatterbox character voice quality requires a synthesis/listening test on
the configured server; automated tests do not establish that subjective quality.
