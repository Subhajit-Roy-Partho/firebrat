"""Compose actual, privacy-cropped browser captures; never recreate provider UI."""
import json,math,subprocess,textwrap,re,difflib
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
ROOT=Path(__file__).resolve().parents[4]
WORK=ROOT/'tmp/key-tutorial'; OUT=ROOT/'assets/tutorial-video/free-key-real'
OUT.mkdir(exist_ok=True); (WORK/'frames').mkdir(exist_ok=True); (WORK/'parts').mkdir(exist_ok=True)
FONT='/System/Library/Fonts/Supplemental/Arial.ttf'; BOLD='/System/Library/Fonts/Supplemental/Arial Bold.ttf'
def font(n,b=False):return ImageFont.truetype(BOLD if b else FONT,n)
def wrap(draw,text,ft,width):
 lines=[];line=''
 for word in text.split():
  trial=(line+' '+word).strip()
  if draw.textlength(trial,font=ft)>width and line:lines.append(line);line=word
  else:line=trial
 if line:lines.append(line)
 return lines
def put(draw,text,y,size=44,color='#f7f6ff',bold=False,x=70,width=940,gap=1.25):
 for line in wrap(draw,text,font(size,bold),width):draw.text((x,y),line,font=font(size,bold),fill=color);y+=int(size*gap)
 return y
def probe(p):return float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0',str(p)]))
def frame(scene,i,caption):
 im=Image.new('RGB',(1080,1920));d=ImageDraw.Draw(im)
 for y in range(1920):
  t=y/1920;d.line((0,y,1080,y),fill=(int(12+10*t),int(10+5*t),int(28+20*t)))
 d.rounded_rectangle((70,80,1010,142),radius=28,fill='#29213f')
 d.text((95,94),'FIREBRAT   /   REAL WEBSITE WALKTHROUGH',font=font(26,True),fill='#c7baff')
 put(d,scene['title'],205,64,bold=True)
 put(d,scene['label'],310,30,color='#a9efd4',bold=True)
 sid=scene['id']; screenshot=OUT/'source/captures'/f'{sid}.png'
 if screenshot.exists():
  shot=Image.open(screenshot).convert('RGB')
  ratio=min(940/shot.width,880/shot.height);shot=shot.resize((int(shot.width*ratio),int(shot.height*ratio)),Image.Resampling.LANCZOS)
  px=(1080-shot.width)//2;py=445+(880-shot.height)//2
  d.rounded_rectangle((px-12,py-12,px+shot.width+12,py+shot.height+12),radius=20,outline='#7860b9',width=3,fill='#20192f')
  im.paste(shot,(px,py))
  d=ImageDraw.Draw(im)
  # Explanatory focus outlines; never alter the real provider controls.
  boxes={
   'openrouter-keys':(869,16,974,58),
   'google-keys':(580,13,727,46),
   'groq-keys':(799,28,959,68),
   'openrouter-create': (24,79,487,121) if 'name' in caption.lower() else (24,179,487,223) if 'expiration' in caption.lower() else (422,519,487,561),
   'google-create': (16,99,480,130) if 'name' in caption.lower() else (16,176,480,208) if 'project' in caption.lower() else (382,223,478,260),
   'groq-create': (25,105,645,146) if 'name' in caption.lower() else (25,232,645,274) if 'expiration' in caption.lower() else (567,332,647,373),
  }
  if sid in boxes:
   x1,y1,x2,y2=boxes[sid]
   d.rounded_rectangle((px+x1*ratio-5,py+y1*ratio-5,px+x2*ratio+5,py+y2*ratio+5),radius=10,outline='#a9efd4',width=4)
  put(d,'Actual website capture • key creation stays private',1350,27,color='#a59bb7')
  if sid=='openrouter-create':put(d,'Free model: openrouter/free',1395,30,color='#a9efd4',bold=True)
 elif sid=='intro':
  for j,(name,url) in enumerate([('OpenRouter','openrouter.ai'),('Google AI Studio','aistudio.google.com'),('GroqCloud','console.groq.com')]):
   y=510+j*220;d.rounded_rectangle((70,y,1010,y+170),radius=28,fill='#282039',outline='#54416f',width=2);put(d,name,y+30,48,bold=True,x=110);put(d,url,y+95,32,color='#a9efd4',x=110)
  put(d,'One key. One provider. Your choice.',1250,40,bold=True)
 elif sid=='connect':
  entries=[('OpenRouter','https://openrouter.ai/api/v1'),('Google AI Studio','https://generativelanguage.googleapis.com/\nv1beta/openai/'),('GroqCloud','https://api.groq.com/openai/v1')]
  y=480
  for name,url in entries:
   y=put(d,name,y,38,color='#a9efd4',bold=True)
   for line in url.split('\n'): y=put(d,line,y+8,31)
   y+=75
  put(d,'Paste your own key → Load models',1150,38,bold=True)
  put(d,'Choose a model → Test connection',1220,38,bold=True)
  put(d,'Configuration checklist • addresses in description',1350,27,color='#a59bb7')
 else:
  for j,(a,b) in enumerate([('Keep keys private','Never put a real key in a video or comment.'),('Check free-tier limits','Availability, rate limits and policies vary.'),('Offline is still an option','Downloaded local models need no cloud key.')]):
   y=510+j*235;put(d,a,y,44,color='#a9efd4',bold=True);put(d,b,y+70,36)
  put(d,'Local narration • cloud language requests optional',1320,30,color='#a59bb7')
 d.rounded_rectangle((50,1455,1030,1740),radius=24,fill='#0a0811',outline='#453257',width=2)
 put(d,caption,1490,43,bold=True,x=85,width=910)
 d.text((70,1790),f'{i+1:02d} / 09',font=font(28,True),fill='#ac9cc3')
 d.text((285,1790),'royFoundry  ×  Firebrat',font=font(30,True),fill='#d5c5f6')
 d.rounded_rectangle((70,1860,1010,1870),radius=5,fill='#32223f');d.rounded_rectangle((70,1860,70+int(940*(i+1)/9),1870),radius=5,fill='#a9efd4')
 return im

