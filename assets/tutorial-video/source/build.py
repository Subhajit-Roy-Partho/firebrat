import sys, json
sys.path.insert(0, '.')
from scenes import *

only = sys.argv[1:]   # optional ids to (re)render


def fmt(t, srt=False):
    t = max(0, t)
    h, m, s = int(t // 3600), int(t % 3600 // 60), t % 60
    if srt:
        return f'{h:02d}:{m:02d}:{int(s):02d},{int(round((s - int(s)) * 1000)):03d}'
    return f'{h}:{m:02d}:{int(s):02d}' if h else f'{m}:{int(s):02d}'


results = []
for sc in SCENES:
    out = f'{B}/parts/{sc["id"]}.mp4'
    if only and sc['id'] not in only and os.path.exists(out):
        # keep previous render, reload its duration
        r = dict(id=sc['id'], path=out, dur=dur(out), cues=json.load(open(out + '.cues.json')) if os.path.exists(out + '.cues.json') else [])
    elif not only and os.path.exists(out) and os.path.exists(out + '.cues.json') and os.environ.get('REUSE'):
        r = dict(id=sc['id'], path=out, dur=dur(out), cues=json.load(open(out + '.cues.json')))
    else:
        print('render', sc['id'], flush=True)
        if sc['kind'] == 'card':
            r = render_card(sc['id'], sc['png'], sc['d'], cues=[(0.2, sc['d'] - 0.2, sc['cue'])] if sc['cue'] else [])
        elif sc['kind'] == 'still_png':
            r = render_card(sc['id'], sc['png'], sc['d'])
        elif sc['kind'] == 'still':
            r = render_clip(sc['id'], sc['part'], sc['header'], None, None, sc['caps'], still=sc['still'], d=sc['d'])
        else:
            r = render_clip(sc['id'], sc['part'], sc['header'], sc['src'], sc['segs'], sc['caps'], masks=sc['masks'])
        json.dump(r['cues'], open(out + '.cues.json', 'w'))
    r['chapter'] = sc.get('chapter')
    results.append(r)

# concat full video
lst = f'{B}/full.txt'
open(lst, 'w').write(''.join(f"file '{r['path']}'\n" for r in results))
os.makedirs(f'{B}/out', exist_ok=True)
run(f'ffmpeg -v error -y -f concat -safe 0 -i {lst} -c copy -movflags +faststart {B}/out/firebrat-tutorial-full.mp4')

# timeline, chapters, srt
t = 0.0
chapters, cues, timeline = [], [], []
for r in results:
    timeline.append((r['id'], t, t + r['dur']))
    if r['chapter']:
        chapters.append((t, r['chapter']))
    for a, b, text in r['cues']:
        cues.append((t + a, t + b, text))
    t += r['dur']
total = t
open(f'{B}/out/chapters.txt', 'w').write('\n'.join(f'{fmt(a)} {name}' for a, name in chapters) + '\n')
with open(f'{B}/out/captions.srt', 'w') as f:
    for i, (a, b, text) in enumerate(cues, 1):
        f.write(f'{i}\n{fmt(a, True)} --> {fmt(b, True)}\n{text}\n\n')
json.dump(dict(total=total, timeline=timeline, chapters=chapters), open(f'{B}/out/timeline.json', 'w'), indent=1)
print('total', fmt(total), 'chapters', len(chapters), 'cues', len(cues))
