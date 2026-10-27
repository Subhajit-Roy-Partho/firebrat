# Firebrat Community — spec (master: Claude; implementers: opencode muse-spark-1.3-contributor)

Public-domain / openly-licensed audiobook library. Static site (Vite + vanilla JS ES modules,
no framework), Firebase web SDK 13.0.0 (Auth + Firestore ONLY — no Storage, no Functions),
files live on the Internet Archive (IA). Firebase project `firebrat-8c597` (same as app + PWA;
web config comes from `src/firebase-config.js`, copy values from
`../frontend/firebrat_pwa/src/main.js` / `/firebase-config` handling — apiKey is public).
Build: `npm run build` -> `dist/`. Deploys to GitHub Pages under base `/firebrat/community/`
(`VITE_APP_BASE`). Tests: `node --test test/*.test.mjs` for pure helpers.

## Book package format ("current app format")
Zip (or unzipped folder) with `manifest.json` (schema_version "1.0", book_id, title, author,
narrator_voice{engine,model_class,...}, total_duration_ms, sections[{section_id,order,title,
audio_path,segments_path,duration_ms,...}], figures, formulas, tables, source_pdf_path),
`sections/<id>/audio.m4a`, `sections/<id>/segments.json`, `assets/...`. See ../docs/DATA_SCHEMA.md.

## Internet Archive handling (src/ia.js — pure, testable)
- `parseArchiveUrl(str)` -> identifier from `archive.org/details/<id>`, `archive.org/download/<id>[/...]`,
  `archive.org/embed/<id>`; rejects other hosts. Identifier regex `^[A-Za-z0-9][A-Za-z0-9._-]{2,99}$`.
- `fetchItem(id)` -> GET `https://archive.org/metadata/<id>` (CORS ok); returns files list.
- `locatePackage(files)` -> `{kind:'folder', base}` if root `manifest.json`, else `{kind:'zip', zip}` for
  the first `.zip`; else null. Inner files of a zip are fetched at
  `https://archive.org/download/<id>/<zip>/<inner/path>`; folder files at `.../download/<id>/<path>`.
- `fetchManifest(id)` and `validateManifest(m)` (pure: checks schema_version, book_id, title, non-empty
  sections each with audio_path+segments_path; returns {ok, errors[], summary:{title,author,sectionCount,
  durationMs,engine}}).
- `downloadUrl(id, loc)` = zip url, or `https://archive.org/compress/<id>` for folders.
Two submission routes (UI must state this plainly, side by side):
  A. **I already have it on Internet Archive** — paste the URL (verified live against the metadata API).
  B. **Upload it for me to Internet Archive** — in-browser upload to IA's S3-compatible API
     (`https://s3.us.archive.org/<id>/<file>`, header `authorization: LOW <accesskey>:<secret>`,
     `x-archive-auto-make-bucket:1`, `x-archive-meta01-collection:opensource_audio`, mediatype `audio`,
     title/description/license meta). Keys are the user's own IA S3 keys (link to
     https://archive.org/account/s3.php), kept in memory only, NEVER stored/logged/sent to Firebase.
     Show progress via XHR upload events; on CORS/network failure fall back to showing the
     manual https://archive.org/upload instructions, then route A. Item identifier = slug(title)+random suffix.

## Firestore data model (rules in ../firebase/firestore.rules — DO NOT change field names)
`books/{bookId}` (bookId = IA-identifier-safe slug):
 title(≤200), author(≤200), description(≤4000), language(≤10), category(one of `fiction|nonfiction|
 science|history|poetry|children|education|other`), tags[≤10 strings ≤40], archiveId(≤100),
 archiveUrl(≤300), packageKind('zip'|'folder'), sizeBytes, sectionCount, totalDurationMs,
 provenance map: {generation ('firebrat-tts'|'human-narrated'|'mixed'|'other'), narrationEngine(≤120),
   models[≤10 ≤120 each], pipelineNotes(≤2000), sourceTitle(≤300), sourceUrl(≤300),
   license('public-domain'|'cc0'|'cc-by'|'cc-by-sa'), licenseUrl(≤300), attested(bool true)},
 submitterUid, submitterName(≤80), status('published'|'removed'|'disputed'), ratingSum, ratingCount,
 commentCount, createdAt, updatedAt (server timestamps).