def stamp(t):
 ms=round(t*1000);return f'{ms//3600000:02d}:{ms//60000%60:02d}:{ms//1000%60:02d},{ms%1000:03d}'
scenes=json.loads((OUT/'source/script.json').read_text());timeline=[];srt=[];elapsed=0
for i,scene in enumerate(scenes):
 wav=WORK/'audio'/f'{scene["id"]}.wav'
 if not wav.exists():raise SystemExit(f'Missing audio: {wav}')
 duration=max(probe(wav)/.9+.7,6)
 qa=json.loads((WORK/'voice-qa.json').read_text())[scene['id']]
 if qa['source_match'] < .85:raise SystemExit(f"Narration needs review: {scene['id']}")
 spoken=qa['words']
 text=scene['text'].replace('Open Router','OpenRouter').replace('Groq Cloud','GroqCloud').replace('A I','AI')
 tokens=text.split()
 def canonical(w):return re.sub('[^a-z0-9]','',w.lower()).replace('firebrand','firebrat').replace('grok','groq')
 sm=difflib.SequenceMatcher(None,[canonical(w) for w in tokens],[canonical(w['word']) for w in spoken],autojunk=False)
 starts={}
 for block in sm.get_matching_blocks():
  for k in range(block.size):starts[block.a+k]=spoken[block.b+k]['start']/.9
 for k in range(len(tokens)):
  if k in starts:continue
  before=max((n for n in starts if n<k),default=-1);after=min((n for n in starts if n>k),default=len(tokens))
  lo=starts.get(before,0);hi=starts.get(after,duration-.7)
  starts[k]=lo+(hi-lo)*(k-before)/(after-before)
 groups=[(k,tokens[k:k+9]) for k in range(0,len(tokens),9)];parts=[]
 for j,(k,group) in enumerate(groups):
  caption=' '.join(group)
  a=0 if j==0 else starts[k]
  b=duration if j==len(groups)-1 else starts[groups[j+1][0]]
  p=WORK/'frames'/f'{i:02d}-{j:02d}.png';frame(scene,i,caption).save(p)
  parts.append((p,b-a));srt.append((elapsed+a,elapsed+b,caption))
 lst=WORK/'parts'/f'{i:02d}.txt';lst.write_text(''.join(f"file '{p}'\nduration {d:.6f}\n" for p,d in parts)+f"file '{parts[-1][0]}'\n")
 out=WORK/'parts'/f'{i:02d}.mp4'
 subprocess.run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',str(lst),'-i',str(wav),'-t',str(duration),'-vf','fps=30,format=yuv420p','-af','atempo=0.9,apad','-c:v','libx264','-preset','fast','-crf','19','-c:a','aac','-b:a','192k',str(out)],check=True)
 actual=probe(out)
 timeline.append({'id':scene['id'],'start':elapsed,'duration':actual});elapsed+=actual
(WORK/'concat.txt').write_text(''.join(f"file '{WORK/'parts'/f'{i:02d}.mp4'}'\n" for i in range(len(scenes))))
video=OUT/'firebrat-free-llm-keys-real.mp4'
subprocess.run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',str(WORK/'concat.txt'),'-c:v','copy','-af','aformat=channel_layouts=stereo,loudnorm=I=-16:TP=-1.5:LRA=9','-ar','48000','-c:a','aac','-b:a','192k','-movflags','+faststart',str(video)],check=True)
(OUT/'captions.srt').write_text(''.join(f'{k+1}\n{stamp(a)} --> {stamp(b)}\n{text}\n\n' for k,(a,b,text) in enumerate(srt)))
(OUT/'source/timeline.json').write_text(json.dumps({'duration':elapsed,'scenes':timeline},indent=2))
print(video,elapsed)
