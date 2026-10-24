# Android metadata and reading checkpoint sync

The Play Android client stores only small per-user Firestore documents. Book
packages stay on device, on the chosen server, or in the user's Google Drive.
No Firebase Storage is used. Native Apple and PWA clients do not yet implement
this new Android checkpoint protocol.

## Storage and access

- `users/{uid}/library/{bookId}`: title, source, optional SHA-256, Drive file ID,
  backup size, section count/duration, update/open timestamps.
- `users/{uid}/progress/{bookId}`: narration section ID, audio position in ms,
  client timestamp, conversion signature and server timestamp.
- Local checkpoints use account-scoped SharedPreferences keys. Guests use a
  separate scope, create no account and send no checkpoints to Firestore.
- Rules in `firebase/firestore.rules` allow only the authenticated owner and
  validate an explicit field whitelist, types, sizes and timestamp bounds.
  Other collections, anonymous access and cross-user access are denied.
- PDF-only chapter page positions are not part of the narration checkpoint
  protocol. Metadata/Drive backup can still transfer their packages.

The deployed project is `firebrat-8c597`, Standard `(default)` database in `nam5`.
It remains on Spark; no billing, Storage, paid backups, TTL, or Functions were
enabled. Production rules were published with owner approval on 24 October 2026.
Live REST verification passed own metadata write/read and progress write;
anonymous read, cross-user read, book-file fields and malformed progress were
rejected with HTTP 403. Test records use the reviewer account and public sample
identifiers; no private book content was uploaded by this verification.

## Progress behavior

Local saves occur approximately every five seconds and on pause/section change.
Cloud attempts are normally two minutes apart; pause/section changes have a
15-second minimum and queue the latest checkpoint if another upload is pending.
A failed upload leaves the local checkpoint durable. **Sync metadata** retries
pending checkpoints after reconnecting. There is no permanent listener or
per-playback-tick cloud write.

On opening an audiobook, the client compares local and remote timestamps and
restores the newest checkpoint matching its conversion signature. Playback
stays paused. The signature hashes the ordered section IDs and durations; it
prevents most mismatched-conversion seeks, but is not a full book-content hash.
Devices need reasonably synchronized clocks. Transactions reject delayed
checkpoints older than the stored checkpoint. This intentionally allows moving
backwards in a book rather than always choosing the furthest position.

## Drive transfer

Menu → **Sync & backup** exposes metadata sync and per-book backup/restore.
Drive uses incremental `drive.file` authorization and the same Google account as
Firebase sign-in. Email-only accounts can sync metadata/progress but must sign
in with Google to transfer Drive files. Folder IDs are cached per Firebase UID.
Backups are ZIPs streamed from disk; uploading again replaces the same app
backup. Interrupted uploads retry from the beginning. Downloads retain a partial
file and request remaining bytes. Restores validate size, recorded SHA-256 and
manifest book identity before extraction; complete local books are preserved.

Backing up is explicit, so metadata-only records cannot magically download
books without a recorded Drive backup. A second device must authorize the same
Google account and have access to those app-created Drive files. Account signout
clears the remembered Google account. No server API keys or OAuth tokens are
included in metadata or package backups.

## Free-tier controls and limitations

Fetches are limited to 200 cloud library entries. Client sync attempts are
limited to 500 writes per account/device per UTC day. This is a client courtesy
limit, not protection against modified clients; strict per-user rate limiting
would require additional infrastructure. Transaction reads/retries also consume
quota. Firebase's free quotas are shared across the entire project, including
all users and devices. Spark exhausts quota rather than automatically charging;
local reading continues when sync is unavailable. Never switch to Blaze as a
routine workaround for quota errors.

See [official Firestore quotas](https://firebase.google.com/docs/firestore/quotas).
Do not promise unlimited free sync or large-library completeness above the
current 200-record fetch cap. Disable future sync in the screen's toggle;
existing cloud records require the account/data-deletion request process.
Deleting an Auth user or parent document alone does not remove subcollections:
remove both library and progress records after verifying account ownership.
