# Privacy and Data safety publication

The original draft was superseded on 23 October 2026 by the published pages:

- [Privacy policy](https://subhajit-roy-partho.github.io/firebrat/privacy/)
- [Data use and safety](https://subhajit-roy-partho.github.io/firebrat/data-safety/)
- [Account/data deletion requests](https://subhajit-roy-partho.github.io/firebrat/delete-account/)
- [Support and bug reporting](https://subhajit-roy-partho.github.io/firebrat/support/)
- [Conversion guide](https://subhajit-roy-partho.github.io/firebrat/help/)

Canonical editable sources are `frontend/firebrat_pwa/public/` and the app-footer
links in `frontend/firebrat_pwa/index.html`. The backend-served PWA build also
includes these pages. The `gh-pages` deployment preserves its existing PWA
bundle and adds the pages/footer plus a refreshed service-worker shell ID.
All five URLs returned HTTP 200 and the Pages deployment succeeded.

Play Console has saved the privacy URL, reviewer sign-in instructions and the
owner-approved 13–15, 16–17 and 18+ audience groups. The separate Play Console Data safety form was also saved on 23 October 2026.
It discloses optional account/book transfers and required SDK analytics collection,
including identifiers and approximate location. No universal encrypted-transit
claim is made because custom HTTP servers remain supported. User-initiated
transfers and service-provider processing are treated under Google's sharing
exemptions; this must be reassessed if provider settings or integrations change.
The in-app privacy/support entry is included in Android 1.6.3+26.

## Manual deletion-request operation

Requests go to the owner's public support inbox, `royduck@duck.com`. The website
prepares an email; it never sends one automatically. This is a manual request
process, not instant self-service deletion. The owner must monitor that inbox.

1. Verify control of the Firebrat account email before deleting anything. Never
   request a password, API key, private key, or access token. If the requester
   lacks email access, verify ownership through another appropriate channel.
2. Find the Firebase Authentication UID in project `firebrat-8c597`. Do not
   confuse the Google account with the Firebrat Firebase account.
3. Remove the user's `users/{uid}/library` documents in Firestore and any
   account document that exists. Removing the parent alone does not remove
   its subcollections. Then delete the Firebase Authentication user.
4. For hosted files, locate the specified book/job IDs and remove the upload,
   generated package and exposed shelf entry using the server controls. Jobs
   have no private per-user ownership, so identifiers may be necessary. Do not
   delete shared/public samples or another user's files by guessing ownership.
5. Explain that local files and personal Drive backups require their separate
   controls. Independently operated servers are controlled by their operators.
   Analytics/service logs follow provider/project retention settings; the app
   does not attach account email or Firebase UID to its custom analytics events.
6. Confirm completion by email and keep only the minimal necessary support
   record securely. Never commit deletion requests, account data or credentials.

The dedicated reviewer account must remain available throughout review. Do not
use it for a destructive account-deletion test.

## Disclosure references

- https://firebase.google.com/docs/android/play-data-disclosure
- https://support.google.com/analytics/answer/11582702
- https://support.google.com/googleplay/android-developer/answer/13327111

SDK disclosures include identifiers, app interactions and network-derived coarse
location. Do not declare "no data collected" merely because book conversion can
run offline. Configurable HTTP servers prevent a universal encrypted-transit
claim. No advertisements are included, although the Android analytics dependency
currently contributes the AD_ID permission.
