#!/usr/bin/env python3
"""Publish the Play Store listing (text + graphics) from assets/play-store/modern-refresh.

Uses the same service account as the release upload. What it does, in one Play
"edit" so it is all-or-nothing:
  1. reads the current en-US listing (the title is kept as it is),
  2. sets the short and full description from description.txt / short-description.txt,
  3. replaces the phone screenshots with exports/01..08 (in order) and the feature graphic,
  4. commits the edit (unless --dry-run, which discards it instead).

Listing changes are reviewed by Google like any other store update.
"""
import argparse
import glob
import json
import os
import sys

from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account

PACKAGE = os.environ.get("PLAY_PACKAGE", "com.firebrat.firebrat_app")
LANG = "en-US"
SCOPE = ["https://www.googleapis.com/auth/androidpublisher"]
API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "assets", "play-store", "modern-refresh")


def die(msg):
    print(f"::error::{msg}")
    sys.exit(1)


def check(resp, what):
    if resp.status_code >= 300:
        die(f"{what} failed ({resp.status_code}): {resp.text[:500]}")
    return resp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="validate everything, then discard the edit")
    args = ap.parse_args()

    info = json.loads(os.environ["PLAY_SERVICE_ACCOUNT_JSON"])
    session = AuthorizedSession(service_account.Credentials.from_service_account_info(info, scopes=SCOPE))

    full = open(os.path.join(ROOT, "description.txt"), encoding="utf-8").read().strip()
    short = open(os.path.join(ROOT, "short-description.txt"), encoding="utf-8").read().strip()
    if len(full) > 4000 or len(short) > 80:
        die(f"description too long ({len(full)}/4000, short {len(short)}/80)")
    shots = sorted(glob.glob(os.path.join(ROOT, "exports", "0[1-8]-*.jpg")))
    feature = os.path.join(ROOT, "exports", "feature-1024x500.jpg")
    if len(shots) != 8 or not os.path.isfile(feature):
        die(f"expected 8 gallery images and a feature graphic, found {len(shots)}")

    edit_id = check(session.post(f"{API}/{PACKAGE}/edits", json={}), "Opening an edit").json()["id"]
    base = f"{API}/{PACKAGE}/edits/{edit_id}"
    try:
        current = check(session.get(f"{base}/listings/{LANG}"), "Reading the current listing").json()
        print("Current title:", current.get("title"))
        body = {"language": LANG, "title": current["title"], "shortDescription": short, "fullDescription": full}
        if current.get("video"):
            body["video"] = current["video"]
        check(session.put(f"{base}/listings/{LANG}", json=body), "Updating the descriptions")
        print("Descriptions updated.")

        def replace_images(image_type, paths):
            check(session.delete(f"{base}/listings/{LANG}/{image_type}"), f"Clearing {image_type}")
            for path in paths:
                with open(path, "rb") as f:
                    resp = session.post(f"{UPLOAD}/{PACKAGE}/edits/{edit_id}/listings/{LANG}/{image_type}",
                                        params={"uploadType": "media"}, data=f.read(),
                                        headers={"Content-Type": "image/jpeg"})
                check(resp, f"Uploading {os.path.basename(path)}")
                print("Uploaded", os.path.basename(path))

        replace_images("phoneScreenshots", shots)
        replace_images("featureGraphic", [feature])

        if args.dry_run:
            print("Dry run: everything validated; discarding the edit without publishing.")
            session.delete(base)
            return
        check(session.post(f"{base}:commit"), "Committing the listing")
        print("Listing committed. Google will review the changes before they go live.")
    except SystemExit:
        session.delete(base)  # never leave a half-built edit behind
        raise


if __name__ == "__main__":
    main()
