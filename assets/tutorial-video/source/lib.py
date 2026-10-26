"""Helpers for the Firebrat tutorial video build (Pillow + ffmpeg, no drawtext)."""
import os, subprocess, textwrap, hashlib, json
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

R = '/private/tmp/claude-501/-Users-subhajitrouy-Documents-Github-firebrat/d2cdc2be-6abe-4aaa-a5e5-c6f36f1c31c7/scratchpad'
B = R + '/build'
REPO = '/Users/subhajitrouy/Documents/Github/firebrat'
SRC = REPO + '/assets/play-store/modern-refresh/sources'
os.makedirs(B + '/png', exist_ok=True)
os.makedirs(B + '/parts', exist_ok=True)

W, H = 1080, 1920
PX, PY, PW, PH = 196, 130, 688, 1540          # phone screen area on the canvas
NW, NH = 1080, 2424                           # native phone frame
SC = PW / NW
APP_BG = (18, 18, 22)
ACCENT = (208, 188, 255)
MUTED = (200, 196, 222)
FONT = '/System/Library/Fonts/Avenir Next.ttc'
HEAVY, DEMI, REG = 8, 2, 7


def font(idx, size):
    return ImageFont.truetype(FONT, size, index=idx)


def run(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(cmd + '\n' + r.stderr[-1500:])
    return r.stdout


def dur(path):
    return float(run(f'ffprobe -v error -show_entries format=duration -of csv=p=0 "{path}"').strip())


# ---------------------------------------------------------------- backgrounds
def gradient(w, h):
    top, bot = np.array((18, 14, 40)), np.array((40, 24, 84))
    t = np.linspace(0, 1, h)[:, None, None]
    arr = (top + (bot - top) * t) * np.ones((1, w, 1))
    base = Image.fromarray(arr.astype('uint8'), 'RGB').convert('RGBA')
    g = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(g)
    d.ellipse((w * .3, h * .62, w * 1.4, h * 1.35), fill=(120, 70, 200, 70))
    d.ellipse((-w * .5, -h * .15, w * .6, h * .3), fill=(255, 255, 255, 22))
    g = g.filter(ImageFilter.GaussianBlur(140))
    base.alpha_composite(g)
    return base


BG = gradient(W, H)


def tracked(d, xy, text, f, fill, spacing=3):
    x, y = xy
    for ch in text:
        d.text((x, y), ch, font=f, fill=fill)
        x += d.textlength(ch, font=f) + spacing


def make_base(part, chapter):
    """Background + header (part label, chapter name) for clip and still scenes."""
    key = hashlib.md5(f'{part}|{chapter}'.encode()).hexdigest()[:10]
    p = f'{B}/png/base_{key}.png'
    if os.path.exists(p):
        return p
    im = BG.copy()
    d = ImageDraw.Draw(im)
    tracked(d, (PX, 30), part.upper(), font(DEMI, 25), ACCENT + (255,), 4)
    f = font(HEAVY, 42)
    d.text((PX, 62), chapter, font=f, fill=(255, 255, 255, 255))
    im.convert('RGB').save(p)
    return p


def make_frame():
    p = f'{B}/png/frame.png'
    fr = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    rect = (PX, PY, PX + PW, PY + PH)
    r = 44
    corner = Image.new('L', (W, H), 0)
    ImageDraw.Draw(corner).rectangle(rect, fill=255)
    ImageDraw.Draw(corner).rounded_rectangle(rect, r, fill=0)
    fr.paste(BG, (0, 0), corner)
    d = ImageDraw.Draw(fr)
    d.rounded_rectangle((PX - 8, PY - 8, PX + PW + 8, PY + PH + 8), r + 8, outline=(58, 52, 96, 255), width=9)
    fr.save(p)
    return p


# ---------------------------------------------------------------- captions
def wrap(d, text, f, maxw):
    words, lines, cur = text.split(), [], ''
    for w in words:
        t = (cur + ' ' + w).strip()
        if d.textlength(t, font=f) <= maxw:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def caption_png(text):
    key = hashlib.md5(text.encode()).hexdigest()[:12]
    p = f'{B}/png/cap_{key}.png'
    if os.path.exists(p):
        return p
    f = font(DEMI, 42)
    tmp = Image.new('RGBA', (10, 10))
    d = ImageDraw.Draw(tmp)
    lines = wrap(d, text, f, 880)
    lh = 54
    w = int(max(d.textlength(l, font=f) for l in lines)) + 64
    h = lh * len(lines) + 36
    im = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, w, h), 30, fill=(10, 8, 22, 232), outline=(120, 100, 190, 160), width=2)
    for i, l in enumerate(lines):
        lw = d.textlength(l, font=f)
        d.text(((w - lw) / 2, 16 + i * lh), l, font=f, fill=(255, 255, 255, 255))
    im.save(p)
    return p