`books/{bookId}/ratings/{uid}` {value:int 1..5, updatedAt}. Client writes rating + book aggregate
 (ratingSum, ratingCount) in ONE batch; rules verify the deltas.
`books/{bookId}/comments/{cid}` {uid, name(≤80), text(≤2000), status('visible'|'hidden'), createdAt, reportCount}.
 Author may delete own; admins hide/delete.
`reports/{id}` {kind('comment'|'book'), bookId, commentId?, reason('offensive'|'spam'|'harassment'|
 'misleading'|'other'), details(≤1000), reporterUid, createdAt, resolved:false}. Admin-readable only.
 Reporting a comment also lets the reporter increment nothing else — keep it write-once.
`bugs/{id}` {kind('bug'|'error'|'feedback'), bookId?, page(≤200), message(≤3000), userAgent(≤300),
 appVersion(≤40), reporterUid, createdAt, status:'open'}. Admin-readable only.
`takedowns/{id}` (copyright violation / DMCA-style notice; auth NOT required) {bookId, claimantName(≤120),
 claimantEmail(≤200), rightsHolder(≤200), workDescription(≤2000), infringingUrls(≤2000), goodFaith(true),
 accuracy(true), signature(≤120), status:'open', createdAt}. Admin-readable only. Page must say
 admins review notices and may disable the book (status 'disputed') pending resolution, and that
 false claims have legal consequences.
`admins/{uid}` — set manually in console; client may only read its own doc to show an admin badge.
`users/{uid}/favorites/{bookId}` {addedAt} — optional bookmarks (owner only).

## UI / UX direction (premium, modern, easy)
Warm, calm, bookish-but-modern. Design tokens in `src/style.css` `:root` (light + `prefers-color-scheme`
dark + `[data-theme]` toggle). Fonts: Lexend (headings) + Atkinson Hyperlegible (body) via Google Fonts,
matching ../site. Accent a deep indigo/amber pair. Large rounded cards with soft layered shadows, generated
gradient "cover" per book (deterministic from title hash — no image uploads), smooth 150-250ms transitions,
skeleton loaders, empty states with a clear next action, focus rings, `prefers-reduced-motion` respected,
fully responsive (phone first), keyboard accessible, ARIA labels. Sticky bottom mini-player persists across
routes (hash router). Hero with search; filter chips (category, language, license); sort (new, top rated,
longest). Book page: cover, stars, provenance card ("How this audio was made"), license badge,
download button (+ "Open in Firebrat app"), chapter list that plays inside the page, comments, report /
copyright-notice / bug links. Submit page = 4-step wizard (Source -> Package check -> Details & provenance ->
Rights attestation & review) with inline validation and the A/B route choice up top.

## Firebrat app/PWA integration
- Deep link: `firebrat://community/book/<bookId>` and web `https://<host>/firebrat/community/#/book/<bookId>`.
- Book page "Open in Firebrat" button uses the custom scheme with web fallback.
- Download URL always points at IA so the existing import (zip) path works unchanged.

