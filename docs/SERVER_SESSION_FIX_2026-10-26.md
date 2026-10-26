# Server mutation investigation — 26 October 2026

Two different compatibility problems were found:

1. The browser control room stored a Firebase ID token once at sign-in. Firebase tokens expire after approximately one hour, so a tab left open could continue browsing the public shelf while upload, deletion and queue requests failed with 401. The web client now asks the Firebase User SDK for a fresh token for each request, retries a 401 once with forced refresh, and uses the same request helper for multipart uploads. It does not retry network/server errors or 403 responses. Refresh failures do not send an unsigned mutation. Signed-out queue display no longer generates a failing authenticated poll every five seconds.
2. The deployed review server is substantially older than the current Android app. Its live OpenAPI schema includes `DELETE /books/{book_id}`, but only `GET /jobs/{job_id}`. Current Android uses `DELETE /jobs/{job_id}` to remove conversion history, so this operation cannot work against that deployment. `/models` and newer ebook/model upload fields are also missing. Source `master` already implements these APIs. This gap was addressed by the bounded API deployment described below; copying the whole repository over the remote checkout would have overwritten its uncommitted conversion-pipeline adaptations.

## Applied change

- Source: `backend/server/static/app.js`.
- Behavior tests: `node --test backend/tests/web/auth_session.test.cjs` — six passed.
- JavaScript syntax check: passed.
- The tested web client was deployed to the existing review server without changing authentication requirements, allowlists, CORS or API processes. The previous file is retained remotely at `runtime/mutation-test-retained/app-before-token-refresh-20261026.js`.
- Public `/static/app.js` bytes match the tested source. Reload an old server tab to obtain the fix; its JavaScript cannot be replaced inside an already-open page.

## Live verification

- Normal existing reviewer Firebase sign-in: passed.
- Authenticated `/jobs`: 200.
- Anonymous deletion of a newly created empty test-only package: 401.
- Authenticated deletion of that package: 200; subsequent manifest request: 404.
- Recovery copy of this disposable package remains under `runtime/mutation-test-retained/firebrat-session-delete-check-20261026`.
- No actual user book, original upload, or existing conversion was deleted. Digital Design remains on the shelf.
- Authenticated public-domain three-page PDF upload accepted as job `d4ca5c6445e24ca7`, book `server-session-regression-check`.
- That job completed in 122 seconds (09:29:55–09:31:57 UTC): 3 sections, 3 figures, no pipeline error, zero `needs_review` flags. Its files and job are retained.

These checks establish that current PDF upload and direct book deletion API work with valid authorization. They do not establish that a stale Android client, an expired browser session, ebook uploads, or conversion-history deletion all work against the old deployed API. The browser refresh behavior is covered with simulated token expiry; no real account session was kept open for an hour as part of this check.

## Bounded API upgrade applied

The compatibility gap above was subsequently addressed for ordinary PDF conversion and current Android job controls. The idle API was restarted after an isolated staging run: **38 focused Python API tests passed**, covering authentication, queue/concurrency/cancellation, settings, profile, desktop controls and unsupported-engine guards. The six JavaScript session tests also passed. Tests used `GCE_METADATA_TIMEOUT=0` to avoid real cloud metadata delays in keyless FCM. An initial broader staging run also exercised the deliberately preserved old ebook compiler; its modern chapter-title expectation failed, which is why ebook capability remains disabled on this deployment rather than being claimed as supported.

- Snapshot: remote `runtime/api-upgrade-snapshot-20261026/` contains the previous server code, SQLite backup, settings and private launch environment (restricted permissions).
- Updated only server Python modules; added standard-library-only `ebook.py` and `character_traits.py` support imports. Existing customized `convert.py` and `compile_llm.py` are byte-for-byte unchanged, verified against the snapshot SHA-256 records.
- The old customized converter cannot handle ebook extraction or research/trait CLI flags. Both capabilities are explicitly disabled for this server. `/settings` reports them as false, and the API returns clear 501 guidance **before storing files or enqueueing work**. Ordinary PDF/ZIP and existing novel conversion remain available.
- API restart command for this deployment: `python3 /home/roy/Github/firebrat/runtime/api-upgrade-launcher-20261026.py` inside the `firebrat-api` tmux session. It preserves the private original environment and the capability restrictions. The server still needs a supervised service/restart after host reboot; no system service was added in this change.
- Public health: 200. Authenticated `/models?provider=local`: 200, one live local model. OpenAPI now exposes `DELETE /jobs/{job_id}`.
- A separate newly created finished-job fixture was backed up outside the shelf, then deleted through the modern endpoint: anonymous request 401, authenticated request 200 with its own upload/package removed, repeat request 404, and its manifest 404. Digital Design manifest remained available. The fixture recovery copy is under `runtime/mutation-test-retained/api-job-delete-fixture-20261026/`.
- Live EPUB/research guards returned 501 and left the job ID set unchanged.
- Fresh post-upgrade PDF conversion job `f8b4a75c918f497f` completed in **125 seconds** (09:43:12–09:45:17 UTC): 3 sections, 3 figures, 28.96 seconds of narration, zero errors and zero review flags. Downloaded ZIP CRC, all audio/image references and segment timing ranges passed. Package SHA-256: `c3ec6cf920c3ce707d7d5c1154dcddbc736a5afb17c475eefa183002f64b07bd`. Its package and job are retained. No existing book/job was deleted to perform this check.

A future complete converter update can enable ebook and trait capabilities after merging and testing the remote custom pipeline adaptations. The API is not advertised as having completed that separate engine upgrade.
