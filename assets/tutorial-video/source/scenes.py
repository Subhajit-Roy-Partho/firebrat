from render import *

P1, P2, P3 = 'Part 1 · Feature tour', 'Part 2 · Free LLM key', 'Part 3 · Advanced topics'
RAW = R + '/raw/'
S_ = SRC + '/'

SCENES = []   # each: dict(kind, id, chapter(optional title for chapters.txt), ...)


def card(id, d, chapter=None, **kw):
    SCENES.append(dict(kind='card', id=id, d=d, chapter=chapter, png=card_png(id, **kw),
                       cue=' — '.join(x for x in (kw.get('title'), kw.get('sub')) if x)))


def clip(id, part, header, src, segs, caps, masks=(), chapter=None, play=None):
    SCENES.append(dict(kind='clip', id=id, part=part, header=header, src=RAW + src, segs=segs, caps=caps,
                       masks=masks, chapter=chapter))


def still(id, part, header, png, d, caps, chapter=None, name=None):
    SCENES.append(dict(kind='still', id=id, part=part, header=header, still=pad_still(png, name or id), d=d,
                       caps=caps, chapter=chapter))


def chapter_card(id, part, num, title, sub, chapter=None, d=2.6):
    card(id, d, chapter=chapter or f'{num} {title}', chip=f'{part.split(" · ")[0]} · {num}', title=title, sub=sub, small_title=len(title) > 24)


# ------------------------------------------------------------------ mock-ups of the OpenRouter website
def mock(id, step, title, url, draw_body, caption):
    im = BG.copy()
    d = ImageDraw.Draw(im)
    tracked(d, (90, 150), f'STEP {step} OF 4', font(DEMI, 30), ACCENT + (255,), 5)
    f = font(HEAVY, 64)
    y = 205
    for l in wrap(d, title, f, 900):
        d.text((90, y), l, font=f, fill=(255, 255, 255, 255))
        y += 78
    # browser panel
    x0, y0, x1, y1 = 70, 450, 1010, 1330
    d.rounded_rectangle((x0, y0, x1, y1), 34, fill=(246, 245, 250, 255))
    d.rounded_rectangle((x0, y0, x1, y0 + 92), 34, fill=(224, 222, 236, 255))
    d.rectangle((x0, y0 + 60, x1, y0 + 92), fill=(224, 222, 236, 255))
    for i, c in enumerate(((236, 106, 96), (240, 190, 80), (96, 200, 110))):
        d.ellipse((x0 + 30 + i * 36, y0 + 33, x0 + 52 + i * 36, y0 + 55), fill=c + (255,))
    d.rounded_rectangle((x0 + 170, y0 + 20, x1 - 40, y0 + 72), 26, fill=(255, 255, 255, 255))
    d.text((x0 + 200, y0 + 28), url, font=font(REG, 34), fill=(90, 86, 110, 255))
    draw_body(d, (x0, y0 + 92, x1, y1))
    f = font(DEMI, 40)
    y = 1380
    for l in wrap(d, caption, f, 900):
        d.text((90, y), l, font=f, fill=(255, 255, 255, 255))
        y += 54
    fn = font(REG, 29)
    d.text((90, 1800), 'Illustration only: not a screenshot of the live site. Keys shown here are placeholders.', font=fn, fill=(170, 164, 200, 255))
    p = f'{B}/png/card_{id}.png'
    im.convert('RGB').save(p)
    return p


def btn(d, box, text, fill=(88, 64, 200, 255), fg=(255, 255, 255, 255), size=38):
    d.rounded_rectangle(box, 22, fill=fill)
    f = font(DEMI, size)
    tw = d.textlength(text, font=f)
    d.text(((box[0] + box[2] - tw) / 2, box[1] + (box[3] - box[1] - size) / 2 - 4), text, font=f, fill=fg)


def body1(d, b):
    x0, y0, x1, y1 = b
    ink, grey = (40, 36, 64, 255), (120, 116, 140, 255)
    d.text((x0 + 60, y0 + 70), 'Create your free account', font=font(HEAVY, 52), fill=ink)
    d.text((x0 + 60, y0 + 140), 'An email address or a Google login is enough.', font=font(REG, 34), fill=grey)
    btn(d, (x0 + 60, y0 + 250, x1 - 60, y0 + 340), 'Continue with email')
    btn(d, (x0 + 60, y0 + 370, x1 - 60, y0 + 460), 'Continue with Google', fill=(255, 255, 255, 255), fg=ink)
    d.rounded_rectangle((x0 + 60, y0 + 520, x1 - 60, y0 + 600), 18, outline=(200, 196, 220, 255), width=3)
    d.text((x0 + 90, y0 + 538), 'you@example.com', font=font(REG, 36), fill=grey)


