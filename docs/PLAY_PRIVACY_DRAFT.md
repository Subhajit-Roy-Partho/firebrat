# Firebrat privacy policy — draft for owner review

Prepared 23 October 2026 for RoyFoundry. Contact: royduck@duck.com.
This draft describes the current Android implementation. It is not yet a published policy URL. Confirm operational retention/deletion procedures and the Ringtail server configuration before publishing or submitting the Data safety declaration.

## Offline reading and local conversion

Imported packages, downloaded books, narration, images, source PDFs, model files, settings and progress are stored on the device. Offline reading does not require an account. On-device conversion processes the selected PDF locally when cloud fallback is disabled. System speech voices are provided by the device's speech engine; download an offline voice to avoid that engine's network services. Kokoro requires initial downloads before local narration can run offline.

## Optional online features

Google or email sign-in uses Firebase Authentication. It processes account identifiers, email and, where supplied by the sign-in provider, name and profile information. Firebase may also process device and network information to provide and secure authentication.

Cloud library sync stores book identifiers, titles, source, timestamps and optional hashes under the signed-in user's Firestore library. Push notifications use Firebase Cloud Messaging installation identifiers and notification tokens. Firebase Analytics is included and records app usage events and device/installation information; the current Android bundle includes the advertising-ID permission through its SDK dependencies. Application events include sign-in method, feature use, section counts, conversion mode, model IDs and download/sync activity. The app does not intentionally attach book text or account email to these custom events. SDK automatic collection must also be included in the final Data safety declaration. The app contains no advertisements.

If Google Drive backup is enabled, selected book packages are uploaded to the user's Google Drive using the granted Drive file-access scope.

Selecting Server conversion uploads the selected PDF to the configured Firebrat server. That server processes book content and generated narration and stores conversion results. A configured LLM API or cloud fallback can receive selected text/images needed for conversion. Downloaded language and voice models are retrieved from their configured distributors, which receive ordinary network requests. Service operators' privacy terms apply to their processing.

## Transport and service choice

Firebase and Google service connections use their service endpoints. Firebrat permits user-configured local HTTP servers; those connections are not protected by HTTPS. Use HTTPS or a trusted encrypted private network for remote access. The final policy must identify the operator and retention practices of any RoyFoundry-hosted server; that deployment is still pending.

## Controls and deletion

Users can delete downloaded books from the library and remove local app data in Android settings. Deleting a local book does not delete server, Drive or account copies. Drive copies can be removed in Google Drive. Server copies depend on the configured server's deletion controls and operator.

Account/cloud-data deletion requests should be directed to royduck@duck.com. Do not send a password or API key. The owner must establish and verify account, Firestore and hosted-server deletion procedures, any legally required retention and a public request page before adopting this as the released policy. The current app still needs a verified in-app account-deletion path.

## Intended audience

The intended release audience is ages 13 and older. Do not claim that this declaration has been saved in Play Console until the sign-in-details prerequisite is complete.

## Items to resolve before publication

- Publish this policy and an account-deletion request page on the app website after owner review.
- Implement and verify in-app account deletion and the corresponding cloud-data cleanup.
- Confirm server operator, accessible HTTPS address, retention and deletion handling after Ringtail setup.
- Complete Data safety using Firebase SDK disclosures as well as app-level code behavior. Do not declare that no data is collected or that every configurable server connection is encrypted.
