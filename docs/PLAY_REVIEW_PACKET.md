# Firebrat — complete Google Play review draft

Prepared 24 October 2026 (America/Phoenix). **Owner approval is required before
sending to Google. Nothing in this packet authorizes submission or rollout.**

## Where to inspect the draft

- [Publishing overview — all pending changes](https://play.google.com/console/u/0/developers/7776694949420468110/app/4972270228784845315/publishing)
- [Closed Alpha release draft](https://play.google.com/console/u/0/developers/7776694949420468110/app/4972270228784845315/tracks/4700362287512119092/releases/1/prepare)
- [Store listing](https://play.google.com/console/u/0/developers/7776694949420468110/app/4972270228784845315/store-listings)
- [Policy declarations](https://play.google.com/console/u/0/developers/7776694949420468110/app/4972270228784845315/app-content/overview)
- [Reviewer sign-in details](https://play.google.com/console/u/0/developers/7776694949420468110/app/4972270228784845315/app-content/testing-credentials)
- [Foreground-service evidence](https://play.google.com/console/u/0/developers/7776694949420468110/app/4972270228784845315/app-content/foreground-services)

Application ID: `com.firebrat.firebrat_app`. Saved draft: **1.6.4+27**.
This is a **closed-test review**, not a production release. The prior internal
release remains separate. At the live dashboard check there were **0 closed
opt-ins**; production access needs at least **12 opted-in testers for 14
continuous days**. The selected track regions are India, UK and US.

## Evidence attached or prepared

| Feature | Evidence | Status |
| --- | --- | --- |
| Server download and background narration | [Redacted playback/download demo](https://subhajit-roy-partho.github.io/firebrat/review-demonstrations/#download-playback) | Saved in network DATA_SYNC and MEDIA_PLAYBACK declarations |
| On-device background conversion | [Redacted local-conversion demo](https://subhajit-roy-partho.github.io/firebrat/review-demonstrations/#local-conversion) | Saved in local DATA_SYNC declaration |
| Explicit Drive backup and completion | [Redacted Drive backup demo](https://subhajit-roy-partho.github.io/firebrat/review-demonstrations/#drive-backup) | Saved in backup/restore DATA_SYNC declaration; Pages deployment 40154666121 passed; browser playback verified |
| Drive restore | All **18** restored public-sample files match the retained original byte-for-byte | Live phone verification passed |
| Cloud reading checkpoint | A newer cloud checkpoint was set through Firebase Console; a fresh app session restored section 3 at **00:01**, overriding its older local checkpoint | Live SDK/Firestore restore passed; not a claim of two physical devices |
| Background media playback | Android reports the audio service foreground, type `0x2` | Live phone verification passed |

The public service recordings are silent; they demonstrate service behavior,
not an audio-quality benchmark. Local conversion may reuse cached inference.
The new raw `play_review_media_playback.mp4` contains private notifications and
**is excluded from Console evidence**. It is already in the owner's earlier
public repository commit; no history deletion was attempted. Use the existing
redacted playback recording for review. Originals and phone test files remain
preserved until publication, per the owner's instruction.

## Store and policy draft

- App name Firebrat; category Books & reference; support `royduck@duck.com`.
- Listing text now explicitly explains Continue as guest, compatible-model
  downloads, illustrated/novel conversion, local Kokoro/system narration,
  private metadata/progress sync and user-owned Drive packages.
- One icon, one feature graphic and three phone screenshots are present. The
  listing's AI-asset labeling option is selected. Listing is saved and ready
  to send for review.
- App content reports **11 actioned declarations** and no outstanding policy
  declaration tasks. Audience is **13+**. No ads, government, financial or
  health features are claimed. Analytics advertising-ID use remains declared.
- [Privacy](https://subhajit-roy-partho.github.io/firebrat/privacy/),
  [data use](https://subhajit-roy-partho.github.io/firebrat/data-safety/),
  [deletion requests](https://subhajit-roy-partho.github.io/firebrat/delete-account/),
  [conversion guide](https://subhajit-roy-partho.github.io/firebrat/help/) and
  [support](https://subhajit-roy-partho.github.io/firebrat/support/) are public.
- Guest mode does not create an Authentication account, but does not disable
  the disclosed analytics SDK. Do not claim “no data collected.” Configurable
  HTTP servers mean a universal encrypted-transit claim would be inaccurate.
- Account deletion is a **manual, verified request process**, reachable inside
  the app under Privacy & support → Request account deletion and on the website.
  It is not immediate automatic deletion. The owner must monitor the support
  inbox and remove both Firestore subcollections plus Authentication data;
  see `PLAY_PRIVACY_DRAFT.md`. No real/reviewer account was deleted as a test.

## Reviewer access

Two credential sets are saved **only in Play Console**. No password belongs in
this file, public docs, video, screenshots or source control.

1. The email reviewer account accesses authenticated server conversion. It has
   no OTP and uses the HTTPS review server. Guest can read/import/local-convert
   after model setup and download the public sample.
2. The dedicated Google test account is for Drive and metadata/progress sync.
   Instructions now explicitly say to sign out of the email account and sign
   in to Firebrat **with that Google account first**, then authorize matching
   Drive access. Mixing Firebase email login with another Google Drive identity
   correctly fails. No password was changed. Google challenge/OTP behavior on
   a new review device has not been independently established.

Google Auth Platform was checked live: audience is **External / In production**,
so there is no testing allowlist restriction. The app requests `drive.file`
for app-created/selected files, not whole-Drive access. The Console scope lists
are empty; no sensitive or restricted scope is declared there. Successful
matching-account Drive backup and restore were verified on the phone.

The review server is
`https://firebrat-review-server.rohu-hexatonic.ts.net`. Fresh normal reviewer
sign-in passed, `/health` and authorized `/jobs` returned 200, and the sample
job remains completed with no pipeline error. Its three sections, three figures
and 27.84 seconds of narration remain available. The public shelf is shared;
private books must use a private server. The server currently survives SSH
disconnects through tmux but needs service restart after a host/container reboot.
Keep it running throughout review.

## Code and device checks

- Reviewed the owner's Drive reconciliation and Play Integrity additions from
  `9bc39ad` and evidence/handover from `f5fa297`.
- Fixed release-only attestation blocking: without an explicitly configured
  verifying backend, authenticated server/Drive features work normally in
  release builds. Token minting remains available when configured. Firebase,
  Drive OAuth and server authorization are unchanged. A token by itself is not
  verification; server-side integrity verification remains unimplemented.
- Corrected native Integrity SDK error numbers, preserved preparation errors,
  and removed the unsupported promise of automatic queued retry.
- Corrected manual release version stamping so the About label reflects the
  app version, not the branch name.
- `flutter analyze`: clean. **70 Flutter tests passed**, including account
  matching, attestation configuration policy, ZIP identity/completion, guest
  access, checkpoint conflicts/isolation and complete backup bytes.
- Source PDF reopened page 3/3 without the former slider assertion.
- Corrected debug APK built and installed with `adb install -r`; no uninstall
  or app-data clear. The original Digital Design book remains, and the sample's
  old folder is separately retained under `files/retained-sync-test/`.
- The Pixel uses **4 KB** pages. Static native-alignment validation and a
  separate **16 KB runtime** check are distinct; do not conflate them.
- Spark remains **$0/month**. Live owner-only Firestore tests allowed valid own
  metadata/progress and rejected anonymous, cross-user, book-file fields and
  malformed progress with 403. No Firebase Storage or billing upgrade.

## Final preparation status

- Signed current-code APK/AAB workflow **40154211894**: **passed**, source `2044188`. Manifest confirms **1.6.4+27**, min SDK 28, target SDK 36. Bundletool validation, all 28 64-bit ELF libraries and APK ZIP alignment passed; bundle config requests `PAGE_ALIGNMENT_16K`.
- The current signed AAB **27 (1.6.4)** is uploaded, saved and previewed in the existing closed Alpha track. The preview reports **Ready to release**, with no artifact errors shown. Play estimates a 39.7 MB device-specific initial download. All **13 pending changes** are now together in Publishing overview, **not submitted for review**. Automatic pre-submission checks are running.
- Play-installed artifact login/Drive behavior is separate from debug testing.
  Preserve phone data; do not uninstall simply to swap signing channels.
- Exact CI-signed release installed on an isolated Android 16 emulator with **16,384-byte pages**, `bionic.linker.16kb.app_compat.enabled=false` and `pm.16kb.app_compat.disabled=true`. Guest launch, ZIP import, three-section reader, advancing audio playback, foreground media service (`0x2`) and rendered source PDF page 3/3 passed. Crash buffer remained empty. This is a focused runtime smoke test, not all-model inference or a Play-delivered signing-channel test. Emulator audio output was disabled; audio quality was not assessed there.
- Final Console preview saved to Publishing overview without submitting or rolling out. Managed publishing is currently off; after an authorized future submission, approved changes can publish automatically to the selected closed track. This does not open production.
- Signed release email reviewer sign-in and HTTPS server shelf access passed. A real server conversion upload completed as job `4e9af6244bf241e1` in **124 seconds** (02:50:08–02:52:12 UTC, 25 October). The signed app displayed Done: three sections, three figures, 28.52 seconds of audio, zero errors and zero `needs_review` flags. Downloaded ZIP CRC, all image/audio references and segment ranges passed. Package SHA-256: `0aa04c8b6bc44bd1ccd8bdc052ea574e7562a4e3ce5cd4924c2d4e1fdd255737`.
- The phone's original plugged-in sleep setting (`0`) has been restored. All its books, imports and test files remain preserved.
- Obtain the owner's final signal only after this packet and attached evidence
  are ready to inspect. Google approval is never guaranteed by these checks.

## Exact store listing copy

**Name:** Firebrat

**Short description:** Read and listen to your books, with offline playback and local PDF conversion.

Firebrat brings reading and listening together for your own books.

READ AND LISTEN OFFLINE
Import a Firebrat book package and keep its narration, sections and visuals on your device. Downloaded books can be read and played without a server or account. If a sign-in screen appears, choose Continue as guest. Choose list, small-card or large-card library views.

CONVERT YOUR PDFS
Choose on-device conversion for local processing, or connect to a Firebrat server running on your computer. Local conversion requires downloading compatible language and voice models first; processing speed and quality depend on your device, model and PDF. Optional cloud helpers require an internet connection and send content to the configured service.

ILLUSTRATED BOOKS AND NOVELS
Illustrated and technical book mode supports figures and formulas alongside narration. Novel mode offers character voice casting and male/female voice choices. Review generated text, character assignments and figure placement against the original PDF.

CHOOSE YOUR NARRATOR
Use Android speech voices or download Kokoro for local neural narration. Books converted on a server retain the narration generated there.

OPTIONAL ONLINE FEATURES
Google or email sign-in supports authenticated server conversion and private library/reading-position sync. Firebase stores only small metadata records, never your book files. Back up selected books to your own Google Drive and restore them on another Android device using the same Google account. Drive authorization and available storage are required. Free sync quotas are shared and limited; local reading continues when sync is unavailable. Guest reading progress stays on this device. Online services and model downloads require internet access.

GET STARTED
Open Conversion settings to choose Offline, On-device or Server. For setup instructions and bug reports, visit https://subhajit-roy-partho.github.io/firebrat/ or contact royduck@duck.com.

Only import and convert books you have permission to use. Firebrat does not include a catalogue of copyrighted books.

## Artifact identity

Build run: https://github.com/Subhajit-Roy-Partho/firebrat/actions/runs/40154211894

- Source commit: `2044188` (subsequent evidence/documentation commits do not change these binaries).
- AAB SHA-256: `7fc5f70b344c3b76a1f140167acd60dd4f310217a35b6d42da669f7a5dd2d71c`.
- APK SHA-256: `28bdf018a6945625995991780f7fa46f505d1b75758f62ffb006cc0cd97b6202`.

## Draft release notes

Continue as guest for offline reading and local conversion.
Sync library metadata and reading position privately.
Back up and restore books in your own Google Drive.
Improved PDF navigation, library layouts, and narration.
Fixed HTTPS server connections and package imports.
