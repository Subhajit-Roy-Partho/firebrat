#!/usr/bin/env python3
"""Relink figures/tables of a finished Firebrat package to the sections that discuss them.

Method (label-driven, page position is only the fallback):
 1. Read every 'Figure N.M' / 'Table N.M' caption (text + page + y) from the package's source.pdf.
 2. Pair captions with the extracted images on the same page. Figure ids are extraction order (top to bottom),
    so order gives a prior; with --vlm a vision model looks at each image and the page's candidate captions and picks
    the matching one (it overrides the prior only when the choice is unique on that page).
 3. Link each figure to every section whose narration mentions its label ('Figure 3.1', 'Figure 3.1(a)', 'Fig. 3.1')
    within --window pages of the figure, closest first (max --max-links); no mention -> first section narrated from the
    figure's page; sizeable unlabeled images (cartoons, chapter art) are linked by page the same way.
Writes a report; --apply merges the refs into manifest.json (keeps manifest.json.bak). Existing refs are never removed.

usage: relink_figures.py <package_dir> [--vlm] [--apply] [--report out.json] [--window 3] [--max-links 3] [--min-px 40]
--vlm needs a transformers>=5 env with a vision model (default Qwen/Qwen3.5-9B) and a free GPU."""
import argparse, collections, json, os, re, shutil

CAP = re.compile(r"(?m)^\s*(Figure|Fig\.|Table)\s+(\d+(?:\.\d+)+)\s*[:.\-–]?\s*(.*)$")
MENTION = re.compile(r"\b(Figure|Fig\.|Table)\s+(\d+(?:\.\d+)+)", re.I)
JSON_RE = re.compile(r"\{.*\}", re.S)


def norm(kind, num):
    return ("table" if kind.lower().startswith("t") else "figure") + " " + num


def read_captions(pdf_path):
    import pymupdf
    doc, caps = pymupdf.open(pdf_path), collections.defaultdict(list)
    for p in range(doc.page_count):
        for b in doc[p].get_text("blocks"):
            m = CAP.search(b[4])
            if m:
                text = " ".join(b[4][m.start(3):].split()) if m.group(3) else ""
                caps[p].append({"label": norm(m.group(1), m.group(2)), "text": text, "y": b[1]})
    for p in caps:
        caps[p].sort(key=lambda c: c["y"])
    return caps


def load(pkg):
    m = json.load(open(f"{pkg}/manifest.json"))
    texts = {}
    for s in m["sections"]:
        f = os.path.join(pkg, s["segments_path"])
        texts[s["section_id"]] = " ".join(g["text"] for g in json.load(open(f))["segments"]) if os.path.isfile(f) else ""
    return m, texts


def pair_by_order(images, caps_on_page, kind):
    cs = [c for c in caps_on_page if c["label"].startswith(kind)]
    return {im["id"]: cs[i]["label"] for i, im in enumerate(images[:len(cs)])}


def vlm_pick(model, proc, pkg, im, cands):
    from PIL import Image
    raw = Image.open(os.path.join(pkg, im["path"])).convert("RGBA")  # transparent PNGs turn black if not flattened onto white
    img = Image.new("RGB", raw.size, "white"); img.paste(raw, mask=raw.split()[3]); img.thumbnail((900, 900))
    opts = "\n".join(f"[{i}] {c['label'].title()}: {c['text']}" for i, c in enumerate(cands))
    q = ("This picture was cut out of one page of a textbook. Which caption on that page belongs to it? "
         f"Captions:\n{opts}\n[none] none of them (decorative picture)\nAnswer ONLY JSON: {{\"caption\": <index or \"none\">, \"why\": \"<8 words>\"}}")
    msgs = [{"role": "user", "content": [{"type": "image", "image": img}, {"type": "text", "text": q}]}]
    inp = proc.apply_chat_template(msgs, add_generation_prompt=True, tokenize=True, return_dict=True,
                                   return_tensors="pt", enable_thinking=False).to(model.device)
    out = model.generate(**inp, max_new_tokens=80, do_sample=False)
    txt = proc.batch_decode(out[:, inp["input_ids"].shape[1]:], skip_special_tokens=True)[0]
    try:
        r = json.loads(JSON_RE.search(txt).group(0)); c = r.get("caption")
        return (cands[c]["label"] if isinstance(c, int) and 0 <= c < len(cands) else None), r.get("why", "")
    except Exception:  # noqa: BLE001
        return None, "unparsable: " + txt[:60]


