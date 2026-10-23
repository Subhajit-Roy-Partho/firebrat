# Firebrat Apple PWA

Server-only conversion with offline playback of books explicitly saved in the
browser. No on-device conversion or language/speech model download is included.

The FastAPI backend serves the production build at **`/pwa/`**; its existing root
control room is unchanged. On an iPhone or iPad, open your server's HTTPS URL in
Safari, choose Share → Add to Home Screen. Set the server URL in Settings if the
API uses another origin. Your deployment domain must be authorized in Firebase
Authentication, and a different API origin must allow your app's origin in CORS.
Firebase web app `Firebrat PWA` is registered in `firebrat-8c597`. Hosting/billing
were not enabled. `/firebase-config` supplies public config; deployments can set
`FIREBASE_WEB_API_KEY` to override its registered browser key.

Features: Google/email sign-in and sign-up, PDF/ZIP uploads, illustrated/novel
server conversion, upload progress, job polling/retry, library, synchronized text,
figures and math, zoom, source PDF, chapter/segment seeking, speed, autoplay,
reading position and media controls. Save offline downloads all narration and
visuals atomically. Original PDF is optional to save storage. Interrupted downloads
do not appear complete. Saved audio supports byte-range requests for Safari.

Browser storage can be evicted by iOS; retain the server copy. A PWA is not a
background conversion worker: conversion continues on the server after upload.
Offline account sign-in, uploads and new server conversions require connectivity.
Private job/auth responses are not cached. Reading public server books needs no
account. Use HTTPS on real Apple devices; localhost is suitable for Mac testing.

## Build and checks

```sh
npm ci
npm test
npm run build
```

Build writes `backend/server/static/pwa/`, which is checked in so the Python
server can serve it without Node. Rebuild after source edits. The build stamps
the service worker with the HTML asset hash so a cached page always matches its
scripts across updates. Do not hand-edit generated files.

2026-10-21 validation: five helper tests pass (URLs/path containment, timing,
asset completeness, audio ranges). Production build succeeds. In a real browser,
a server-generated API library entry was saved, read and played; after stopping
the server, a full reload restored the library, original image and narration,
including seeking. This caught and fixed a stale HTML/script update bug.
The published short illustrated sample uses native Kokoro speech, not a new
heavy server conversion run.
Live account consent, real iPhone installation/storage eviction, lock-screen
behavior and complete heavy server conversion are not established by these checks.

## GitHub Pages

Published app: https://subhajit-roy-partho.github.io/firebrat/

The existing website is preserved at `/firebrat/documentation/` and linked from
the app. Firebase authorizes `subhajit-roy-partho.github.io` for sign-in. Pages
serves static files, so enter a separately hosted HTTPS conversion server in
Settings to upload new books. The bundled original circuit sample works without
a server and can be saved for offline reading.

`npm run build:pages` uses `/firebrat/` as the application and service-worker
scope. Publish that generated output to the repository's `gh-pages` root. The
registered public Firebase web config is bundled for static hosting. Google
sign-in reached the popup flow on the published hostname without an unauthorized
domain error; actual account consent still needs Safari verification.

On the connected iPad (9th generation), iPadOS 27.2, a Safari UI test passed
opening the published sample, showing the original illustration in zoom, starting
Kokoro narration through a text segment and pausing it with the media control.
This verifies the public reader in actual iPad Safari; it does not establish
home-screen installation, airplane-mode storage persistence or Google consent.

## Public information pages

The PWA footer links privacy policy (`privacy/`), data-use explanations
(`data-safety/`), manual account/data deletion requests (`delete-account/`),
conversion instructions (`help/`) and bug reporting (`support/`). These static
pages are accessible without sign-in and load no analytics scripts. Editable
sources live in `public/`. The public Data safety explanation is separate from
Google Play's declaration. See `docs/PLAY_PRIVACY_DRAFT.md` for the owner's
manual deletion-request procedure and remaining release requirements.