def caption_pos(path):
    w, h = Image.open(path).size
    return (W - w) // 2, 1795 - h // 2


# ---------------------------------------------------------------- cards
def card_png(name, title, sub=None, chip=None, bullets=None, icon=False, tiles=None, note=None, small_title=False, code=None):
    p = f'{B}/png/card_{name}.png'
    im = BG.copy()
    d = ImageDraw.Draw(im)
    y = 210
    if icon:
        ic = Image.open(REPO + '/site/assets/brand-512.png').convert('RGBA').resize((220, 220), Image.LANCZOS)
        mask = Image.new('L', (220, 220), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, 220, 220), 52, fill=255)
        im.paste(ic, ((W - 220) // 2, y), mask)
        y += 290
    if chip:
        f = font(DEMI, 30)
        tw = d.textlength(chip.upper(), font=f) + len(chip) * 4 + 56
        d.rounded_rectangle(((W - tw) / 2, y, (W + tw) / 2, y + 62), 31, fill=(70, 52, 140, 255))
        tracked(d, ((W - tw) / 2 + 28, y + 14), chip.upper(), f, (232, 222, 255, 255), 4)
        y += 120
    f = font(HEAVY, 62 if small_title else 86)
    for l in wrap(d, title, f, 900):
        lw = d.textlength(l, font=f)
        d.text(((W - lw) / 2, y), l, font=f, fill=(255, 255, 255, 255))
        y += (74 if small_title else 100)
    y += 24
    if sub:
        f = font(REG, 42)
        for l in wrap(d, sub, f, 860):
            lw = d.textlength(l, font=f)
            d.text(((W - lw) / 2, y), l, font=f, fill=MUTED + (255,))
            y += 60
        y += 30
    if code:
        f = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 38)
        lines = code
        bh = 62 * len(lines) + 40
        d.rounded_rectangle((90, y, W - 90, y + bh), 28, fill=(10, 8, 22, 235), outline=(120, 100, 190, 180), width=2)
        for i, l in enumerate(lines):
            d.text((130, y + 22 + i * 62), l, font=f, fill=(222, 214, 255, 255))
        y += bh + 40
    if bullets:
        fh, fb = font(DEMI, 42), font(REG, 36)
        for head, body in bullets:
            d.ellipse((96, y + 14, 120, y + 38), fill=ACCENT + (255,))
            d.text((150, y), head, font=fh, fill=(255, 255, 255, 255))
            y += 56
            for l in wrap(d, body, fb, 800):
                d.text((150, y), l, font=fb, fill=MUTED + (255,))
                y += 48
            y += 30
    if tiles:
        n = len(tiles)
        tw = 290
        gap = 30
        x0 = (W - (tw * n + gap * (n - 1))) // 2
        for i, t in enumerate(tiles):
            c = Image.open(t).convert('RGBA')
            c = c.resize((tw, int(c.height * tw / c.width)), Image.LANCZOS)
            m = Image.new('L', c.size, 0)
            ImageDraw.Draw(m).rounded_rectangle((0, 0) + c.size, 22, fill=255)
            im.paste(c, (x0 + i * (tw + gap), y), m)
        y += tiles and 440
    if note:
        f = font(REG, 30)
        for l in wrap(d, note, f, 880):
            lw = d.textlength(l, font=f)
            d.text(((W - lw) / 2, 1790), l, font=f, fill=(170, 164, 200, 255))
    im.convert('RGB').save(p)
    return p


# ---------------------------------------------------------------- stills as phone frames
def pad_still(path, name, scale=1.0):
    p = f'{B}/png/still_{name}.png'
    im = Image.open(path).convert('RGB')
    h = int(im.height * NW / im.width)
    im = im.resize((NW, h), Image.LANCZOS)
    canvas = Image.new('RGB', (NW, NH), APP_BG)
    canvas.paste(im, (0, (NH - h) // 2))
    canvas.save(p)
    return p


# ---------------------------------------------------------------- detection
def frames_small(src, fps=8):
    cmd = f'ffmpeg -v error -i "{src}" -vf fps={fps},scale=270:606 -f rawvideo -pix_fmt rgb24 -'
    raw = subprocess.run(cmd, shell=True, capture_output=True).stdout
    n = len(raw) // (270 * 606 * 3)
    return np.frombuffer(raw[:n * 270 * 606 * 3], dtype=np.uint8).reshape(n, 606, 270, 3).astype(np.int16)


def match_windows(src, box, ref_src, ref_t, thr=6.0, fps=8, pad_before=0.3, pad_after=0.35):
    """Times (in src seconds) where `box` (native px x0,y0,x1,y1) looks like the reference frame."""
    fr = frames_small(src, fps)
    rf = frames_small(ref_src, fps)
    ref = rf[min(int(round(ref_t * fps)), len(rf) - 1)]
    x0, y0, x1, y1 = [v // 4 for v in box]
    reg = fr[:, y0:y1, x0:x1, :]
    diff = np.abs(reg - ref[y0:y1, x0:x1, :][None]).mean(axis=(1, 2, 3))
    ok = diff < thr
    wins, start = [], None
    for i, o in enumerate(ok):
        t = i / fps
        if o and start is None:
            start = t
        if not o and start is not None:
            wins.append([start - pad_before, t + pad_after])
            start = None
    if start is not None:
        wins.append([start - pad_before, len(ok) / fps + 1])
    merged = []
    for a, b in wins:
        if merged and a <= merged[-1][1] + 0.2:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([max(a, 0), b])
    return merged


def map_intervals(wins, segs):
    """Map source-time intervals to output time through the (a,b,speed) segment list."""
    out, base = [], 0.0
    for a, b, sp in segs:
        for s, e in wins:
            lo, hi = max(s, a), min(e, b)
            if hi > lo:
                out.append([base + (lo - a) / sp, base + (hi - a) / sp])
        base += (b - a) / sp
    return out


def src2out(t, segs):
    base = 0.0
    for a, b, sp in segs:
        if t <= a:
            return base
        if t < b:
            return base + (t - a) / sp
        base += (b - a) / sp
    return base


def en(intervals):
    if not intervals:
        return '0'
    return '+'.join(f"between(t,{a:.3f},{b:.3f})" for a, b in intervals)


# ---------------------------------------------------------------- patches (privacy masks)
def key_patch():
    p = f'{B}/png/keypatch.png'
    im = Image.new('RGBA', (NW, NH), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rectangle((58, 1068, 1026, 1178), fill=APP_BG + (255,))
    f = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 44)
    d.text((84, 1098), 'sk-or-v1-EXAMPLE-NOT-A-REAL-KEY', font=f, fill=(255, 255, 255, 255))
    im.save(p)
    return p


def list_cover():
    p = f'{B}/png/listcover.png'
    im = Image.new('RGBA', (NW, NH), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rectangle((0, 1396, NW, NH), fill=APP_BG + (255,))
    f = font(DEMI, 40)
    t = 'Your backed-up books are listed here'
    d.text(((NW - d.textlength(t, font=f)) / 2, 1700), t, font=f, fill=(160, 154, 190, 255))
    im.save(p)
    return p


def status_strip():
    p = f'{B}/png/strip.png'
    im = Image.new('RGBA', (NW, NH), (0, 0, 0, 0))
    ImageDraw.Draw(im).rectangle((0, 0, NW, 118), fill=APP_BG + (255,))
    im.save(p)
    return p
