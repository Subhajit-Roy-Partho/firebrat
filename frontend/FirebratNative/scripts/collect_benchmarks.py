"""Export original native fixture measurements without device/account identifiers.
Usage: python3 collect_benchmarks.py BOOKS_DIRECTORY > report.json
"""
import json
import pathlib
import sys

cases = []
for manifest_path in pathlib.Path(sys.argv[1]).rglob("manifest.json"):
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("title") not in {
        "native-illustrated", "native-scanned", "native-novel", "native-voices"
    }:
        continue
    folder = manifest_path.parent
    metrics_path = folder / "conversion_metrics.json"
    if not metrics_path.exists():
        continue
    case = {
        "fixture": manifest["title"],
        "generated_at": manifest.get("generated_at"),
        "figure_count": len(manifest.get("figures", [])),
        "metrics": json.loads(metrics_path.read_text()),
    }
    for filename, key in [("compilation_report.json", "compilation"),
                          ("character_roster.json", "characters")]:
        path = folder / filename
        if path.exists():
            case[key] = json.loads(path.read_text())
    cases.append(case)
print(json.dumps(sorted(cases, key=lambda item: item.get("generated_at") or ""),
                 indent=2, ensure_ascii=False))
