"""Builds the Play listing graphics from real captures in sources/.

Screens are never invented: dev-*.png are Pixel 9a screenshots of the
debug build (status bar already cropped out of the sources), library-*.png and cover-*.png are
rendered by test/store_modern_capture_test.dart from the real widgets.
Run: python3 compose.py   ->  exports/
"""
import os, math
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
SRC, OUT = f"{HERE}/sources", f"{HERE}/exports"
os.makedirs(OUT, exist_ok=True)
FONT = "/System/Library/Fonts/Avenir Next.ttc"
HEAVY, DEMI, REG = 8, 2, 7

def font(idx, size):
    return ImageFont.truetype(FONT, size, index=idx)

PALETTES = {  # top, bottom, glow
    "indigo": ((30, 20, 92), (76, 44, 190), (255, 181, 71)),
    "violet": ((44, 12, 78), (130, 52, 210), (255, 140, 120)),
    "teal":   ((6, 40, 52), (18, 110, 120), (255, 214, 120)),
    "ocean":  ((12, 30, 80), (30, 100, 190), (255, 150, 150)),
    "night":  ((14, 12, 38), (52, 36, 128), (255, 181, 71)),
    "rose":   ((60, 14, 60), (170, 50, 150), (255, 196, 110)),
}

def gradient(w, h, top, bottom, glow):
    base = Image.new("RGB", (w, h))
    px = base.load()
    for y in range(h):
        t = y / (h - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    # warm glow lower-right + soft light upper-left
    g = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(g)
    d.ellipse((w * .35, h * .55, w * 1.35, h * 1.45), fill=glow + (120,))
    d.ellipse((-w * .4, -h * .2, w * .6, h * .4), fill=(255, 255, 255, 40))
    g = g.filter(ImageFilter.GaussianBlur(120))
    base.paste(g, (0, 0), g)
    return base.convert("RGBA")

def rounded(img, r):
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0) + img.size, r, fill=255)
    out = img.copy()
    out.putalpha(m)
    return out

