import sys
sys.path.insert(0, '.')
from render import *

PP = 'Firebrat'
parts = []


def add(r):
    parts.append(r)


add(render_card('play_intro', card_png('play_intro', 'Firebrat', sub='Turn your PDFs and ebooks into narrated audiobooks.', icon=True), 3.0))
add(render_clip('play_lib', PP, 'Every book gets a cover', None, None, [(0.2, 4.2, 'A cover for every book (sample shelf)')],
                still=pad_still(SRC + '/library-dark.png', 'librarydark'), d=4.2))
add(render_clip('play_reader', PP, 'Listen and follow', R + '/raw/reader.mp4', [(6.6, 15.2, 1.0)],
                [(6.8, 15.0, 'Press play. The spoken sentence is highlighted')]))
add(render_clip('play_cast', PP, 'Novel mode: Cast & voices', R + '/raw/cast.mp4', [(7.0, 12.8, 1.0)],
                [(7.1, 12.8, 'Novels get a cast: every speaker has a voice')]))
add(render_clip('play_listen', PP, 'New: listen while it converts', R + '/raw/listen.mp4', [(4.2, 10.2, 1.0)],
                [(4.3, 10.2, 'Start listening while the rest converts')]))
add(render_clip('play_pause', PP, 'New: pause and resume', R + '/raw/pause.mp4', [(9.2, 13.4, 1.0)],
                [(9.3, 13.4, 'Pause and resume. Progress is saved')]))
add(render_clip('play_llm', PP, 'Free cloud LLM', R + '/raw/llm_b.mp4', [(16.6, 22.8, 1.0)],
                [(16.7, 22.8, 'Paste a free OpenRouter key, test, and go')], masks=('key',)))
add(render_card('play_priv', card_png('play_priv', 'Private by default', sub='Convert on your phone with nothing leaving the device. Use a cloud LLM only if you choose.', small_title=False), 4.0))
add(render_card('play_outro', card_png('play_outro', 'Firebrat', sub='Audiobooks from your own books.', icon=True, note='Bring books you have permission to use.'), 3.5))

lst = f'{B}/play.txt'
open(lst, 'w').write(''.join(f"file '{r['path']}'\n" for r in parts))
os.makedirs(f'{B}/out', exist_ok=True)
run(f'ffmpeg -v error -y -f concat -safe 0 -i {lst} -c copy -movflags +faststart {B}/out/firebrat-play-promo.mp4')
print('play total', sum(r['dur'] for r in parts))
