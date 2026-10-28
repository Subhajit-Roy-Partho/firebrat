#!/usr/bin/env python3
"""Write books/{slug} + users/{uid}/uploads/{slug} Firestore docs for the launch catalogue.

usage: seed_launch_books.py <catalog.json> <zips_dir> <submitter_uid> <slug>...
Run only AFTER ia_upload.py has put <zips_dir>/<slug>.zip on the Internet Archive as firebrat-<slug>.
Auth: the local `firebase login` (refresh token in ~/.config/configstore). Admin REST writes bypass the rules,
so every doc is shaped to satisfy validBook() in firebase/firestore.rules. Refuses to overwrite an existing book."""
import datetime, glob, json, os, re, subprocess, sys, tempfile, urllib.error, urllib.parse, urllib.request, zipfile

PROJECT = "firebrat-8c597"
HERE = os.path.dirname(os.path.abspath(__file__))
CC_BY = "https://creativecommons.org/licenses/by/4.0/"


def token():
    cfg = json.load(open(os.path.expanduser("~/.config/configstore/firebase-tools.json")))
    src = glob.glob(os.path.expanduser("~/.npm/_npx/*/node_modules/firebase-tools/lib/api.js"))[0]
    t = open(src).read()
    cid = re.search(r'"([0-9-]+[a-z0-9]+\.apps\.googleusercontent\.com)"', t).group(1)
    sec = re.search(r'"(j9iVZfS8[^"]+)"', t).group(1)
    d = urllib.parse.urlencode({"grant_type": "refresh_token", "refresh_token": cfg["tokens"]["refresh_token"],
                                "client_id": cid, "client_secret": sec}).encode()
    return json.load(urllib.request.urlopen("https://oauth2.googleapis.com/token", d))["access_token"]


def val(v):
    if isinstance(v, bool): return {"booleanValue": v}
    if isinstance(v, int): return {"integerValue": str(v)}
    if isinstance(v, str): return {"stringValue": v}
    if isinstance(v, list): return {"arrayValue": {"values": [val(x) for x in v]}}
    if isinstance(v, dict):
        if "__ts__" in v: return {"timestampValue": v["__ts__"]}
        return {"mapValue": {"fields": {k: val(x) for k, x in v.items()}}}
    raise TypeError(type(v))


def doc_url(path): return f"https://firestore.googleapis.com/v1/projects/{PROJECT}/databases/(default)/documents/{path}"


def exists(tok, path):
    try:
        urllib.request.urlopen(urllib.request.Request(doc_url(path), headers={"Authorization": "Bearer " + tok}))
        return True
    except urllib.error.HTTPError as e:
        if e.code == 404: return False
        raise


def put(tok, path, fields):
    r = urllib.request.Request(doc_url(path), json.dumps({"fields": {k: val(v) for k, v in fields.items()}}).encode(),
                               {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}, method="PATCH")
    return urllib.request.urlopen(r).status


def main(cat, zips, uid, slugs):
    catalog = {b["slug"]: b for b in json.load(open(cat))}
    tok = token()
    now = {"__ts__": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")}
    for slug in slugs:
        b, iid, zp = catalog[slug], "firebrat-" + slug, os.path.join(zips, slug + ".zip")
        if exists(tok, f"books/{slug}"):
            print("SKIP (exists)", slug); continue
        meta = json.load(urllib.request.urlopen(f"https://archive.org/metadata/{iid}", timeout=30))
        names = {f["name"]: f for f in meta.get("files", [])}
        if f"{iid}.zip" not in names or int(names[f"{iid}.zip"]["size"]) != os.path.getsize(zp):
            print("NOT ON ARCHIVE YET (or size mismatch):", slug); continue
        with tempfile.NamedTemporaryFile(suffix=".json") as tf:
            tf.write(zipfile.ZipFile(zp).read("manifest.json")); tf.flush()
            out = json.loads(subprocess.check_output(["node", os.path.join(HERE, "chapters.mjs"), tf.name]))
        by = f"{b['author']}" + (f"; translation by {b['translator']}" if b.get("translator") else "")
        book = {
            "title": b["title"], "author": b["author"], "description": b["description"], "language": b["language"],
            "category": b["category"], "tags": ["audiobook", "public domain", "firebrat"],
            "archiveId": iid, "archiveUrl": f"https://archive.org/details/{iid}",
            "packageKind": "zip", "packageFile": f"{iid}.zip", "chapters": out["chapters"],
            "sizeBytes": os.path.getsize(zp), "sectionCount": out["sectionCount"], "totalDurationMs": out["totalDurationMs"],
            "provenance": {
                "generation": "firebrat-tts", "narrationEngine": "Qwen3-TTS (VoiceDesign voice anchors + Base voice cloning)",
                "models": ["Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign", "Qwen/Qwen3-TTS-12Hz-1.7B-Base"],
                "pipelineNotes": ("Fully synthetic narration; no human reader. A language model assigns dialogue to characters; each "
                                  "character voice is designed from a written description, not from any real person's recording. "
                                  "Sampled segments were checked with speech recognition; not every sentence is human-reviewed."),
                "sourceTitle": f"{b['title']} — {by} (Project Gutenberg #{b['gutenberg']})",
                "sourceUrl": b["sourceUrl"], "license": "cc-by", "licenseUrl": CC_BY, "attested": True,
            },
            "submitterUid": uid, "submitterName": "Firebrat", "status": "published",
            "ratingSum": 0, "ratingCount": 0, "commentCount": 0, "createdAt": now, "updatedAt": now,
        }
        s1 = put(tok, f"books/{slug}", book)
        s2 = put(tok, f"users/{uid}/uploads/{slug}", {"bookId": slug, "title": b["title"], "archiveId": iid,
                                                      "archiveUrl": book["archiveUrl"], "uploadedAt": now})
        print("OK", slug, s1, s2, out["sectionCount"], "sections", out["totalDurationMs"] // 60000, "min")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:])