def load_vlm(name):
    import torch
    from transformers import AutoModelForImageTextToText, AutoProcessor, BitsAndBytesConfig
    proc = AutoProcessor.from_pretrained(name)
    # FP8 on-the-fly conversion corrupts this model's vision tower (the model then hallucinates); 8-bit LM + bf16 vision is verified.
    for label, kw in (("bnb8", dict(quantization_config=BitsAndBytesConfig(load_in_8bit=True, llm_int8_skip_modules=["visual", "lm_head"]))),
                      ("bnb4", dict(quantization_config=BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                                    bnb_4bit_compute_dtype=torch.bfloat16, llm_int8_skip_modules=["visual", "lm_head"])))):
        try:
            return AutoModelForImageTextToText.from_pretrained(name, device_map="cuda", **kw), proc
        except Exception as e:  # noqa: BLE001
            print("vlm load failed", label, str(e)[:160]); torch.cuda.empty_cache()
    raise SystemExit("no VLM")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pkg"); ap.add_argument("--vlm", action="store_true"); ap.add_argument("--apply", action="store_true")
    ap.add_argument("--report", default="relink_report.json"); ap.add_argument("--window", type=int, default=3)
    ap.add_argument("--max-links", type=int, default=3); ap.add_argument("--min-px", type=int, default=40)
    ap.add_argument("--model", default="Qwen/Qwen3.5-9B"); ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--pages", default="", help="restrict to 'lo-hi' figure pages (debug)")
    a = ap.parse_args()
    m, texts = load(a.pkg)
    caps = read_captions(os.path.join(a.pkg, m.get("source_pdf_path") or "source.pdf"))
    secs = {s["section_id"]: s for s in m["sections"]}
    by_page = collections.defaultdict(list)
    for s in m["sections"]:
        for p in s.get("source_pages", []): by_page[p].append(s["section_id"])
    mention = collections.defaultdict(list)  # label -> [(page, section_id)]
    for s in m["sections"]:
        for k, n in {(k, n) for k, n in MENTION.findall(texts[s["section_id"]])}:
            mention[norm(k, n)].append((min(s.get("source_pages") or [0]), s["section_id"]))
    items = {"figure": [dict(id=f["figure_id"], page=f["page"], path=f["image_path"], w=f["width"], h=f["height"]) for f in m["figures"]],
             "table": [dict(id=t["table_id"], page=t["page"], path=t["image_path"], w=t.get("width", 999), h=t.get("height", 999)) for t in m.get("tables", [])]}
    lo, hi = (map(int, a.pages.split("-")) if a.pages else (0, 10**6))
    model = proc = None
    if a.vlm:
        model, proc = load_vlm(a.model)
    rows, links = [], collections.defaultdict(lambda: collections.defaultdict(list))
    done = 0
    for kind, lst in items.items():
        pages = collections.defaultdict(list)
        for im in lst: pages[im["page"]].append(im)
        for page, ims in sorted(pages.items()):
            if not lo <= page <= hi or (a.limit and done >= a.limit): continue
            ims = sorted(ims, key=lambda i: i["id"])
            real = [i for i in ims if min(i["w"], i["h"]) >= a.min_px]
            page_caps = [c for c in caps.get(page, []) if c["label"].startswith(kind)]
            prior = pair_by_order(real, caps.get(page, []), kind)
            for im in real:
                label, why, how = prior.get(im["id"]), "", "order"
                if model and page_caps:
                    pick, why = vlm_pick(model, proc, a.pkg, im, page_caps)
                    if pick and pick != label and sum(1 for x in real if prior.get(x["id"]) == pick) == 0:
                        how = "vlm"; label = pick
                    elif pick == label:
                        how = "order+vlm"
                    elif pick:
                        how = "order(vlm-disagrees:" + pick + ")"
                done += 1
                near = sorted((abs(p - page), p, sid) for p, sid in mention.get(label, []) if abs(p - page) <= a.window) if label else []
                chosen, seen = [], set()
                for _, _, sid in near:
                    if sid not in seen and len(chosen) < a.max_links: chosen.append(sid); seen.add(sid)
                basis = "mention"
                if not chosen:
                    chosen, basis = by_page.get(page, [])[:1], "page"
                for sid in chosen: links[sid][kind].append(im["id"])
                rows.append({"id": im["id"], "kind": kind, "page": page, "label": label, "pair": how, "vlm_why": why, "basis": basis, "sections": chosen,
                             "caption": next((c["text"] for c in page_caps if c["label"] == label), "")})
    summ = collections.Counter()
    for r in rows:
        summ["items"] += 1; summ["labeled"] += bool(r["label"]); summ["linked"] += bool(r["sections"]); summ["by_" + r["basis"]] += 1
        summ["pair_" + r["pair"].split("(")[0]] += 1
    json.dump({"summary": summ, "rows": rows}, open(a.report, "w"), indent=1)
    print(json.dumps(summ))
    if a.apply:
        shutil.copy(f"{a.pkg}/manifest.json", f"{a.pkg}/manifest.json.bak")
        for sid, d in links.items():
            for kind, ids in d.items():
                key = "figure_refs" if kind == "figure" else "table_refs"
                cur = secs[sid].setdefault(key, [])
                cur.extend(i for i in ids if i not in cur)
        json.dump(m, open(f"{a.pkg}/manifest.json", "w"), ensure_ascii=False, indent=2)
        print("applied to", len(links), "sections")


if __name__ == "__main__":
    main()
