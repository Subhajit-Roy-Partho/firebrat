# Server administration: accounts, roles (IAM), and device-controlled settings

Builds on INTEGRATION.md. Everything additive and OFF by default so existing deployments (shared-server policy, or
FIREBRAT_ALLOWED_USER_IDS) keep working unchanged. Enabled with env `FIREBRAT_IAM=1`.

## Accounts and roles
- Identity stays Firebase Auth (ID token verified by backend/server/auth.py; require `email_verified` when an email is used for matching).
- Store in sqlite (`<data>/iam.sqlite3`, same dir as jobs db): `users(uid PK, email, name, role, status 'active'|'disabled', created_at, invited_by, last_seen)`,
  `invites(email PK, role, invited_by, created_at, claimed_uid)`, `audit(id, at, actor_uid, action, target, detail)`.
- Roles: `admin` (everything), `user` (upload incl. cast mode, own jobs, own delete), `viewer` (listen only, no uploads). Not signed in = public read as today.
- First-run setup: when IAM is on and no admin exists, the server creates a one-time 10-char setup code, stores only its hash, and prints it once to the server log
  (and `<data>/SETUP_CODE.txt` mode 0600, deleted after use). The first signed-in account to `POST /admin/bootstrap {code}` becomes admin (rate-limited, constant-time compare, 5 tries
  then 10-minute lockout). Afterwards bootstrap returns 410. Env `FIREBRAT_ADMIN_EMAILS` (comma list, verified emails) is an alternative bootstrap. Legacy env `FIREBRAT_ALLOWED_USER_IDS` entries are treated as admins when the IAM table is empty.
- Invites: admin pre-authorizes `email + role`; when that verified email first signs in, `GET /me` links the uid and activates the user. Admins can change role, disable/enable, delete users; the last active admin cannot be demoted/disabled/deleted.
- Jobs get `owner_uid` (new nullable column via the same migration pattern as content_mode). Users see their own jobs; admins see all. Deleting a book: owner or admin.

## Endpoints (all require auth except as noted; admin = role admin)
- `GET /me` -> `{uid,email,name,role|null,iam_enabled,needs_setup}` (works without a role; needs_setup true only when no admin exists).
- `POST /admin/bootstrap {code}`.
- `GET /admin/users`, `POST /admin/users {email, role}` (invite), `PATCH /admin/users/{uid|email} {role?,status?}`, `DELETE /admin/users/{uid|email}`, `GET /admin/audit?limit=`.
- `GET /admin/settings` -> `{values, options, availability, notes}`; `PUT /admin/settings {values}` (validated, persisted to `<data>/server_settings.json`, atomic, audit-logged).
- `GET /admin/queue` -> scheduler status + per-book stages; `POST /admin/queue/pause|resume`; `POST /admin/queue/{slug}/cancel`; `POST /admin/queue/{slug}/priority {top:true}`.
- Existing mutating routes enforce role when IAM is on (upload: user+, jobs list/detail: owner or admin, delete: owner or admin). `GET /settings` stays public and keeps `cast_available`; add `iam_enabled`.

## Settings (values; every choice is picked from a server-defined catalog, never free text; options include `vram_gb`, `description`, and `available` = weights already in the local HF cache)
```
llm:  {model: 'qwen3.5-9b' | 'qwen3.5-4b', quantization: 'fp8'}
tts:  {engine: 'qwen3-tts-1.7b' | 'qwen3-tts-0.6b' | 'chatterbox'}
run_pattern: {phase_mode: 'batched' | 'sequential',   # batched = all queued books cast together, then audio; sequential = one book end to end
              max_books_per_llm_phase: int 1..20, audio_order: 'shortest_first' | 'fifo',
              paused: bool, quiet_hours: null | {start:'HH:MM', end:'HH:MM'}}   # GPU work only inside allowed hours when set
limits: {max_upload_mb: int, max_cast_chars: int}
```
The scheduler re-reads `server_settings.json` before every phase (hot reload via a settings provider hook) and honours `paused`; no restart needed. Invalid files fall back to defaults with a logged warning.

## Clients (PWA and Android; same behaviour)
- After sign-in call `/me`. If `needs_setup`: show "Set up this server" asking for the setup code, then continue as admin.
- Non-admins never see admin UI. Admin UI = Settings -> "Server administration": Users (list, invite by email + role, change role, disable, remove), Models (the three selects above with VRAM hints and "weights not downloaded" warnings), Run pattern (controls above), Queue (live status, pause/resume, cancel, move to top).
- Role-aware upload UI: viewers see "Your account can only listen"; users see upload; the cast option follows `cast_available` and role. 403 -> friendly message.
- Never break existing behaviour when `iam_enabled` is false: no setup prompt, no admin section (unless the account is the legacy admin).
## Tests
Backend: bootstrap (code, lockout, 410 after), invites + claim, last-admin protection, role enforcement on upload/jobs/delete, owner_uid scoping, settings validation (reject unknown values) + hot-reload by a fake scheduler hook, queue controls with fake scheduler status. PWA: helper tests for role/setup logic + build. Flutter: analyze + tests for models/api methods.

