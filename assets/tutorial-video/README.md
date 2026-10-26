# Firebrat tutorial video

Voiceless, music-free tutorial of the Android app (v1.7.2), usable as a YouTube tutorial and, with the short cut, as the Play listing promo (Play takes a YouTube link).

| File | What it is |
|---|---|
| `firebrat-tutorial-full.mp4` | Full tutorial, 7:58, 1080x1920 portrait, H.264, 30 fps, no audio track |
| `firebrat-play-promo.mp4` | 45 s cut for the Play listing (same format) |
| `chapters.txt` | YouTube chapter list, paste into the description (starts at 0:00, every chapter is 10 s or longer) |
| `captions.srt` | All on-screen captions and chapter-card text, timed to the full video (upload as subtitles) |
| `thumbnail.png` | 1280x720 YouTube thumbnail |
| `source/` | Scripts that built everything (Pillow + ffmpeg). They read the raw phone recordings from a scratch folder that is not kept in the repo |

Style: one dark gradient canvas, phone framed in the middle, chapter label on top, lower-third caption below the phone (so captions never cover the UI), white tap indicators come from Android's "show touches" in the recording.

## Privacy handling

- The signed-in Google account email (menu drawer header and Sync & backup page) is blurred or replaced in every scene. Sync & backup also hides the list of the user's Drive backups.
- The API key is never shown. Where the key field is static, a visibly fake placeholder (`sk-or-v1-EXAMPLE-NOT-A-REAL-KEY`) is drawn over it. While the page is scrolling, the app's own dots mask the field. The key was never typed, pasted or read during recording.
- No account was created and nothing was signed into. The OpenRouter website steps are drawn mock-ups labelled "Illustration only", not screenshots of the live site.
- Status bar (clock, notification icons) is covered. The recording ran in Do Not Disturb with Firebrat in front; no other app is in the video. The file picker is never shown because the phone's Downloads folder holds personal files.
- Raw recordings are not in the repo (they contain the account email before masking).

## Scenes and where each comes from

Part 1, feature tour
1. 1.1 First-run guide: real recording, 10 guide pages (menu > App guide).
2. 1.2 Library and cover art: real library (ebook cover for Pride and Prejudice, generated cover for the Peter Rabbit sample, hourglass badge) plus a larger shelf from `assets/play-store/modern-refresh/sources/library-dark.png` (**illustrative sample titles**, captioned as such).
3. 1.3 Open a book and listen: real recording of the Peter Rabbit sample: highlight, speed menu, segments, section bar, section list, text size, focus mode, source page. Then a card on cover art on the lock screen and notification (**no lock-screen capture; text card with generated covers**).
4. 1.4 Import or convert a book: **text card** (no picker footage, for privacy).
5. 1.5 Novel vs Illustrated: real settings recording plus two Pixel stills from the Play listing sources (`dev-modes-illustrated.png`, `dev-modes-novel.png`, captured on an earlier build). The app calls the modes "Illustrated / technical" and "Novel / characters".
6. 1.6 Cast & voices: real recording on the Pride and Prejudice book (25 speakers, 29% attributed, web research box, per-speaker traits and voices).
7. 1.7 Conversion queue: real Conversions screen with a live conversion, plus a battery/background card. **Adding several books and pressing Stop were not filmed**: the user's Pride and Prejudice conversion was running and was never stopped.
8. 1.8 Pause and resume (1.7.2): real recording, Pause, paused row ("Progress is saved"), Resume, "resuming after section 6 of 463". The re-read of the PDF text layer is sped up 4x.
9. 1.9 Listen while it converts (1.7.2): real recording, hourglass badge, "Still converting: 6 of 463 sections ready" banner, seek to the end of the last ready section and "Waiting for the next section to finish. Playback continues by itself." (the wait is sped up 2x). The clip does not wait long enough to show playback moving into a newly finished section.
10. 1.10 Menu: real drawer, email blurred.
11. 1.11 Drive backup and sync: real Sync & backup page (account and backup list hidden) plus the in-app guide page on Google Drive. The Drive sign-in and connect flow was not filmed (no sign-in allowed).

Part 2, free OpenRouter key
- 2.1 In-app guide: real recording, Conversion settings > Cloud LLM > "How to get a free API key".
- 2.2 OpenRouter website steps: **four drawn mock-ups** (sign up, Keys > Create key, free models, keep the key private).
- 2.3 URL, key, Load models, Test connection: real recording on the configured settings screen ("Found 467 models (17 free)", "Connected"). The key is a placeholder. The "pick a free model" step uses `dev-llm-test.png` from the Play sources (**earlier capture**). Nothing was typed into the key field and Save was never pressed, so the user's settings are unchanged.

Part 3, advanced topics (3.1 voice overrides: Pixel still + example card; 3.2 web research: real settings and Cast & voices clips; 3.3 queue/background/battery: guide clip; 3.4 cloud for all vs on-device: settings clip + card; 3.5 ebooks and covers: card; 3.6 pause, resume and partial listening: real 1.7.2 clips; 3.7 Drive backup: guide clip + card; 3.8 privacy and offline-first: Pixel still + card).

## Placeholders and things to re-record

- **1.7.2 guide text**: the installed 1.7.2 build's in-app guide still shows the 1.7.1 pages (no "Listen while it converts" line). If the guide was updated after that build, re-record the 1.1 scene (`guide.mp4`) and the two short guide reuses in 3.3 and 1.11/3.7.
- **Lock-screen and notification cover art**: text card only. Film it with a clean notification shade (no personal notifications).
- **Import and convert a PDF / EPUB**: text card only. A short sample PDF and EPUB converted live, filmed without the file picker (or with a scrubbed Downloads folder), would replace it.
- **Queue "add several books" and "Stop"**: not filmed (see above).
- **Stills from older builds** (modes, voice overrides, model pick, on-device settings, larger library shelf): fine for now, replace with 1.7.2 captures when convenient.
- Playback moving into a freshly finished section while converting: re-record once the conversion is further along.

## Play listing images

The 1.7.2 gallery lives with the other listing assets: `assets/play-store/modern-refresh/exports/` (`01` to `08`, listing order) built by `compose.py` from real 1.7.2 screenshots in `sources/` (listen while it converts, pause and resume, Cast & voices). The video build scripts in `source/` are separate.

## YouTube description starter

```
Firebrat turns your own PDFs and ebooks into narrated audiobooks. Private on-device conversion, or a free cloud LLM for speed.

Chapters: paste chapters.txt here.
Guide and downloads: https://subhajit-roy-partho.github.io/firebrat/documentation/guide.html
Free LLM providers may log prompts. Keep private books on the on-device model. Bring books you have permission to use.
```
