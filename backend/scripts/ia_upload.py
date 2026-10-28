#!/usr/bin/env python3
"""Upload a built package zip to the Internet Archive via its S3-compatible API.

usage: ia_upload.py <catalog.json> <slug> <zip> [--dry]
Keys come from the environment (internetArchiveS3key / internetArchiveS3secret; get them at
https://archive.org/account/s3.php) and are never printed or put on a command line (a 0600 temp header file is used).
Run it from the Mac, not the server (the keys live in the user's ~/.zshrc). Refuses nothing silently: it reports if the item exists."""
import json, os, stat, subprocess, sys, tempfile, urllib.parse, urllib.request

PD = "https://creativecommons.org/publicdomain/mark/1.0/"


def ia_id(slug):  # prefixed: bare slugs (dracula-stoker, jane-eyre-bronte) already belong to other uploaders
    return "firebrat-" + slug


def uri(v):  # IA's escape for non-ASCII header values
    return "uri(" + urllib.parse.quote(v, safe="") + ")"


def main(cat_path, slug, zpath, dry):
    b = {x["slug"]: x for x in json.load(open(cat_path))}[slug]
    iid = ia_id(slug)
    key, sec = os.environ["internetArchiveS3key"], os.environ["internetArchiveS3secret"]
    try:  # do not overwrite an item that already has files
        with urllib.request.urlopen(f"https://archive.org/metadata/{iid}", timeout=30) as r:
            if json.load(r).get("files"):
                print("EXISTS", iid, "- item already present; skipping create")
                return
    except Exception as e:  # noqa: BLE001
        print("metadata check:", e)
    desc = (f"{b['description']} Narrated audiobook in the Firebrat package format (manifest.json + per-chapter m4a). "
            f"Text: Project Gutenberg ebook #{b['gutenberg']} ({b['sourceUrl']}), public domain ({b['author']}, d. {b['died']}). "
            "Audio generated with Qwen3-TTS (synthetic voices, one per character) via the Firebrat pipeline. "
            "Browse and listen at https://subhajit-roy-partho.github.io/firebrat/community/")
    hdr = {
        "authorization": f"LOW {key}:{sec}",
        "x-archive-auto-make-bucket": "1", "x-archive-queue-derive": "0",
        "x-archive-meta01-collection": "opensource_audio", "x-archive-meta-mediatype": "audio",
        "x-archive-meta-title": uri(b["title"]), "x-archive-meta-creator": uri(b["author"]),
        "x-archive-meta-description": uri(desc), "x-archive-meta-language": "eng",
        "x-archive-meta-licenseurl": PD, "x-archive-meta-source": uri(b["sourceUrl"]),
        "x-archive-meta01-subject": "audiobook", "x-archive-meta02-subject": "public domain", "x-archive-meta03-subject": "firebrat",
    }
    fname = f"{iid}.zip"
    if dry:
        print("DRY would PUT", f"https://s3.us.archive.org/{iid}/{fname}", os.path.getsize(zpath), "bytes;", len(hdr), "headers")
        return
    fd, hp = tempfile.mkstemp(); os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "w") as f:
        for k, v in hdr.items():
            f.write(f"{k}: {v}\n")
    try:
        r = subprocess.run(["curl", "-sS", "--fail-with-body", "--retry", "3", "-X", "PUT", "-H", f"@{hp}",
                            "--upload-file", zpath, f"https://s3.us.archive.org/{iid}/{fname}"], capture_output=True, text=True)
        print("curl exit", r.returncode, (r.stdout + r.stderr)[:400].replace(key, "***").replace(sec, "***"))
        if r.returncode:
            sys.exit(1)
    finally:
        os.unlink(hp)
    print("UPLOADED", f"https://archive.org/details/{iid}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], "--dry" in sys.argv)
