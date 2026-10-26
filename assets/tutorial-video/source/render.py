from lib import *

ENC = '-c:v libx264 -preset medium -crf 19 -r 30 -pix_fmt yuv420p -movflags +faststart -an'
FRAME = make_frame()
STRIP = status_strip()
KEYP = key_patch()
LISTC = list_cover()

_det = {}


def detect(kind, src):
    """Privacy-mask windows (source seconds) for a raw clip."""
    k = (kind, src)
    if k in _det:
        return _det[k]
    if kind == 'drawer':
        w = match_windows(src, (0, 220, 660, 560), R + '/raw/library.mp4', 6.5, thr=7)
    elif kind == 'sync':
        w = match_windows(src, (0, 150, 1080, 300), R + '/raw/sync.mp4', 6.5, thr=6, pad_before=0.0, pad_after=0.0)
    elif kind == 'key':
        w = match_windows(src, (44, 1030, 1036, 1200), R + '/raw/llm_b.mp4', 12.0, thr=6, pad_before=0.1, pad_after=0.1)
    _det[k] = w
    return w


def render_clip(sid, part, chapter, src, segs, caps, masks=(), still=None, d=None, out=None):
    """segs: [(a,b,speed)] in source seconds. caps: [(t0,t1,text)] in source seconds (clip) or output seconds (still)."""
    out = out or f'{B}/parts/{sid}.mp4'
    base = make_base(part, chapter)
    if still:
        total = d
        segs_eff = [(0, d, 1.0)]
    else:
        segs_eff = segs
        total = sum((b - a) / sp for a, b, sp in segs)
    inputs = [f'-loop 1 -framerate 30 -i "{base}"']
    if still:
        inputs.append(f'-loop 1 -framerate 30 -i "{still}"')
    else:
        inputs.append(f'-i "{src}"')
    inputs.append(f'-loop 1 -framerate 30 -i "{FRAME}"')          # 2
    inputs.append(f'-loop 1 -framerate 30 -i "{STRIP}"')          # 3
    extra = {}
    idx = 4
    flt = []
    # video pieces
    if still:
        flt.append('[1:v]setpts=PTS-STARTPTS[v0]')
    else:
        n = len(segs)
        if n == 1:
            a, b, sp = segs[0]
            flt.append(f'[1:v]fps=30,trim=start={a}:end={b},setpts=(PTS-STARTPTS)/{sp},fps=30[v0]')
        else:
            flt.append(f'[1:v]fps=30,split={n}' + ''.join(f'[i{i}]' for i in range(n)))
            for i, (a, b, sp) in enumerate(segs):
                flt.append(f'[i{i}]trim=start={a}:end={b},setpts=(PTS-STARTPTS)/{sp},fps=30[p{i}]')
            flt.append(''.join(f'[p{i}]' for i in range(n)) + f'concat=n={n}:v=1:a=0[v0]')
    cur = 'v0'
    if not still:
        flt.append(f'[{cur}][3:v]overlay=0:0[s0]')
        cur = 's0'
    k = 0

    def blur(cur, box, wins):
        nonlocal k
        x, y, w, h = box
        k += 1
        flt.append(f'[{cur}]split[a{k}][b{k}]')
        flt.append(f'[b{k}]crop={w}:{h}:{x}:{y},boxblur=lr=24:lp=3:cr=9:cp=3[bb{k}]')
        flt.append(f"[a{k}][bb{k}]overlay={x}:{y}:enable='{en(wins)}'[m{k}]")
        return f'm{k}'

    def patch(cur, png, wins):
        nonlocal idx, k
        inputs.append(f'-loop 1 -framerate 30 -i "{png}"')
        k += 1
        flt.append(f"[{cur}][{idx}:v]overlay=0:0:enable='{en(wins)}'[m{k}]")
        idx += 1
        return f'm{k}'

    masks_info = {}
    for m in masks:
        if m == 'drawer':
            wins = map_intervals(detect('drawer', src), segs_eff)
            masks_info[m] = wins
            if wins:
                cur = blur(cur, (0, 448, 700, 112), wins)
        elif m == 'sync':
            wins = map_intervals(detect('sync', src), segs_eff)
            masks_info[m] = wins
            if wins:
                cur = blur(cur, (0, 604, 1080, 80), wins)
                cur = patch(cur, LISTC, wins)
        elif m == 'key':
            wins = map_intervals(detect('key', src), segs_eff)
            masks_info[m] = wins
            if wins:
                cur = patch(cur, KEYP, wins)
    flt.append(f'[{cur}]scale={PW}:{PH}:flags=lanczos[vs]')
    flt.append(f'[0:v][vs]overlay={PX}:{PY}:shortest=0[c0]')
    flt.append('[c0][2:v]overlay=0:0[c1]')
    cur = 'c1'
    cues = []
    for i, (t0, t1, text) in enumerate(caps):
        if still:
            o0, o1 = t0, t1
        else:
            o0, o1 = src2out(t0, segs_eff), src2out(t1, segs_eff)
        if o1 - o0 < 0.4:
            continue
        o1 = min(o1, total)
        p = caption_png(text)
        cx, cy = caption_pos(p)
        inputs.append(f'-loop 1 -framerate 30 -i "{p}"')
        flt.append(f"[{cur}][{idx}:v]overlay={cx}:{cy}:enable='between(t,{o0:.3f},{o1:.3f})'[c{i + 2}]")
        cur = f'c{i + 2}'
        idx += 1
        cues.append((o0, o1, text))
    flt.append(f'[{cur}]format=yuv420p[vout]')
    fc = ';'.join(flt)
    fpath = f'{B}/parts/{sid}.filter'
    open(fpath, 'w').write(fc)
    cmd = f'ffmpeg -v error -y {" ".join(inputs)} -/filter_complex "{fpath}" -map "[vout]" -t {total:.3f} {ENC} "{out}"'
    run(cmd)
    return dict(id=sid, path=out, dur=dur(out), cues=cues, masks=masks_info)


def render_card(sid, png, d, cues=None):
    out = f'{B}/parts/{sid}.mp4'
    run(f'ffmpeg -v error -y -loop 1 -framerate 30 -i "{png}" -t {d} -vf format=yuv420p {ENC} "{out}"')
    return dict(id=sid, path=out, dur=dur(out), cues=cues or [])