def body2(d, b):
    x0, y0, x1, y1 = b
    ink, grey = (40, 36, 64, 255), (120, 116, 140, 255)
    d.text((x0 + 60, y0 + 50), 'API keys', font=font(HEAVY, 52), fill=ink)
    btn(d, (x1 - 380, y0 + 40, x1 - 60, y0 + 120), 'Create key', size=36)
    d.rounded_rectangle((x0 + 60, y0 + 190, x1 - 60, y0 + 330), 22, fill=(236, 234, 246, 255))
    d.text((x0 + 90, y0 + 210), 'Name: firebrat', font=font(DEMI, 36), fill=ink)
    d.text((x0 + 90, y0 + 262), 'sk-or-v1-EXAMPLE-NOT-A-REAL-KEY', font=font(REG, 32), fill=grey)
    btn(d, (x0 + 60, y0 + 380, x0 + 330, y0 + 460), 'Copy', fill=(255, 255, 255, 255), fg=ink, size=36)
    d.rounded_rectangle((x0 + 60, y0 + 520, x1 - 60, y0 + 650), 22, fill=(255, 240, 214, 255))
    d.text((x0 + 90, y0 + 540), 'The key is shown only once.', font=font(DEMI, 36), fill=(120, 80, 10, 255))
    d.text((x0 + 90, y0 + 590), 'Copy it before you close this box.', font=font(REG, 34), fill=(120, 80, 10, 255))


def body3(d, b):
    x0, y0, x1, y1 = b
    ink, grey = (40, 36, 64, 255), (120, 116, 140, 255)
    d.text((x0 + 60, y0 + 50), 'Models', font=font(HEAVY, 52), fill=ink)
    btn(d, (x0 + 60, y0 + 140, x0 + 260, y0 + 210), 'Free', size=34)
    for i, n in enumerate(('example-model-a:free', 'example-model-b:free', 'example-model-c:free')):
        yy = y0 + 260 + i * 140
        d.rounded_rectangle((x0 + 60, yy, x1 - 60, yy + 110), 20, fill=(236, 234, 246, 255))
        d.text((x0 + 90, yy + 30), n, font=font(DEMI, 36), fill=ink)
        btn(d, (x1 - 290, yy + 25, x1 - 90, yy + 85), 'free', fill=(214, 240, 222, 255), fg=(30, 110, 60, 255), size=30)


def body4(d, b):
    x0, y0, x1, y1 = b
    ink, grey = (40, 36, 64, 255), (120, 116, 140, 255)
    d.text((x0 + 60, y0 + 60), 'Treat the key like a password', font=font(HEAVY, 46), fill=ink)
    items = ('Never post it or put it in a screenshot', 'Paste it only into the app\'s API key field', 'You can delete the key and make a new one any time')
    for i, t in enumerate(items):
        yy = y0 + 190 + i * 150
        d.ellipse((x0 + 60, yy + 6, x0 + 100, yy + 46), fill=(88, 64, 200, 255))
        for j, l in enumerate(wrap(d, t, font(REG, 38), 700)):
            d.text((x0 + 130, yy + j * 48), l, font=font(REG, 38), fill=ink)


MOCKS = [
    mock('mock1', 1, 'Sign up for free', 'openrouter.ai', body1, 'Create a free account at openrouter.ai. An email or a Google login is enough.'),
    mock('mock2', 2, 'Keys › Create key', 'openrouter.ai/keys', body2, 'Open Keys, tap Create key, give it any name and copy it. It is shown only once.'),
    mock('mock3', 3, 'Pick a free model', 'openrouter.ai/models', body3, 'Filter by Free. Free model IDs end in :free. The app can list them for you.'),
    mock('mock4', 4, 'Keep the key private', 'openrouter.ai/keys', body4, 'Paste the key only into Firebrat. Free providers may log prompts, so keep private books on-device.'),
]

# ================================================================== SCRIPT
card('intro', 6.0, chapter='Intro', title='Firebrat', sub='Turn PDFs and ebooks into narrated audiobooks. Private by default.', chip='Full tutorial · v1.7.2', icon=True,
     note='No narration: follow the captions.')
