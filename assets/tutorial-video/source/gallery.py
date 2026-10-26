import sys; sys.path.insert(0,'.')
from lib import *
out=R+'/build/out/play-listing-1.7.2'; os.makedirs(out,exist_ok=True)
items=[
 ('01-listen-while-it-converts','listen.mp4',8.0,'Listen while it converts','Open a book that is still converting and play what is ready.',False),
 ('02-carries-on-by-itself','listen.mp4',20.0,'It carries on by itself','At the last ready section, playback waits and continues when the next one finishes.',False),
 ('03-pause-and-resume','pause.mp4',12.8,'Pause and resume','Progress is saved, so a long book can be paused and picked up later.',False),
 ('04-cast-and-voices','cast.mp4',9.0,'Know who is speaking','Cast & voices lists every speaker, their traits and their voice.',False),
 ('05-every-book-a-cover','library.mp4',2.0,'Every book gets a cover','Real ebook covers, or a generated one.',False),
 ('06-free-cloud-llm','llm_b.mp4',20.0,'A free cloud LLM in minutes','Paste a free OpenRouter key, load models, test, go.',True),
]
for name,clipf,t,head,sub,patchkey in items:
    fr=f'{B}/png/g_{name}.png'
    run(f'ffmpeg -v error -y -i {R}/raw/{clipf} -vf "fps=30,select=gte(t\\,{t})" -frames:v 1 "{fr}"')
    im=Image.open(fr).convert('RGBA')
    if patchkey:
        im.alpha_composite(Image.open(key_patch()))
    im=im.convert('RGB').crop((0,118,1080,2424))
    ph=int(1500); pw=int(im.width*ph/im.height)
    im=im.resize((pw,ph),Image.LANCZOS)
    cv=gradient(1080,1920).convert('RGBA'); d=ImageDraw.Draw(cv)
    f=font(HEAVY,74); y=90
    for l in wrap(d,head,f,940):
        d.text((70,y),l,font=f,fill=(255,255,255,255)); y+=88
    f2=font(REG,38)
    for l in wrap(d,sub,f2,940):
        d.text((70,y+6),l,font=f2,fill=MUTED+(255,)); y+=50
    x=(1080-pw)//2; yy=1920-ph-70
    m=Image.new('L',im.size,0); ImageDraw.Draw(m).rounded_rectangle((0,0)+im.size,40,fill=255)
    d.rounded_rectangle((x-9,yy-9,x+pw+9,yy+ph+9),48,outline=(88,80,150,255),width=9)
    cv.paste(im.convert('RGBA'),(x,yy),m)
    cv.convert('RGB').save(f'{out}/{name}.jpg',quality=92)
print(sorted(os.listdir(out)))