def device(path, width, crop_top=0, crop_bottom=0, crop_box=None):
    im = Image.open(path).convert("RGB")
    if crop_box:
        im = im.crop(crop_box)
    else:
        im = im.crop((0, crop_top, im.width, im.height - crop_bottom))
    h = int(im.height * width / im.width)
    im = im.resize((width, h), Image.LANCZOS)
    r = int(width * .075)
    screen = rounded(im, r)
    bez = max(10, width // 60)
    frame = Image.new("RGBA", (width + 2 * bez, h + 2 * bez), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle(
        (0, 0, frame.width - 1, frame.height - 1), r + bez, fill=(14, 14, 20, 255),
        outline=(70, 70, 90, 255), width=3)
    frame.paste(screen, (bez, bez), screen)
    return frame

def shadowed(canvas, frame, x, y):
    sh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    a = frame.split()[3].point(lambda v: int(v * .55))
    blk = Image.new("RGBA", frame.size, (0, 0, 0, 255))
    blk.putalpha(a)
    sh.paste(blk, (x + 10, y + 36), blk)
    sh = sh.filter(ImageFilter.GaussianBlur(34))
    canvas.alpha_composite(sh)
    canvas.alpha_composite(frame, (x, y))

def wrap(draw, text, fnt, maxw):
    lines, cur = [], ""
    for w in text.split():
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=fnt) <= maxw:
            cur = t
        else:
            lines.append(cur); cur = w
    lines.append(cur)
    return lines

def card(name, headline, sub, shot, pal, **kw):
    W, H = 1080, 1920
    c = gradient(W, H, *PALETTES[pal])
    d = ImageDraw.Draw(c)
    hf, sf = font(HEAVY, 86), font(DEMI, 38)
    y = 120
    for ln in wrap(d, headline, hf, W - 150):
        d.text((75, y), ln, font=hf, fill="white"); y += 100
    y += 14
    for ln in wrap(d, sub, sf, W - 170):
        d.text((77, y), ln, font=sf, fill=(255, 255, 255, 205)); y += 52
    dev_w = kw.pop("dev_w", 800)
    f = device(f"{SRC}/{shot}", dev_w, **kw)
    top = max(y + 70, 520)
    x = (W - f.width) // 2
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadowed(layer, f, x, top)  # phone bleeds off the bottom edge
    c.alpha_composite(layer)
    c.convert("RGB").save(f"{OUT}/{name}.jpg", quality=92)
    print("wrote", name)

def feature():
    W, H = 1024, 500
    c = gradient(W, H, *PALETTES["night"])
    d = ImageDraw.Draw(c)
    d.text((56, 92), "Firebrat", font=font(HEAVY, 92), fill="white")
    d.text((58, 200), "Listen to any book,", font=font(DEMI, 40), fill=(255, 255, 255, 235))
    d.text((58, 250), "with every picture in sync.", font=font(DEMI, 40), fill=(255, 255, 255, 235))
    d.rounded_rectangle((58, 346, 420, 404), 29, fill=(255, 181, 71))
    d.text((90, 355), "PDFs to audiobooks", font=font(DEMI, 30), fill=(40, 24, 0))
    ids = ["alice", "pride", "sherlock", "frank", "moby"]
    specs = [(-10, 540, 124, 232), (-4, 622, 76, 258), (0, 706, 44, 286), (5, 790, 78, 258), (11, 856, 128, 232)]
    for (ang, x, y, h), i in sorted(zip(specs, ids), key=lambda s: -abs(s[0][0])):
        cov = Image.open(f"{SRC}/cover-{i}.png").convert("RGBA")
        bb = cov.getbbox()
        cov = cov.crop(bb)
        cov = cov.resize((int(cov.width * h / cov.height), h), Image.LANCZOS)
        cov = cov.rotate(-ang, expand=True, resample=Image.BICUBIC)
        c.alpha_composite(cov, (x, y))
    c.convert("RGB").save(f"{OUT}/feature-1024x500.jpg", quality=93)
    print("wrote feature")

if __name__ == "__main__":
    for old in os.listdir(OUT):
        os.remove(f"{OUT}/{old}")
    # The eight Play gallery images, in listing order (1.7.2 listing).
    card("01-your-library", "Every book gets its own cover", "A beautiful shelf for PDFs, novels and textbooks you can listen to.",
         "library-dark.png", "night")
    card("02-listen-while-it-converts", "Listen while it converts", "Open a book that is still converting and play the sections that are ready. It carries on by itself.",
         "dev-listen-converting.png", "indigo", dev_w=650)
    card("03-pause-and-resume", "Pause and pick up later", "Pause a long conversion any time. Progress is saved and it resumes after the last finished section.",
         "dev-pause-resume.png", "ocean", dev_w=650)
    card("04-cast-and-voices", "See who is speaking", "Cast & voices lists every speaker in a novel, their traits and the voice they were given.",
         "dev-cast-voices.png", "rose", dev_w=650)
    card("05-novel-voices", "A different voice for every character", "Novel mode splits dialogue by speaker and gives each character their own voice, age and temperament.",
         "dev-novel-voices.png", "violet", dev_w=650)
    card("06-free-cloud-llm", "Faster with a free cloud LLM", "Use a free key from OpenRouter, Groq or Google AI Studio instead of the on-device model.",
         "dev-cloud-llm-top.png", "indigo", dev_w=650)
    card("07-private-offline", "Or keep it private and offline", "Convert on your phone with a natural neural voice. No account, no server, nothing leaves the device.",
         "dev-settings-ondevice-2.png", "teal", dev_w=650)
    card("08-drive-sync", "Back up and sync with Google Drive", "Your books go to your own Drive and onto your other devices. Firebrat sees only its own files.",
         "dev-guide-drive.png", "night", dev_w=700)
    # Extras kept for the website and future listings (not part of the eight).
    card("extra-listen-and-follow", "Literature and textbooks, with pictures in sync", "The sentence being read is highlighted, and its figure stays on screen.",
         "dev-reader-s1-playing.png", "indigo", dev_w=640)
    card("extra-two-modes", "Two modes: novels and illustrated books", "Novel mode keeps the prose verbatim with character voices. Illustrated mode keeps figures, tables and formulas.",
         "dev-modes-novel.png", "rose", dev_w=650)
    card("extra-source-page", "See the original page, always", "Open the source PDF at the exact page being read, for figures, tables and formulas.",
         "dev-source-pdf.png", "ocean")
    card("extra-keeps-going", "It carries on by itself", "At the last ready section playback waits, then continues when the next one finishes.",
         "dev-listen-waiting.png", "teal", dev_w=650)
    card("extra-test-your-llm", "Load models, test, go", "Pull the model list from your provider and test the key in one tap.",
         "dev-llm-test.png", "ocean", crop_box=(0, 120, 1080, 1500), dev_w=900)
    card("extra-light-and-dark", "Easy on the eyes, day or night", "Light, dark or match your phone, with adjustable text size.",
         "library-light.png", "rose")
    card("extra-pick-a-model", "Pick the right model for your phone", "From light and fast to high quality, with RAM needs listed.",
         "dev-guide-models.png", "teal", dev_w=700)
    card("extra-guide-modes", "A guide to every option", "A built-in tour explains where everything is and what each mode does.",
         "dev-guide-modes.png", "violet", dev_w=700)
    card("extra-guide-llm", "Free LLM setup, step by step", "The in-app guide walks through getting a key and entering it.",
         "dev-guide-llm.png", "indigo", dev_w=700)
    feature()