card('p1', 4.2, chapter=None, chip='Part 1', title='Feature tour', sub='From the first launch to your first listen.')

# ---- 1.1 guide
chapter_card('c11', P1, '1.1', 'First-run guide', 'A 10-page tour opens on first launch.')
clip('guide', P1, '1.1 First-run guide', 'guide.mp4', [(1.0, 39.2, 1.2)], [
    (1.0, 3.6, 'Open the menu, then App guide'),
    (3.8, 7.6, 'The guide opens by itself on first launch. Reopen it any time'),
    (7.6, 12.2, 'Library, layout and theme'),
    (12.2, 14.8, 'Adding books, the queue and keeping it running'),
    (14.8, 17.8, 'Reading: section bar, cast & voices, focus mode'),
    (17.8, 22.0, 'Listening: play, speed and autoplay'),
    (22.0, 24.8, 'Three modes: Offline, Server or On-device'),
    (24.8, 27.6, 'Which on-device model suits your phone'),
    (27.6, 31.6, 'Faster with a free cloud LLM'),
    (31.6, 34.6, 'Google Drive sync'),
    (34.6, 39.2, 'Settings, sync and privacy live in the menu'),
], masks=('drawer',))

# ---- 1.2 library
chapter_card('c12', P1, '1.2', 'Your library and cover art', 'Every book gets a cover.')
clip('lib_a', P1, '1.2 Your library and cover art', 'library.mp4', [(1.8, 4.4, 1.0)], [
    (1.8, 4.4, 'Your library: every book has a cover'),
])
still('lib_b', P1, '1.2 Your library and cover art', S_ + 'library-dark.png', 5.0, [
    (0.2, 2.6, 'Ebooks keep their own cover. Other books get a generated one'),
    (2.7, 5.0, 'A larger shelf (illustrative sample titles)'),
], name='librarydark')

# ---- 1.3 reader
chapter_card('c13', P1, '1.3', 'Open a book and listen', 'Play, speed, sections, focus mode.')
clip('reader', P1, '1.3 Open a book and listen', 'reader.mp4', [(2.2, 9.0, 1.0), (9.0, 15.0, 2.5), (15.0, 53.7, 1.0)], [
    (2.4, 3.9, 'Tap a book to open it'),
    (4.2, 7.0, 'Illustrated mode: pictures stay in sync with the text'),
    (7.0, 15.4, 'Press play: the spoken sentence is highlighted'),
    (15.6, 19.6, 'Speed chip: 0.75× to 2×'),
    (19.8, 23.2, 'Previous / next segment'),
    (23.4, 27.6, 'Section bar: previous and next section'),
    (28.6, 33.2, 'Menu: jump to any section'),
    (33.8, 37.8, 'Text size slider'),
    (38.0, 43.4, 'Focus mode: just the picture'),
    (44.0, 50.0, 'Source page: the original PDF page'),
    (50.2, 53.6, 'Audio keeps playing with the screen off'),
])
card('lock', 4.5, title='Cover art on your lock screen', sub='While you listen, the book cover appears on the lock screen and in the notification, and playback keeps going with the screen off.', small_title=True,
     tiles=[S_ + 'cover-pride.png', S_ + 'cover-alice.png', S_ + 'cover-sherlock.png'])

# ---- 1.4 add books
chapter_card('c14', P1, '1.4', 'Import or convert a book', 'PDF, EPUB, MOBI, AZW or a finished package.')
card('addbooks', 8.4, title='Add a book', small_title=True, bullets=[
    ('Import', 'Pick a finished .tar.gz or .zip package (top right of the library).'),
    ('Convert', 'Conversions › Convert a book: PDF, a ZIP of PDFs, or a DRM-free EPUB, MOBI, AZW or AZW3.'),
    ('Queue', 'Pick many books at once, or keep adding while one converts.'),
    ('Ebooks', 'Read as text in chapter order: no pictures and no Source page.'),
])

# ---- 1.5 modes
chapter_card('c15', P1, '1.5', 'Novel mode vs Illustrated mode', 'Choose the book type per conversion.')
clip('modes', P1, '1.5 Novel mode vs Illustrated mode', 'settings.mp4', [(4.4, 9.6, 1.0)], [
    (4.6, 9.6, 'Menu › Conversion settings › Book type'),
], masks=('drawer',))
still('modes_i', P1, '1.5 Novel mode vs Illustrated mode', S_ + 'dev-modes-illustrated.png', 4.5, [
    (0.2, 4.5, 'Illustrated / technical: figures, tables and formulas stay on screen'),
])
still('modes_n', P1, '1.5 Novel mode vs Illustrated mode', S_ + 'dev-modes-novel.png', 5.0, [
    (0.2, 5.0, 'Novel / characters: prose kept word for word, each speaker gets a voice'),
])

