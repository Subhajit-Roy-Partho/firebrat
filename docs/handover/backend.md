# Backend hand-off (IAM, admin settings, queue control, scheduler controls) - 2026-10-26

## Changed (backend/**)
- `server/iam.py`: sqlite users/invites/audit/bootstrap; atomic first-admin bootstrap; legacy allowlist materialised as admin rows; verified-email admin bootstrap and invite claim; invite update/revoke; last-admin protection.
- `server/auth.py`: `require_role(*roles)`; allowlist not enforced when IAM on. `routes/{admin,jobs,books,profile,settings}.py`: role/owner enforcement, endpoints per INTEGRATION2 ("As built" section there lists final shapes and the one deviation: ownerless pre-IAM jobs are admin-only).
- `server/server_settings.py`: rewritten to use `firebrat_cast/catalog.py` only (fallback catalog removed), atomic write, defaults per Decisions. `server/cast_bridge.py`: `build_env()` exports `FIREBRAT_SETTINGS_FILE`, cancel flag + priority file helpers.
- `firebrat_cast/scheduler.py`: fixed clock hooks with default args (quiet-hours bug), defaults (cap 4), fifo = arrival order, priority file, cancel flags, per-book pause check, `cancelled` in status. `catalog.py` unchanged.
- Tests: `tests/test_iam.py`, `tests/test_admin_settings.py`, `firebrat_cast/tests/test_scheduler_settings.py` extended (the 3 known failures fixed: clock hook bug, fifo semantics, settings-file location per Decision 2).

## Verification
`cd backend && python3 -m pytest tests firebrat_cast/tests -q` -> 270 passed, 2 skipped, 4 failed. The 4 failures are pre-existing environment gaps (pydub, firebase_admin, pypdf not installed; chatterbox test needs pydub).

## Not done / not verified
- `limits.max_cast_chars` stored, not enforced. Nothing run against live Firebase tokens, a real scheduler process or the GPU server; supervisor env passing only unit-checked via `build_env()`.
- Cancel/priority act between books/stages; a stage already running is not interrupted.
- Another writer touched `test_scheduler_settings.py`/`scheduler.py` area while I worked (mtimes changed mid-session); re-run the tests before committing.

## Gotchas
- With IAM on a signed-in uid with no role gets 403 on everything except `/me` and bootstrap.
- Tests override `auth.require_user`; `require_role` depends on it so overrides still work.

## Next
Enforce `max_cast_chars` in the scheduler fetch stage; live smoke test of bootstrap + PUT /admin/settings -> scheduler reload on the GPU server.
