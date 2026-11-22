"""Measure a candidate's receiver/JPEG/DDR counters without treating fps_rx as complete fps."""
from pathlib import Path
import argparse,hashlib,json,socket,time,urllib.request,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'net_web'))
import netproto as P
ap=argparse.ArgumentParser();ap.add_argument('--url',default='http://127.0.0.1:8081');ap.add_argument('--seconds',type=int,default=60);ap.add_argument('--tag',default='perf_20261021');ap.add_argument('--warmup',type=int,default=10)
ap.add_argument('--width',type=int,default=320);ap.add_argument('--height',type=int,default=180);ap.add_argument('--min-fps',type=float,default=59.4)
ap.add_argument('--snapshots-every',type=int,default=0);a=ap.parse_args()
r=Path(__file__).resolve().parents[1];out=r/'build/hardware';out.mkdir(parents=True,exist_ok=True)
def sample():
 s=json.load(urllib.request.urlopen(a.url+'/api/status',timeout=3))
 # The RTL replies to fixed UDP port 5000, so use streamd's paired control
 # client rather than an ephemeral UDP socket that can never receive its ACK.
 values=json.load(urllib.request.urlopen(a.url+'/api/regs',timeout=10))['regs']
 regs={f'{addr:04X}':values[f'{addr:04X}']['value'] for addr in (0x0004,0x0008,0x0020,0x0024,0x0028,0x0038,0x003c,0x0040)}
 if any(v is None for v in regs.values()):raise RuntimeError('missing control register readback')
 return dict(status=s,regs=regs)
def udp_errors():
 lines=Path('/proc/net/snmp').read_text().splitlines()
 for h,v in zip(lines,lines[1:]):
  if h.startswith('Udp:') and v.startswith('Udp:'):return dict(zip(h.split()[1:],map(int,v.split()[1:])) )
 return {}
time.sleep(a.warmup)
start=time.monotonic();before=sample();kernel_before=udp_errors();records=[dict(elapsed_s=0,**before)];snapshots=[]
with (out/f'{a.tag}_acceptance.jsonl').open('w') as f:
 f.write(json.dumps(records[-1])+'\n');f.flush()
 for i in range(1,a.seconds+1):
  delay=start+i-time.monotonic()
  if delay>0:time.sleep(delay)
  current=sample();entry=dict(elapsed_s=time.monotonic()-start,**current);records.append(entry)
  f.write(json.dumps(entry)+'\n');f.flush()
  if a.snapshots_every and i%a.snapshots_every==0:
   import io
   from PIL import Image
   data=urllib.request.urlopen(a.url+'/snapshot.jpg',timeout=3).read()
   with Image.open(io.BytesIO(data)) as im:
    im.load();size=list(im.size)
   path=out/f'{a.tag}_{i:03d}s.jpg';path.write_bytes(data)
   snapshots.append(dict(path=str(path),size=size,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
  if i%30==0:print(f"{a.tag}: {i}s fps={current['status']['fps_rx']} complete={current['status']['frames_ok']}",flush=True)
elapsed=records[-1]['elapsed_s'];after=current
s0=before['status'];s1=after['status'];d={k:s1[k]-s0[k] for k in ('pkts','bad','frames_ok','frames_partial','frames_lost','jpeg_version')}
pub=(after['regs']['003C']-before['regs']['003C'])%(1<<32)
net=(after['regs']['0020']-before['regs']['0020'])%(1<<32)
tx=(after['regs']['0028']-before['regs']['0028'])%(1<<32)
result=dict(bitstream_sha256=hashlib.sha256((r/'outflow/ti60f225_oob.bit').read_bytes()).hexdigest(),seconds=elapsed,mode=[s1['w'],s1['h']],delta=d,complete_fps=d['frames_ok']/elapsed,jpeg_fps=d['jpeg_version']/elapsed,capture_published_delta=pub,capture_fps=pub/elapsed,fpga_frames_delta=net,fpga_fps=net/elapsed,tx_err_delta=tx,udp_mbps_min=min(x['status']['mbps'] for x in records[1:]),udp_mbps_max=max(x['status']['mbps'] for x in records[1:]),board_status_start=before['regs']['0040'],board_status_end=after['regs']['0040'],kernel_udp_before=kernel_before,kernel_udp_after=udp_errors(),clients=s1['clients'])
result['snapshots']=snapshots
result['udp_mbps_mean']=sum(x['status']['mbps'] for x in records[1:])/len(records[1:])
result['pass']=result['mode']==[a.width,a.height] and result['complete_fps']>=a.min_fps and result['capture_fps']>=a.min_fps and result['jpeg_fps']>=a.min_fps and all(d[k]==0 for k in ('bad','frames_partial','frames_lost')) and tx==0 and all(x['size']==[a.width,a.height] for x in snapshots)
(out/f'{a.tag}_acceptance_summary.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