# ---- 1.6 cast
chapter_card('c16', P1, '1.6', 'Cast & voices', 'See who speaks and how they sound.')
clip('cast', P1, '1.6 Cast & voices', 'cast.mp4', [(3.2, 25.6, 1.0)], [
    (3.4, 6.8, 'In a novel, tap the people icon for Cast & voices'),
    (7.0, 11.0, '25 speakers found. 29% of the dialogue has a named speaker'),
    (11.2, 15.0, 'Web research used: some characters described from Wikipedia'),
    (15.2, 22.6, 'Each speaker: lines, traits and the voice they were given'),
    (22.8, 25.6, 'Back in the reader'),
])

# ---- 1.7 queue
chapter_card('c17', P1, '1.7', 'The conversion queue', 'Several books, Stop, and battery.')
clip('queue', P1, '1.7 The conversion queue', 'pause.mp4', [(2.6, 9.0, 1.0)], [
    (2.8, 5.6, 'Conversions: books convert one after another'),
    (5.8, 9.0, 'Stop ends the current book and the next one starts'),
])
card('battery', 6.0, title='Long books: keep it running', small_title=True, bullets=[
    ('Background', 'Conversion carries on with the screen off.'),
    ('Battery', 'Allow unrestricted battery use for Firebrat. The Conversions screen shows a button for it.'),
    ('Charging', 'Keep the phone plugged in for a long book.'),
])

# ---- 1.8 pause / resume
chapter_card('c18', P1, '1.8', 'Pause and resume', 'New in 1.7.2.')
PAUSE_SEGS = [(2.6, 13.5, 1.0), (13.5, 59.0, 4.0), (59.0, 68.6, 1.0)]
clip('pause', P1, '1.8 Pause and resume · new in 1.7.2', 'pause.mp4', PAUSE_SEGS, [
    (2.8, 5.6, 'The banner has Pause and Stop'),
    (5.8, 8.8, 'Every queue row has pause and stop icons too'),
    (9.2, 13.4, 'Paused. Progress is saved. Tap Resume to carry on'),
    (13.6, 59.0, 'Resume re-reads the PDF text layer (sped up)'),
    (59.2, 64.0, 'Then it carries on: “resuming after section 6 of 463”'),
    (64.2, 68.6, 'Every finished section is kept'),
])

# ---- 1.9 listen while converting
chapter_card('c19', P1, '1.9', 'Listen while it converts', 'New in 1.7.2.')
clip('listen', P1, '1.9 Listen while it converts · new in 1.7.2', 'listen.mp4', [(0.4, 16.0, 1.0), (16.0, 33.0, 2.0)], [
    (0.6, 3.4, 'A hourglass badge marks a book that is still converting'),
    (4.2, 10.0, 'Open it any time: “Still converting: 6 of 463 sections ready”'),
    (10.2, 15.6, 'Play what is ready while the rest converts'),
    (15.8, 33.0, 'At the last ready section: “Waiting for the next section… Playback continues by itself.”'),
])

# ---- 1.10 drawer
chapter_card('c110', P1, '1.10', 'The menu', 'Avatar, guide and settings.', d=4.8)
clip('drawer', P1, '1.10 The menu', 'library.mp4', [(4.2, 9.8, 1.0)], [
    (4.3, 6.8, 'Your avatar and sign-in status sit at the top (account name blurred)'),
    (6.9, 9.6, 'Library, Conversions, settings, Sync & backup, App guide'),
], masks=('drawer',))

# ---- 1.11 drive
chapter_card('c111', P1, '1.11', 'Drive backup and sync', 'Where to find them.')
clip('sync', P1, '1.11 Drive backup and sync', 'sync.mp4', [(1.9, 9.8, 1.0)], [
    (2.0, 4.2, 'Menu › Sync & backup'),
    (4.4, 9.8, 'Reading position follows your Google account. Books stay on your phone or in your own Drive'),
], masks=('drawer', 'sync'))
clip('guide_drive', P1, '1.11 Drive backup and sync', 'guide.mp4', [(32.0, 34.8, 1.0)], [
    (32.1, 34.8, 'Conversion settings › Get finished books from where? › My Google Drive'),
], masks=())