## Files (one owner per file when delegating)
src/firebase.js (init, auth helpers, Google + email sign-in) | src/ia.js | src/data.js (all Firestore
reads/writes, pagination, batch rating) | src/router.js | src/ui.js (tiny DOM helpers, toast, modal, stars,
cover generator) | src/player.js (audio + mini-player, media session, resume position in localStorage) |
src/views/{home,book,submit,about,legal,admin}.js | src/main.js | src/style.css | index.html | vite.config.js |
package.json | public/manifest.webmanifest + sw.js + icons | test/*.test.mjs

## Module API contract (all ES modules; workers must export EXACTLY these)
src/firebase.js: `auth, db, onUser(cb)->unsub, currentUser(), signInGoogle(), signInEmail(email,pw), signUpEmail(email,pw,name), signOut(), isAdmin()->Promise<bool>`
src/data.js (uses `serverTimestamp()`/`writeBatch`/`increment` per rules):
 `listBooks({category,language,license,sort:'new'|'top'|'long',search,after,limit=24})->{items:[{id,...doc}],cursor}` (search = client-side
 prefix/substring over the fetched page + tags; sort 'top' orders by ratingAvg desc computed client-side from page),
 `getBook(id)`, `createBook(id, fields)` (adds submitter/status/counters/timestamps),
 `getMyRating(bookId)`, `rateBook(bookId, value)` (batch: rating doc + book aggregate),
 `listComments(bookId,{after,limit=20})`, `addComment(bookId,text)` (batch: comment + commentCount+1),
 `deleteComment(bookId,cid)` (batch w/ commentCount-1), `reportItem({kind,bookId,commentId,reason,details})`,
 `reportBug({kind,bookId,page,message})`, `submitTakedown(form)`, `toggleFavorite(bookId)`, `listFavorites()`,
 admin: `adminList(coll,{status})`, `adminSetBookStatus(id,status)`, `adminHideComment(bookId,cid)`, `adminResolve(coll,id)`.
 All errors thrown as `Error` with a user-friendly `.message` (map `permission-denied` -> "You need to sign in" / "not allowed").
src/ui.js: `h(tag, props, ...children)` DOM builder (props: class, on*, dataset, aria-*, boolean attrs; children strings/nodes/arrays),
 `toast(msg,{kind})`, `modal({title,body,actions})->close`, `stars({value,count,editable,onRate})->HTMLElement`,
 `cover(book,{size})->HTMLElement` (deterministic gradient + initials), `badge(text,kind)`, `formatDuration(ms)`, `formatBytes(n)`,
 `timeAgo(ts)`, `skeleton(n)`, `emptyState({icon,title,body,action})`, `requireSignIn()->Promise<user>` (opens sign-in modal).
src/router.js: hash router `route(pattern, handler)`, `navigate(path)`, `start(outletEl)`; patterns `/`, `/book/:id`, `/submit`, `/about`,
 `/legal/:doc` (copyright|terms|privacy|takedown), `/report-bug`, `/admin`, `/favorites`. Handlers return an element or a Promise of one,
 get `{params, query}`.
src/player.js: `playBook(book, manifest, loc, sectionIndex)`, `togglePlay()`, `seek(sec)`, `setSpeed(r)`, `current()`, `onChange(cb)`,
 `mountMiniPlayer(el)`; section audio URL built via ia.js helpers; Media Session API; remembers `{bookId,section,time}` in localStorage.
src/views/*.js each `export default async function view(ctx) -> HTMLElement`.

## Design change (verified 2026-10-26): no cross-origin manifest fetch
archive.org `/download/...` does NOT send CORS headers, so browsers cannot `fetch()` manifest.json from IA
(metadata API `https://archive.org/metadata/<id>` and the S3 endpoint DO allow CORS; `<audio src>` needs no CORS).
Therefore: at submit time the manifest is read from the user's LOCAL file (route B: the zip they upload; route A:
they pick their local copy of the zip or manifest.json — "read in your browser only, not uploaded"). The book doc stores
`packageFile` (zip filename, '' for folder) and `chapters: [{title, durationMs, audioPath}]` (1..1500 items; rules-enforced
size only). The book page/player use `book.chapters` + `itemFileUrl(archiveId, {kind, zip}, audioPath)` and never fetch the
manifest. Route A additionally checks via the metadata API that the IA item really contains `packageFile` (or manifest.json)
with a similar size. ia.fetchManifest stays but is best-effort only.
