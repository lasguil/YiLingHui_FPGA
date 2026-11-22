"""Independent on-wire frame/FCS/IP/VI validation, using the production decoder."""
from pathlib import Path
import argparse,binascii,json,struct,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'net_web'))
import netproto as P
ap=argparse.ArgumentParser();ap.add_argument('--trace',default='build/tx_pipeline_frames.hex');ap.add_argument('--w',type=int,default=320);ap.add_argument('--h',type=int,default=180);ap.add_argument('--frames',type=int,default=100);ap.add_argument('--out',default='build/tx_pipeline_summary.json');a=ap.parse_args()
def ones_sum(d):
 if len(d)%2:d+=b'\0'
 s=sum(struct.unpack('!%dH'%(len(d)//2),d))
 while s>>16:s=(s&65535)+(s>>16)
 return s
frames={};starts={};controls=arps=icmps=0;source_ports=set();previous_end=None;min_gap=10**9
first_cycle=None;wire_bytes=gap_cycles=0
for line in Path(a.trace).open():
 cycle,n,h=line.split();cycle=int(cycle);n=int(n);d=bytes.fromhex(h)
 if first_cycle is None:first_cycle=cycle
 wire_bytes+=n
 assert len(d)==n and d[:8]==bytes.fromhex('55555555555555d5'), 'preamble/SFD'
 if previous_end is not None:
  gap=cycle-previous_end;gap_cycles+=gap;min_gap=min(gap,min_gap);assert gap>=24,('IFG',gap)
 previous_end=cycle+n*2
 eth=d[8:];assert len(eth)>=64,'undersize Ethernet frame'
 assert int.from_bytes(eth[-4:],'little')==binascii.crc32(eth[:-4]),'FCS'
 assert eth[6:12]==bytes.fromhex('000a3501fec0'),'source MAC'
 if eth[12:14]==b'\x08\x06':arps+=1;continue
 assert eth[12:14]==b'\x08\x00','EtherType'
 ip=eth[14:-4];assert ip[0]==0x45 and ones_sum(ip[:20])==0xffff,'IPv4 header'
 ilen=int.from_bytes(ip[2:4],'big');assert ilen<=1500 and ilen<=len(ip),'IP length'
 assert ip[12:20]==bytes.fromhex('c0a80002c0a80003'),'IPv4 address'
 if ip[9]==1:
  body=ip[20:ilen]
  assert len(body)==64 and body[:2]==b'\x00\x00' and ones_sum(body)==0xffff,'ICMP echo reply/checksum'
  assert body[4:8]==bytes.fromhex('12340001') and body[8:]==bytes(range(56)),'ICMP payload'
  icmps+=1;continue
 assert ip[9]==17,'IPv4 protocol'
 u=ip[20:ilen];sport,port,length,csum=struct.unpack('!HHHH',u[:8]);assert length==len(u),'UDP length'
 # udp_tx intentionally emits checksum 0 for IPv4 UDP; nonzero checksums must validate.
 if csum:assert ones_sum(ip[12:20]+b'\x00\x11'+length.to_bytes(2,'big')+u)==0xffff,'UDP checksum'
 payload=u[8:]
 if port==5000:
  assert sport==5000,('control source port',sport)
  source_ports.add(sport)
  assert payload==bytes(range(12)),('control payload',payload.hex());controls+=1;continue
 assert port==5001,('wrong destination port',port)
 assert sport==8080,('video source port',sport)
 source_ports.add(sport)
 v=P.unpack_video(payload);assert v is not None,'VI decode'
 fid,idx,total,off,ts,flags,px=v
 expected_total=(a.w*a.h*2+1451)//1452
 assert total==expected_total and idx<total and off==idx*1452,'VI geometry'
 assert flags==((1 if idx==0 else 0)|(2 if idx==total-1 else 0)),'VI flags'
 assert len(px)==min(1452,a.w*a.h*2-off),'VI payload size'
 f=frames.setdefault(fid,{})
 assert idx not in f,'duplicate packet'
 f[idx]=bytes(px)
 starts.setdefault(fid,cycle)
 # RGB565 source pattern varies by both frame and absolute pixel index.
 expected=b''.join(((0xa500+fid*113+off//2+i)&65535).to_bytes(2,'little') for i in range(len(px)//2))
 assert bytes(px)==expected,('pixel mismatch',fid,idx)
assert set(frames)==set(range(a.frames)),('frame IDs',len(frames),sorted(frames)[-3:])
for fid,f in frames.items():
 assert len(f)==expected_total,('incomplete frame',fid,len(f))
assert controls>0 and arps>0 and icmps>0,'competition was not exercised'
assert source_ports=={5000,8080},('source port selection',sorted(source_ports))
fps=(a.frames-1)*25e6/(starts[a.frames-1]-starts[0])
elapsed_cycles=previous_end-first_cycle
result=dict(status='PASS',w=a.w,h=a.h,frames=len(frames),video_packets=sum(map(len,frames.values())),
            control_packets=controls,control_source_port=5000,video_source_port=8080,udp_checksum='zero_disabled',arp_frames=arps,icmp_frames=icmps,min_ifg_cycles=min_gap,
            wire_video_fps=fps,video_payload_mbps=a.w*a.h*2*8*fps/1e6,
            ethernet_frame_mbps=wire_bytes*8*25/elapsed_cycles)
print(json.dumps(result,indent=2));Path(a.out).write_text(json.dumps(result,indent=2)+'\n')
