"""Validate the actual project-relative HDMI EDID dependency and timing contract."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
receiver = root / 'rtl/vendor_hdmi/source/hdmi_src/dvi_rx/EDID/hdmi_rx.v'
name, = re.findall(r'\.RAM_INIT_FILE\("([^"]+)"\)', receiver.read_text())
data = bytes(int(x, 16) for x in (root / name).read_text().split())
assert len(data) == 128 and data[:8] == bytes.fromhex('00 ff ff ff ff ff ff 00')
assert sum(data) % 256 == 0 and data[126] == 0
assert data[35:38] == bytes(3) and data[38:54] == bytes.fromhex('01 01') * 8
refresh_rates = []
for offset in (54, 72):
    d = data[offset:offset+18]
    clock = int.from_bytes(d[:2], 'little') * 10_000
    width = d[2] | (d[4] & 0xf0) << 4
    hblank = d[3] | (d[4] & 0x0f) << 8
    height = d[5] | (d[7] & 0xf0) << 4
    vblank = d[6] | (d[7] & 0x0f) << 8
    assert (width, height, hblank, vblank) == (1920, 1080, 280, 45)
    assert d[17] == 0x1e  # Progressive, digital separate +H/+V sync.
    refresh_rates.append(clock / ((width+hblank)*(height+vblank)))
assert refresh_rates == [60.0, 30.0]
assert data[90:95] == bytes.fromhex('00 00 00 fc 00')
assert data[108:113] == bytes.fromhex('00 00 00 10 00')
print('PASS: initialized EDID; only 1920x1080p60/p30; checksum and relative path valid')