# ================================================================== PART 2
card('p2', 3.2, chapter=None, chip='Part 2', title='Free LLM key from OpenRouter', sub='Get a key, paste it into Firebrat, test it.', small_title=True)
chapter_card('c21', P2, '2.1', 'The in-app guide', 'Conversion settings › Cloud LLM.', chapter='2.1 Free key: the in-app guide')
clip('llm_a', P2, '2.1 The in-app guide', 'llm_a.mp4', [(3.8, 27.2, 1.0)], [
    (3.9, 7.2, 'Menu › Conversion settings'),
    (7.4, 10.0, 'Cloud LLM › How to get a free API key'),
    (10.2, 15.6, 'OpenRouter is recommended. Free models end in :free'),
    (15.8, 22.6, 'Groq and Google AI Studio work the same way: URL, key, model'),
    (22.8, 27.2, '“Use this URL” fills in the address for you'),
], masks=('drawer', 'key'))
chapter_card('c22', P2, '2.2', 'Create the key on OpenRouter', 'Sign up, Keys › Create key, copy.', chapter='2.2 Create the key on OpenRouter')
for i, m in enumerate(MOCKS):
    SCENES.append(dict(kind='still_png', id=f'mock{i + 1}', png=m, d=4.2, cue=None, chapter=None))
chapter_card('c23', P2, '2.3', 'Paste, load models, test', 'URL, key, Load models, Test connection.', chapter='2.3 Paste the key, load models, test')
clip('llm_b1', P2, '2.3 Paste the key, load models, test', 'llm_b.mp4', [(4.8, 12.4, 1.0)], [
    (4.9, 8.0, 'Back in Conversion settings › Cloud LLM'),
    (8.2, 10.2, 'LLM URL: https://openrouter.ai/api/v1'),
    (10.2, 12.4, 'API key: paste yours (placeholder shown)'),
], masks=('drawer', 'key'))
clip('llm_b2', P2, '2.3 Paste the key, load models, test', 'llm_b.mp4', [(12.4, 16.6, 1.0)], [
    (12.5, 16.6, 'Load models: 467 found, 17 free'),
], masks=('key',))
still('llm_pick', P2, '2.3 Paste the key, load models, test', S_ + 'dev-llm-test.png', 4.5, [
    (0.2, 4.5, 'Pick a free model: type “free” to search the list'),
], name='llmtest')
clip('llm_b3', P2, '2.3 Paste the key, load models, test', 'llm_b.mp4', [(16.6, 22.8, 1.0)], [
    (16.7, 18.0, 'Test connection'),
    (18.1, 22.8, 'Connected: the free model answered'),
], masks=('key',))
card('limits', 6.0, title='Good to know', small_title=True, bullets=[
    ('Free limits', 'About 20 requests a minute, and 50 a day until you have bought 10 credits.'),
    ('Privacy', 'Free providers may log prompts. Use the on-device model for private books.'),
    ('Errors', '401: paste the whole key again. 404: the URL must end in /v1. 429: wait a minute.'),
])

# ================================================================== PART 3
card('p3', 3.2, chapter=None, chip='Part 3', title='Advanced topics', sub='Short chapters you can jump to.')
chapter_card('c31', P3, '3.1', 'Character voice overrides', 'Voice names and trait words.')
still('ovr', P3, '3.1 Character voice overrides', S_ + 'dev-novel-voices.png', 5.5, [
    (0.2, 2.8, 'Conversion settings › Character voice overrides'),
    (2.9, 5.5, 'One character per line: Name=Voice, Name=traits, or both'),
], name='novelvoices')
card('ovr_ex', 8.0, title='Examples', small_title=True, code=['Alice=child cheerful', 'Mad Hatter=Michael, elder, gruff', 'Queen of Hearts=female stern', 'Wolf=elder gruff female'],
     sub='Voices: Default, Bella, Nicole, Sarah, Adam, Michael. Traits: child, young, adult, elder; calm, cheerful, stern, gruff, gentle, energetic, mysterious; male, female.')

chapter_card('c32', P3, '3.2', 'Automatic web research', 'Only the title and names are sent.')
clip('research', P3, '3.2 Automatic web research', 'settings.mp4', [(18.4, 24.0, 1.0)], [
    (18.5, 24.0, '“Research characters online”: the book is looked up on Wikipedia'),
])
clip('research2', P3, '3.2 Automatic web research', 'cast.mp4', [(8.6, 14.6, 1.0)], [
    (8.7, 14.6, 'Cast & voices shows what the research found and missed'),
])
card('research_note', 5.5, title='What is sent', small_title=True, bullets=[
    ('Sent', 'Only the book title and the character names.'),
    ('Never sent', 'The text of the book.'),
    ('Your say', 'Your own overrides always win over research.'),
])

