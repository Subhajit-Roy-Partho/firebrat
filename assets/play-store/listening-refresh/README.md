# Listening-first Play Store refresh

Created 24 October 2026 (America/Phoenix). This is a store-listing-only update; it does not change the Android binary or policy declarations.

## Assets

`exports/` contains a 1024×500 JPEG feature graphic and six 1080×1920 JPEG phone-gallery graphics, ordered 01–06. All are under 8 MB. The gallery presents listening first, followed by pictures/source PDF, narrator and character voices, offline/on-device operation, the companion server, and backend model selection.

`description.txt` and `short-description.txt` contain the exact Play copy. `render.html?card=1` through `?card=6` and `?card=feature` are editable HTML/CSS layout sources. Serve this folder locally; export the canvas at its explicit dimensions. UI content is captured, not AI-invented. Headphones/book artwork is promotional illustration and is not shown as an in-app feature.

## Sources and accuracy

- `reader-playback.png` and `source-pdf.png`: real signed-release Android 16 KB emulator screenshots from the preceding verification. Public-domain Peter Rabbit sample only; no account details or private notifications.
- `novel-voices.png` and `offline-settings.png`: previously captured real Android settings screens. Layout windows crop surrounding content but do not change control text or values.
- `server-convert.jpg` and `server-models.jpg`: actual companion-server browser captures. Only the upload form's local GPU option was selected for framing; no conversion was submitted and server defaults were not changed. Screens are labeled as server UI, not Android UI. Preset changes require an LLM restart; VRAM needs vary by model and workload.
- Narration assets require initial downloads. Offline conversion depends on compatible hardware/models. The API option sends content to the chosen LLM provider; server voice generation remains local. No promise of unlimited Firebase sync, perfect figure placement, universal hardware support or an included copyrighted catalogue.
- Sample: *The Tale of Peter Rabbit*, Beatrix Potter (1902), Project Gutenberg 14838, three-page review excerpt.

## Image-generation provenance

Used the built-in image-generation tool (not the CLI/API fallback) to create `sources/listening-world.png`. The remaining typography, wave motif, frames and layout are HTML/CSS. Existing source artwork and old store screenshots remain preserved.

Final artwork prompt:

> Use case: ads-marketing. Create a premium wide landscape editorial campaign illustration for Firebrat, an app that converts your own books and PDFs into narrated listening with pictures. Artwork ONLY, no text, no letters, no logos, no UI, no device screens. A beautifully tactile open paper book near the lower right transforms its pages into flowing luminous sound ribbons that form a graceful over-ear headphone silhouette and expand outward like a world of sound; subtle illustrated mountains and stars emerging from the paper suggest imagination and freedom. Sophisticated midnight indigo and deep violet background, vivid warm amber/coral sound light with a little lavender, rich dimensional paper textures, polished contemporary 3D editorial illustration, restrained but striking, excellent lighting. Wide 2:1 composition: leave the left 45 percent mostly dark negative space for large headline typography to be added separately, keep important book/headphone forms in the right 55 percent with breathing room around all edges. No music notes (this is spoken books), no people, no stock photo look, no watermarks.

## Verification

Each exported image was visually inspected. JPEG decoding, dimensions, file-size limits, 80-character short description and 4,000-character full-description limit were checked. Keep AI asset labeling enabled in Play Console for the generated illustration. Submission status is recorded after saving the final Console preview.
