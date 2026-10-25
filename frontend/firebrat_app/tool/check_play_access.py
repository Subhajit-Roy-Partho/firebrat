#!/usr/bin/env python3
"""Fail fast, with a plain explanation, if the Play service account can't publish.

Reads the service-account JSON from the PLAY_SERVICE_ACCOUNT_JSON env var,
authenticates, opens a Play "edit" for the app and immediately discards it.
That is exactly the first call upload-google-play makes, so if this passes the
upload will not die with the bare "The caller does not have permission".
Nothing is changed in the Play Console.
"""
import json
import os
import sys

PACKAGE = os.environ.get("PLAY_PACKAGE", "com.firebrat.firebrat_app")
SCOPE = ["https://www.googleapis.com/auth/androidpublisher"]
BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"


def fail(msg: str) -> None:
    print(f"::error::{msg}")
    sys.exit(1)


def main() -> None:
    raw = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON", "").strip()
    if not raw:
        fail("Secret PLAY_SERVICE_ACCOUNT_JSON is empty or missing.")
    try:
        info = json.loads(raw)
        email = info["client_email"]
    except Exception:
        fail("PLAY_SERVICE_ACCOUNT_JSON is not a service-account key file (expected JSON with client_email). "
             "Paste the whole downloaded .json, not base64.")
    print(f"Service account: {email}  (project {info.get('project_id')})")

    from google.auth.transport.requests import AuthorizedSession
    from google.oauth2 import service_account

    creds = service_account.Credentials.from_service_account_info(info, scopes=SCOPE)
    session = AuthorizedSession(creds)
    resp = session.post(f"{BASE}/{PACKAGE}/edits", json={})
    if resp.status_code == 200:
        edit_id = resp.json()["id"]
        session.delete(f"{BASE}/{PACKAGE}/edits/{edit_id}")
        print("OK: the service account can open and discard a Play edit for", PACKAGE)
        return

    body = resp.text[:600]
    hint = {
        401: "The key is invalid, revoked, or for a deleted service account. Create a new key.",
        403: ("Play Console has not granted this service account access to the app. Fix, in Play Console "
              "(not GitHub): Users and permissions > Invite new users > paste the service-account email above "
              "> App permissions: add this app > tick 'Release apps to testing tracks' (and 'Release to "
              "production' if you need it) > Invite. Also make sure the 'Google Play Android Developer API' "
              "is enabled in that service account's Google Cloud project. Changes can take a few minutes "
              "(occasionally up to 24 h) to apply."),
        404: (f"Play does not know the package '{PACKAGE}' for this account: the app must already exist in "
              "this developer account, with at least one release created manually."),
    }.get(resp.status_code, "Unexpected response from the Play Developer API.")
    fail(f"Play API returned {resp.status_code} for {PACKAGE} as {email}. {hint}  Response: {body}")


if __name__ == "__main__":
    main()
