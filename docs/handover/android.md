# Android handover (frontend/firebrat_app) - IAM + server administration

## Changed
- Unified two competing partial implementations on ONE stack: `lib/models/server_admin.dart` (MeProfile, AdminUser, AdminSettings, QueueStatus, ...),
  `ApiClient` methods (getMe, bootstrapSetup, listAdminUsers (merges unclaimed `invites`), inviteUser, updateUser, removeUser, getAudit,
  get/putAdminSettings, getQueue, pause/resume, cancelQueuedBook, prioritizeQueuedBook, `friendlyAdminError`, `dio` test seam),
  `lib/state/server_admin_providers.dart` (serverAdminProvider, meProvider, canUploadProvider, showAdminSectionProvider, needsSetupProvider, admin data providers).
  Deleted `services/server_admin_service.dart` and `state/iam_providers.dart`.
- `lib/app.dart`: `_Home` calls GET /me after sign-in (cloud mode only), re-probes on server-URL change, auto-pushes ServerSetupScreen once when needs_setup. Sign-out clears the profile (app_drawer).
- `screens/server_setup_screen.dart`, `screens/server_admin_screen.dart` (Users / Models / Run pattern / Queue; queue polls every 5 s), entry points in conversion settings and drawer (admin only).
- `conversions_screen.dart`: viewers see "Your account can only listen", no FAB; 'Expressive voices' follows cast_available and role; stale cast choice is blocked with a message; 403 friendly text.
- Shapes coded to routes/admin.py as of now: users `{users, invites}`, audit `{audit}`, settings `options.llm.models|quantizations`, `options.tts.engines`, PUT returns `{values}`, queue `{scheduler:{books,detail}, paused}` (also tolerates flat books/items/jobs).

## Verified (Mac)
- `flutter analyze`: No issues. `flutter test`: 138 passed (119 old + 19 new: models, fake-Dio-adapter API tests, role gating, setup/admin screen layout incl. 320px/2x text).

## Not verified / gaps
- Never run against a live server or on a device. The "As built" section of INTEGRATION2.md did not exist when I checked; no mismatch found vs routes/admin.py/server_settings.py.
- ConversionsScreen viewer gating is only covered at provider level (widget tests cannot sign in: AuthService.currentUser is null in tests).
- Legacy admin = role 'admin' while iam_enabled false; but backend admin routes 404 when IAM is off, so the admin screen would show load errors there.
- Queue book rows have no title from the server (slug shown).

## Gotchas
- I accidentally ran `dart format` on all of lib/ and test/ (tall style differs from repo style), then restored files from HEAD / 3-way merged (read-only `git show` + `git merge-file` on scratch copies; no git state changed). conversions_screen.dart, api_client.dart, server_books_providers.dart, app_drawer.dart may carry small whitespace-only reformat hunks. Do NOT run `dart format` on the whole tree.
## Next
- Test against a live IAM server; add widget test for setup flow success; consider a title field in queue rows.
