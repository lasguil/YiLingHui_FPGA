from __future__ import annotations
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"
ARTIFACTS = ROOT / "artifacts"
BIN = BUILD / "product_ui_24k.bin"
IMAGE_BYTES = 24 * 1024
WORDS = IMAGE_BYTES // 4

raw = BIN.read_bytes()
if len(raw) > IMAGE_BYTES:
    raise SystemExit(f"BIN too large: {len(raw)} > {IMAGE_BYTES}")
image = raw.ljust(IMAGE_BYTES, b"\0")
ARTIFACTS.mkdir(parents=True, exist_ok=True)
(ARTIFACTS / "product_ui_24k_ocr_padded.bin").write_bytes(image)

lanes: list[bytes] = []
for lane in range(4):
    data = image[lane::4]
    if len(data) != WORDS:
        raise SystemExit(f"bad lane length: {lane} {len(data)}")
    lanes.append(data)
    path = ARTIFACTS / f"EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{lane}.bin"
    path.write_bytes(("\r\n".join(f"{byte:08b}" for byte in data) + "\r\n").encode("ascii"))

parsed: list[bytes] = []
for lane in range(4):
    path = ARTIFACTS / f"EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{lane}.bin"
    rows = path.read_text(encoding="ascii").splitlines()
    if len(rows) != WORDS or any(len(row) != 8 or set(row) - {"0", "1"} for row in rows):
        raise SystemExit(f"invalid $readmemb lane {lane}")
    parsed.append(bytes(int(row, 2) for row in rows))
reconstructed = bytes(parsed[lane][word] for word in range(WORDS) for lane in range(4))
if reconstructed != image:
    raise SystemExit("4-lane readmemb interleave does not reconstruct padded BIN")
