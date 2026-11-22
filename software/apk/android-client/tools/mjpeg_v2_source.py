#!/usr/bin/env python3
"""Paced VI v2 replay; development only. Standard Python library, no transcoding."""
import argparse, hashlib, json, math, random, socket, struct, time
from pathlib import Path
HEADER=struct.Struct('>HBBIHHII')

def fragments(jpeg, frame_id, timestamp):
    count=math.ceil(len(jpeg)/1452)
    return [HEADER.pack(0x5649,2,(1 if i==0 else 0)|(2 if i==count-1 else 0),frame_id,i,0xffff,i*1452,timestamp)+jpeg[i*1452:(i+1)*1452] for i in range(count)]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--host',default='127.0.0.1'); p.add_argument('--port',type=int,default=5001)
    p.add_argument('--jpeg',type=Path); p.add_argument('--fps',type=float,default=30)
    p.add_argument('--seconds',type=float,default=60); p.add_argument('--mbps',type=float,help='repeat source at this UDP user-data load; overrides fps')
    p.add_argument('--loss',type=float,default=0); p.add_argument('--duplicate',type=float,default=0)
    p.add_argument('--reorder',type=float,default=0); p.add_argument('--drop-frame',type=float,default=0)
    p.add_argument('--eof-first',action='store_true'); p.add_argument('--seed',type=int,default=42)
    p.add_argument('--report',type=Path,default=Path('source-report.json')); a=p.parse_args()
    if not (a.fps>0 and a.seconds>0 and 1<=a.port<=65535 and all(0<=x<=1 for x in (a.loss,a.duplicate,a.reorder,a.drop_frame)) and (a.mbps is None or a.mbps>0)): p.error('invalid range')
    if a.jpeg: jpeg=a.jpeg.read_bytes()
    else:
        base=Path(__file__).resolve().parent.parent/'fixtures/mjpeg_v2_frame_1'
        jpeg=b''.join(x.read_bytes()[20:] for x in sorted(base.glob('*.udp')))
    if not (jpeg.startswith(b'\xff\xd8') and jpeg.endswith(b'\xff\xd9')): p.error('not a JPEG')
    if len(jpeg)>4*1024*1024: p.error('JPEG exceeds 4 MiB')
    load=len(jpeg)+20*math.ceil(len(jpeg)/1452)
    fps=a.mbps*1e6/8/load if a.mbps else a.fps
    rng=random.Random(a.seed); counts=dict(source_frames=0,whole_frames_dropped=0,packets_sent=0,packets_dropped=0,duplicates_sent=0,bytes_sent=0,send_errors=0,expected_complete_frames=0)
    start=time.monotonic(); frame_id=0
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        while time.monotonic()-start<a.seconds:
            packets=fragments(jpeg,frame_id,int(time.monotonic()*1e6)&0xffffffff)
            counts['source_frames']+=1
            complete=True
            if rng.random()<a.drop_frame: packets=[]; counts['whole_frames_dropped']+=1; complete=False
            else:
                if a.eof_first: packets=packets[-1:]+packets[:-1]
                for i in range(len(packets)-1):
                    if rng.random()<a.reorder: packets[i],packets[i+1]=packets[i+1],packets[i]
            for i,packet in enumerate(packets):
                deadline=start+(counts['source_frames']-1+i/max(len(packets),1))/fps
                delay=deadline-time.monotonic()
                if delay>0: time.sleep(delay)
                if rng.random()<a.loss: counts['packets_dropped']+=1; complete=False; continue
                copies=2 if rng.random()<a.duplicate else 1
                for copy in range(copies):
                    try: sent=s.sendto(packet,(a.host,a.port))
                    except OSError: counts['send_errors']+=1; complete=False; continue
                    counts['packets_sent']+=1; counts['bytes_sent']+=sent
                    if copy: counts['duplicates_sent']+=1
            if complete: counts['expected_complete_frames']+=1
            frame_id=(frame_id+1)&0xffffffff
            delay=start+counts['source_frames']/fps-time.monotonic()
            if delay>0: time.sleep(delay)
    elapsed=time.monotonic()-start
    report=dict(**counts,elapsed_s=elapsed,source_fps=counts['source_frames']/elapsed,udp_mbps=counts['bytes_sent']*8/elapsed/1e6,target_fps=fps,jpeg_sha256=hashlib.sha256(jpeg).hexdigest(),seed=a.seed,options={k:str(v) if isinstance(v,Path) else v for k,v in vars(a).items()})
    a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n'); print(json.dumps(report,ensure_ascii=False,indent=2))
if __name__=='__main__': main()
