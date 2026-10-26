import os,json,sys,time
os.environ['HF_HOME']=os.path.expanduser('~/.cache/huggingface')
os.environ['HF_HUB_OFFLINE']='1'
sys.path.insert(0,os.path.expanduser('~/Github/firebrat/backend'))
import torch
torch.set_num_threads(2)
from firebrat.pipeline.tts import FirebratTTS
root='/tmp/firebrat-key-tutorial-20261026'
os.makedirs(root+'/audio',exist_ok=True)
tts=FirebratTTS(device='cpu',voice_ref=os.path.expanduser('~/Github/firebrat/backend/voice/narrator_ref.wav'),exaggeration=.32,cfg_weight=.45)
worker=int(sys.argv[1]); count=int(sys.argv[2])
for index,scene in enumerate(json.load(open(root+'/script.json'))):
 if index % count != worker: continue
 p=root+'/audio/'+scene['id']+'.wav'
 if os.path.exists(p):continue
 print('START',scene['id'],flush=True)
 if not tts.synthesize(scene['text'],p):raise RuntimeError(scene['id'])
 print('DONE',scene['id'],flush=True)
print('ALL_DONE',flush=True)
