"""Exercise the PC HDMI source's two modes against the FPGA receiver.

Only the explicitly named secondary output is changed; it is restored in a
finally block. Requires the board's local streamd service to already be running.
"""
from pathlib import Path
import argparse,hashlib,io,json,subprocess,time,urllib.request,signal
from PIL import Image
ap=argparse.ArgumentParser()
ap.add_argument('--output',required=True,help='HDMI output confirmed by xrandr --query')
ap.add_argument('--url',default='http://127.0.0.1:8080')
ap.add_argument('--seconds',type=int,default=20)
ap.add_argument('--tag',default='adaptive_hdmi_20261022')
a=ap.parse_args()
root=Path(__file__).resolve().parents[1];out=root/'build/hardware'/a.tag;out.mkdir(parents=True,exist_ok=False)
query=subprocess.check_output(['xrandr','--query'],text=True)
(out/'xrandr_before.txt').write_text(query)
lines=query.splitlines();matching=[i for i,l in enumerate(lines) if l.startswith(a.output+' connected ')]
if len(matching)!=1:raise RuntimeError('Named connected HDMI output not found')
head=lines[matching[0]]
if ' primary ' in head:raise RuntimeError('Refusing to change the primary display')
original_mode=None;original_rate=None
for line in lines[matching[0]+1:]:
 if line and not line[0].isspace():break
 if '*' in line:
  fields=line.split();original_mode=fields[0];original_rate=next(x for x in fields[1:] if '*' in x).strip('*+')
if original_mode is None:raise RuntimeError('Could not determine original mode')
def get(path):return json.load(urllib.request.urlopen(a.url+path,timeout=10))
def sample():
 s=get('/api/status');r=get('/api/regs')['regs']
 return {'time':time.monotonic(),'status':s,'regs':{k:v['value'] for k,v in r.items()}}
def save_jpeg(label):
 data=urllib.request.urlopen(a.url+'/snapshot.jpg',timeout=5).read()
 with Image.open(io.BytesIO(data)) as im:im.load();size=list(im.size)
 p=out/(label+'.jpg');p.write_bytes(data)
 if size!=[1280,720]:raise RuntimeError(f'Bad JPEG size {size}')
 return dict(file=p.name,size=size,bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
results=[]
def interrupted(signum, frame):
 raise SystemExit(128+signum)
signal.signal(signal.SIGTERM,interrupted)
try:
 for n,(w,h) in enumerate([(1920,1080),(1280,720),(1920,1080),(1280,720)]):
  before=get('/api/status');start=time.monotonic()
  subprocess.run(['xrandr','--output',a.output,'--mode',f'{w}x{h}','--rate','60'],check=True,capture_output=True,text=True)
  deadline=time.monotonic()+20
  while True:
   s=get('/api/status');hd=s.get('hd',{})
   if hd.get('valid') and [hd.get('src_w'),hd.get('src_h')]==[w,h] and s['frames_ok']>before['frames_ok']+5:
    break
   if time.monotonic()>deadline:raise RuntimeError(f'Input {w}x{h} did not recover: {s}')
   time.sleep(.25)
  recovered=time.monotonic()-start
  time.sleep(2)
  first=sample();records=[first]
  for _ in range(a.seconds):
   time.sleep(1);records.append(sample())
  last=records[-1];elapsed=last['time']-first['time'];s0=first['status'];s1=last['status']
  delta={k:s1[k]-s0[k] for k in ('frames_ok','frames_partial','frames_lost','bad')}
  capture=(last['regs']['003C']-first['regs']['003C'])%(1<<32)
  tx=(last['regs']['0028']-first['regs']['0028'])%(1<<32)
  result=dict(input=[w,h],recovered_s=recovered,elapsed_s=elapsed,complete_fps=delta['frames_ok']/elapsed,capture_fps=capture/elapsed,delta=delta,tx_err_delta=tx,
      snapshot=save_jpeg(f'{n}_{w}x{h}'),input_stayed_valid=all(x['status'].get('hd',{}).get('valid') and [x['status']['hd'].get('src_w'),x['status']['hd'].get('src_h')]==[w,h] for x in records),
      stream_continued=s1['frames_ok']>s0['frames_ok'],width=s1['w'],height=s1['h'])
  results.append(result)
  (out/f'{n}_{w}x{h}_samples.json').write_text(json.dumps(records,indent=2))
  (out/'summary.json').write_text(json.dumps(results,indent=2))
  print(json.dumps(result),flush=True)
finally:
 subprocess.run(['xrandr','--output',a.output,'--mode',original_mode,'--rate',original_rate],check=True,capture_output=True,text=True)
 (out/'xrandr_after.txt').write_text(subprocess.check_output(['xrandr','--query'],text=True))
assert len(results)==4 and all(r['input_stayed_valid'] and r['stream_continued'] and [r['width'],r['height']]==[1280,720] for r in results),results
print('PASS: input geometry adaptation and output continuity in both directions; see counters for frame losses',flush=True)
