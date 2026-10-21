"""Inspect actual simulator-produced narration, source coverage and assets."""
import pathlib,sys,json,wave,array
root=pathlib.Path(sys.argv[1]); books={}
for p in root.rglob('manifest.json'):
    try:m=json.loads(p.read_text())
    except (ValueError,OSError):continue
    title=m.get('title')
    if title not in books or m.get('generated_at','')>books[title][0].get('generated_at',''):books[title]=(m,p.parent)
for title in ['native-illustrated','native-novel','native-scanned']:
    assert title in books, f'Missing generated {title}'
    m,folder=books[title];all_text=[]
    assert len(m['figures'])==(0 if title=='native-novel' else 1)
    for section in m['sections']:
        with wave.open(str(folder/section['audio_path'])) as w:
            assert w.getframerate()==24000 and w.getnchannels()==1
            samples=array.array('h',w.readframes(w.getnframes()));assert max(map(abs,samples),default=0)>100
            assert abs(section['duration_ms']-len(samples)*1000/24000)<2
        segs=json.loads((folder/section['segments_path']).read_text())['segments'];all_text.extend(s['text'] for s in segs)
        assert segs[-1]['end_ms']<=section['duration_ms']
    text=' '.join(all_text).lower()
    if title=='native-novel':
        assert 'the light is ready' in text and 'let us go' in text
        roster=json.loads((folder/'character_roster.json').read_text());assert {c['name']:c['gender'] for c in roster}=={'Alice':'female','Bob':'male'}
    else:assert 'three volts' in text and 'switch is closed' in text
    print(title, 'PASS',len(m['sections']),'sections',m['total_duration_ms'],'ms')