## Decisions (lead, supersede anything above that disagrees)
1. `quiet_hours` {start,end}: the window in which NO new GPU phase starts (the name means what it says; overnight windows like 22:00-06:00 wrap midnight). CPU prefetch still runs. UI label: "Quiet hours (no GPU work)".
2. Settings file: the server writes `<data>/server_settings.json`; when it launches the scheduler it exports `FIREBRAT_SETTINGS_FILE` pointing at that exact path. The scheduler reads `FIREBRAT_SETTINGS_FILE`, else `<root>/server_settings.json`. Nothing else.
3. Defaults: `max_books_per_llm_phase` = 4, `audio_order` = shortest_first, `phase_mode` = batched, `paused` = false, quiet_hours = null.
4. `firebrat_cast/catalog.py` is the single model catalog (server_settings.py and scheduler.py both import it).

## As built (backend, 2026-10-26) - code against this
No endpoint shape from the contract changed. Details and deviations:
- **Flag:** everything is off unless `FIREBRAT_IAM=1`. Off: `/admin/*` -> 404, `/me` returns `{uid,email,name,role:null,iam_enabled:false,needs_setup:false,...}`, no role checks, `FIREBRAT_ALLOWED_USER_IDS` enforced as before. On: the allowlist is NOT enforced (roles replace it); its uids become admin rows (while no admin exists) and skip the setup code.
- **`GET /me`** (IAM on) also returns `status` ('active'|'disabled'|null). It claims a pending invite (verified email only) and applies `FIREBRAT_ADMIN_EMAILS` bootstrap (verified emails) automatically. Role-less or disabled -> `role:null`.
- **`POST /admin/bootstrap {code}`**: 200 -> the admin user view; 403 wrong code; 422 missing/oversized code; 429 locked (5 failures -> 10 min); 410 once an admin exists. Code: 10 chars from `A-Z2-9` (no 0/O/1/I/L), compared case-insensitively; hash-only in sqlite; plain text only in the server log once and `<data>/SETUP_CODE.txt` (0600, deleted after use).
- **Users:** `GET /admin/users` -> `{users:[{uid,email,name,role,status,created_at,invited_by,last_seen}], invites:[{email,role,invited_by,created_at,claimed_uid}]}`. `POST /admin/users {email,role}` -> invite row (409 if already a user, 422 bad email/role). `PATCH /admin/users/{uid|email}` `{role?,status?}` (a pending invite accepts only `{role}` and returns the invite row). `DELETE` -> `{deleted: uid|email}` (revokes a pending invite when no user matches). Last active admin cannot be demoted/disabled/deleted (409).
- **Audit:** `GET /admin/audit?limit=1..500` -> `{audit:[{id,at,actor_uid,action,target,detail}]}`; actions: bootstrap, legacy_admin, invite, invite_update, invite_delete, claim, user_update, user_delete, settings_update (also used by queue pause/resume), queue_cancel, queue_priority.
- **Settings:** `GET /admin/settings` -> `{values, options, availability, notes}`; `options.llm.models[]` / `options.tts.engines[]` entries `{id,name,vram_gb,description,available}`; `availability` = `{llm:{id:bool}, tts:{id:bool}}`. `PUT /admin/settings {values}` accepts a partial per-section merge, validates the whole (unknown section/key/model -> 422), `limits.max_upload_mb` is enforced on uploads when IAM is on; `limits.max_cast_chars` is stored but NOT yet enforced.
- **Settings file:** `<dir of FIREBRAT_JOBS_DB>/server_settings.json`, atomic (tmp+fsync+replace). The supervisor starts the scheduler with env `FIREBRAT_SETTINGS_FILE=<that path>` (`cast_bridge.build_env()`; argv from `build_command` is unchanged). Scheduler: `$FIREBRAT_SETTINGS_FILE` else `<cast root>/server_settings.json`; missing file leaves CLI flags untouched; invalid file -> defaults with a warning.
- **Scheduler:** re-reads settings every loop tick and before each LLM/audio phase; `paused` also stops a running snapshot after the current book; `quiet_hours` blocks only NEW GPU phases (CPU prefetch continues); `audio_order=fifo` = inbox arrival order (file mtime); default cap `max_books_per_llm_phase`=4. Controls from the server: `<cast root>/priority.json` `{"top":[slugs]}` (front first) and marker files `<cast root>/cancel/<slug>`; status file queue gained `cancelled`.
- **Queue:** `GET /admin/queue` -> `{scheduler:{available,running,detail,status,books:[{slug,stage,detail,progress,terminal,error}]}, paused}`; `POST /admin/queue/pause|resume` -> `{paused}`; `POST /admin/queue/{slug}/cancel` -> `{slug,cancelled_job,removed_inbox}` (404 unknown); `POST /admin/queue/{slug}/priority {top:true}` -> job view plus `paused_jobs` (cast books: writes priority.json; others: promote_now; 409 for finished jobs).
- **Role rules (IAM on):** upload needs user/admin (viewer 403 with "only listen" text; checked before payload validation); `/jobs*` need any active role; retry/resume/convert-now need user+; jobs visible/deletable by owner or admin only. **Deviation:** jobs created before IAM (empty `owner_uid`) and books without a job owner are ADMIN-ONLY (previously shared). `POST /settings` (global defaults) is admin-only. Missing role -> 403 "no role on this server".
