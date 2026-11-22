#!/usr/bin/env python3
"""Development-only control READ responder for emulator (board IP 10.0.2.2). No writes."""
import argparse, socket, struct, time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--seconds',type=float,default=15);a=p.parse_args()
h=struct.Struct('>HBBHHI');end=time.monotonic()+a.seconds
with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
 s.bind(('127.0.0.1',5000));s.settimeout(.2)
 while time.monotonic()<end:
  try: raw,source=s.recvfrom(2048)
  except socket.timeout: continue
  if len(raw)!=12: continue
  magic,version,op,seq,reg,value=h.unpack(raw)
  if (magic,version,op)!=(0x4354,1,0): continue
  # Event with matching seq/reg must not be mistaken for ACK.
  s.sendto(h.pack(magic,version,5,seq,reg,0xdeadbeef),source)
  s.sendto(h.pack(magic,version,2,seq,reg,0x4e423031 if reg==0 else 0),source)