chapter_card('c33', P3, '3.3', 'Queue, background and battery', 'Keep long conversions running.')
clip('guide_queue', P3, '3.3 Queue, background and battery', 'guide.mp4', [(12.0, 15.2, 1.0)], [
    (12.1, 15.2, 'Adding books › Queue several books › Keep it running'),
])
clip('queue2', P3, '3.3 Queue, background and battery', 'pause.mp4', [(2.6, 9.0, 1.0)], [
    (2.8, 9.0, 'One book at a time. Add more while one converts'),
])

chapter_card('c34', P3, '3.4', 'Cloud for all vs on-device LLM', 'Speed against privacy.')
clip('cloudall', P3, '3.4 Cloud for all vs on-device LLM', 'settings.mp4', [(7.0, 11.4, 1.0)], [
    (7.2, 11.4, 'Allow cloud helper  ·  Use the cloud LLM for every passage'),
])
card('cloud3', 8.0, title='Three ways to run', small_title=True, bullets=[
    ('Cloud helper only', 'Easy passages stay on the phone. Equations, figures and tables go to your LLM.'),
    ('Cloud for every passage', 'Fastest, no model download. All of the book\'s text goes to your provider.'),
    ('Fully local', 'Slowest, most private. Nothing leaves the phone after the one-time downloads.'),
])

chapter_card('c35', P3, '3.5', 'Ebooks and book covers', 'EPUB, MOBI, AZW and AZW3.')
card('ebooks', 8.0, title='Ebooks', small_title=True, bullets=[
    ('Formats', 'DRM-free EPUB, MOBI, AZW and AZW3, on the phone or on a server.'),
    ('Text only', 'Read in chapter order. Great for Novel mode.'),
    ('DRM', 'Protected books are refused with a clear message. Convert to EPUB first.'),
    ('Covers', 'A real cover when the book has one, otherwise a generated one.'),
], tiles=None)

chapter_card('c36', P3, '3.6', 'Pause, resume and partial listening', 'New in 1.7.2.')
clip('pause_b', P3, '3.6 Pause, resume and partial listening', 'pause.mp4', [(9.0, 13.6, 1.0), (59.0, 68.6, 1.0)], [
    (9.2, 13.4, 'Pause: progress is saved'),
    (13.8, 18.4, 'Resume: “resuming after section 6 of 463”'),
])
clip('listen_b', P3, '3.6 Pause, resume and partial listening', 'listen.mp4', [(4.0, 12.0, 1.0)], [
    (4.2, 12.0, 'Listen to the finished sections while the book converts'),
])

chapter_card('c37', P3, '3.7', 'Google Drive private backup', 'Only files Firebrat creates.')
clip('drive2', P3, '3.7 Google Drive private backup', 'guide.mp4', [(32.0, 34.8, 1.0)], [
    (32.1, 34.8, 'Back up finished books to your own Drive'),
])
card('drive_note', 6.0, title='Private by design', small_title=True, bullets=[
    ('Permission', 'Firebrat asks only for files it creates itself (drive.file).'),
    ('Layout', 'A Firebrat folder in your Drive, one zip per book.'),
    ('Control', 'Per-book backup, Sync now, and you can turn it off any time.'),
])

chapter_card('c38', P3, '3.8', 'Privacy and offline-first', 'You decide what leaves the phone.')
still('priv', P3, '3.8 Privacy and offline-first', S_ + 'dev-settings-ondevice-2.png', 5.0, [
    (0.2, 5.0, 'On-device model and offline narrator voice: no account, no server'),
], name='ondevice')
card('priv_note', 8.0, title='Your choices', small_title=True, bullets=[
    ('Stays on the phone', 'Offline mode and On-device mode need no server or account after the one-time downloads.'),
    ('Only if you turn it on', 'Cloud helper, cloud for every passage, web research and Drive sync.'),
    ('Keys', 'Your API key is stored only on the phone and sent only to the URL you set.'),
])
card('outro', 7.0, chapter=None, title='Thanks for watching', sub='Guide and downloads: subhajit-roy-partho.github.io/firebrat', icon=True,
     note='Firebrat is open source (AGPL-3.0). Bring books you have permission to use.')
