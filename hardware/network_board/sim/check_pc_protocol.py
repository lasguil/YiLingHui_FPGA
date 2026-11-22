"""Decode RTL-emitted VI packets with the unchanged production PC protocol."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root.parent / 'net_web'))
import netproto

packets = [bytes.fromhex(line) for line in (root / 'build/net_packet_payloads.hex').read_text().splitlines()]
assert len(packets) == 5
frame = bytearray(70)
for index, packet in enumerate(packets):
    fid, idx, total, offset, timestamp, flags, pixels = netproto.unpack_video(packet)
    assert fid == 0 and idx == index and total == 5 and offset == index * 16
    assert flags == ((netproto.FLAG_SOF if index == 0 else 0) | (netproto.FLAG_EOF if index == 4 else 0))
    frame[offset:offset + len(pixels)] = pixels
assert bytes(frame) == b''.join((0xA500 + i).to_bytes(2, 'little') for i in range(35))
print('PASS: unchanged net_web/netproto.py decodes and reconstructs the RTL RGB565 frame')
