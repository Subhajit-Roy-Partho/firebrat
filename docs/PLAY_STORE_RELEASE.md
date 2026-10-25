# Play Store release branch

The Android app on `master` retains all features: account-free offline reading, on-device conversion and OCR, local LLM and Kokoro/system voices, illustrated and novel modes, server conversion, Firebase/Google sign-in, cloud sync and notifications. It includes the source-PDF slider and duplicate drawer fixes. This is not a claim of Play approval.

## Build and signing

Run the **Play Store bundle** workflow from `master`. It analyzes and tests the app, builds a signed AAB and retains it as a workflow artifact. It never publishes to Play automatically. Repository secrets required: `ANDROID_KEYSTORE_BASE64`, `KEY_STORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`, `GOOGLE_SERVICES_JSON`. These are the existing Android release secrets. Missing signing inputs fail the store build; it cannot silently use a debug certificate.

For a local store bundle, provide `frontend/firebrat_app/android/key.properties` and its upload keystore, then run from the Flutter app directory:

```sh
FIREBRAT_PLAY_RELEASE=true flutter build appbundle --release
```

Keep the application ID and upload key stable. Increase `versionCode` above every previously uploaded bundle. Use Play App Signing, and register the **Play app-signing** certificate with Firebase/Google OAuth as well as any upload/debug certificates. Test sign-in with a build installed from Play's internal track.

## Required before submission

- Verify target SDK against the [current requirements](https://support.google.com/googleplay/android-developer/answer/11926878), and validate every bundled native library for 16 KB page sizes. Test the actual AAB on a 16 KB emulator; Flutter unit tests cannot establish native compatibility.
- Complete account deletion inside the app and a public deletion-request web page, including authentication, cloud metadata and retention rules. Verify actual deletion before declaring compliance.
- Publish an accurate privacy policy and complete [Data safety](https://support.google.com/googleplay/android-developer/answer/10787469) for Firebase, Analytics, Messaging, Drive, selected LLM providers and uploaded books. Account-free reading does not mean every feature collects no data.
- Review permissions and foreground-service declarations for conversion and media playback, notification behavior, background execution and Android version coverage.
- Audit redistribution rights for Syncfusion, native libraries, downloadable models and voices; supply required notices and model download disclosures. Only convert content the user has rights to use.
- Complete content rating, app access/reviewer instructions, store graphics, contact information and any testing/verification requirements shown in Play Console. Test offline import/playback, online sign-in/server conversion, novels, illustrated PDFs, model downloads and deletion on the release artifact.

These are open release gates, not completed checks. See [Google Play policies](https://developer.android.com/distribute/play-policies). No Play account creation, payment or store submission is performed by the build workflow.

## User instructions and support

Link the [Android conversion guide](ANDROID_CONVERSION_GUIDE.md) from the store listing. Bugs go to the [structured GitHub report form](https://github.com/Subhajit-Roy-Partho/firebrat/issues/new?template=bug_report.yml).

## Console preparation — 23 October 2026

The default listing, Firebrat icon/banner and three actual-widget UI previews are saved in Play Console and ready for review. RoyFoundry's approved maker R icon and matching developer header are saved. Public support email: `royduck@duck.com`. Category: Books & reference. No-ads, non-government, no-financial-features, no-health-features and content-rating declarations were saved. The current Analytics SDK's advertising-ID use is declared for analytics, consistent with the merged bundle manifest.

The intended audience is 13+, authorized by the owner. The 13–15, 16–17 and 18+ audience groups are now saved in Play Console, along with the dedicated reviewer credentials and live server instructions. Version 1.6.2 is active and available to internal testers (verified in Play Console on 2026-10-23). Reviewer/server preparation now uses the owner's authorized `docker` SSH host, with a dedicated Firebase reviewer login; see [deployment and test evidence](REVIEW_SERVER_TESTING.md). The review server is reachable at https://firebrat-review-server.rohu-hexatonic.ts.net through Tailscale Funnel; Android review checks are in progress; the privacy URL is now saved in Play Console. The privacy policy and a manual account/data deletion request page are published. The separate Data safety and foreground-service declarations, final Android checks, and production testing/access gates remain open. See [the policy draft](PLAY_PRIVACY_DRAFT.md) for the known data flows and unresolved operational details.

The initial 1.6.1+24 AAB was uploaded as an internal-test draft. It exposed eSpeak's 4 KB ELF alignment. The 1.6.2+25 rebuild adds flexible-page linker arguments to the Kokoro native plugin. GitHub run `39917654070` passed analysis, tests, signed AAB build and the 28-library 64-bit ELF alignment check. Native alignment is a build check; it does not establish complete runtime compatibility on a 16 KB Android device.

Internal test opt-in: https://play.google.com/apps/internaltest/4701750160663480733
(only accounts on the configured tester list can join; currently the owner's
“Close friends” list is selected). This is internal availability, not production
approval. A debug-signed installation cannot be updated in place by a
Play-signed build; preserve/export local books before changing signing channels.
