# IAM security-review fixes (backend)

All changes are backward compatible with `FIREBRAT_IAM` unset; endpoint
shapes used by the PWA/Android apps are unchanged. Regression tests:
`backend/tests/test_iam_security.py` (one or more per finding).

1. **Invite resurrection (HIGH)** - `claim_invite` refuses invites with a
   non-empty `claimed_uid`; `delete_user` deletes the invite in the same
   transaction; `update_user` keeps a claimed invite's role in sync; a fresh
   `create_invite` resets `claimed_uid`.
2. **book_id / upload collisions** - book ids are unique against job rows
   too; uploads are stored at `UPLOAD_DIR/<job_id>.<ext>`; cast slugs are
   normalised before the uniqueness check (and uniqueness is checked on the
   normalised slug). `jobs.create_job` accepts an optional `job_id`.
   Residual: two truly simultaneous uploads of one name could still race
   between the check and `create_job` (files no longer collide).
3. **Last-admin race** - count, check and write run in one `BEGIN IMMEDIATE`
   transaction (`update_user`, `delete_user`).
4. **Bootstrap lockout** - atomic counters in one transaction; per-uid limit
   (5 tries / 10 min) plus a global limit (25 tries / 10 min), both persisted.
5. **Avatar and `/models`** - require an active role when IAM is on.
6. **Setup code** - minted, hashed (salted PBKDF2) and written to
   `SETUP_CODE.txt` under one write transaction; old unsalted hashes still
   verify but are re-minted by `ensure_setup_code`.
7. **Concurrent first sign-in** - `claim_invite` is transactional and
   tolerates `IntegrityError`.
8. **Audit** - new actions: `settings.update`, `job.retry`, `job.resume`,
   `job.convert_now`, `job.delete`, `book.delete` (admin acting on someone
   else's job/book), `bootstrap.failed`, `bootstrap.locked` (never contain
   the submitted code). `iam.safe_audit` is used after mutations so audit
   failures are logged instead of returning 500.
9. **Validation** - unhashable `llm.model` / `tts.engine` -> 422;
   `POST /settings` validates `default_chunk_pages` and writes atomically;
   `tail_lines` clamped to 1..2000; non-admin model ids limited to the
   catalog when IAM is on; job error text no longer shows the log path;
   admin slug routes accept only `[A-Za-z0-9_-]` and use the normalised slug
   (`..` rejected); `--title=` / `--character-trait=` argv form.

`POST /settings` with IAM unset: `require_role("admin")` is identical to
`require_user` when IAM is off, so behaviour is unchanged apart from the new
422 for a non-integer `default_chunk_pages`.
