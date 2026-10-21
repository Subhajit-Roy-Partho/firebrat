"""Generate original, tiny PDFs for native simulator conversion tests (reportlab)."""
import pathlib, sys
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import letter
root = pathlib.Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
c = canvas.Canvas(str(root/'native-illustrated.pdf'))
c.setFont('Helvetica', 18); c.drawString(40, 770, 'The Lantern Circuit')
c.setFont('Helvetica', 12)
for i, line in enumerate(['A battery supplies three volts to a lamp.', 'The lamp lights when the switch is closed.', 'The diagram below preserves the original circuit layout.']):
    c.drawString(40, 730-i*24, line)
c.rect(80, 400, 300, 180); c.circle(230, 400, 25); c.drawString(205, 355, 'Lamp')
c.drawString(95, 590, '3 V battery'); c.save()
c = canvas.Canvas(str(root/'native-novel.pdf'))
for lines in [['The Lantern', 'Alice smiled as she lifted the lantern.', '"The light is ready," Alice said.', 'Bob nodded as he opened the door.', '"Let us go," Bob replied.'], ['At the Gate', '"Is the path clear?" Alice asked.', '"Yes," Bob answered.', 'They walked through the gate together.']]:
    c.setFont('Helvetica', 12)
    for i, line in enumerate(lines): c.drawString(40, 760-i*24, line)
    c.showPage()
c.save()
# A small original package for import testing, independent of neural speech.
import wave, math, struct, tarfile, io, json, shutil, subprocess
package=root/'import-package'; (package/'sections/sec_0001').mkdir(parents=True, exist_ok=True)
with wave.open(str(package/'sections/sec_0001/audio.wav'),'wb') as w:
    w.setparams((1,2,24000,0,'NONE','not compressed'))
    w.writeframes(bytes(48000 * 2))
(package/'sections/sec_0001/segments.json').write_text(json.dumps({'section_id':'sec_0001','sample_rate':24000,'segments':[{'segment_id':'seg_1','index':0,'type':'prose','text':'Imported package playback fixture.','start_ms':0,'end_ms':2000}]}))
(package/'manifest.json').write_text(json.dumps({'book_id':'native-import','title':'Imported archive fixture','total_duration_ms':2000,'sections':[{'section_id':'sec_0001','title':'Import test','order':1,'audio_path':'sections/sec_0001/audio.wav','segments_path':'sections/sec_0001/segments.json','duration_ms':2000}],'figures':[],'formulas':[],'tables':[]}))
with tarfile.open(root/'native-package.tar.gz','w:gz',format=tarfile.PAX_FORMAT) as t:t.add(package,'package')
if shutil.which('pdftoppm'):
    subprocess.run(['pdftoppm','-scale-to','1800','-png','-singlefile',str(root/'native-illustrated.pdf'),str(root/'scanned')],check=True)
    c=canvas.Canvas(str(root/'native-scanned.pdf')); c.drawImage(str(root/'scanned.png'),0,0,width=595,height=842); c.save()

# Six named characters exercise every neural voice and automatic gender pools.
c=canvas.Canvas(str(root/'native-voices.pdf'),pagesize=letter)
y=740
for name,gender in [('Alice','woman'),('Bella','woman'),('Clara','woman'),('Diana','woman'),('Evan','man'),('Felix','man')]:
    c.drawString(50,y,f'{name} was a {gender}.');y-=22
    c.drawString(50,y,f'"The light is ready," {name} said.');y-=36
c.save()
