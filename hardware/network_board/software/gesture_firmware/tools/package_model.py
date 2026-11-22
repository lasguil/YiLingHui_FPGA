from __future__ import annotations

import json
import zlib
from pathlib import Path

FW = Path(__file__).resolve().parents[1]
OUT = FW / "model"

weight_data = (OUT / "weights_hw.bin").read_bytes()
param_data = (OUT / "param_hw.bin").read_bytes()
if len(weight_data) != 1_099_552 or len(param_data) != 112_384:
    raise SystemExit(f"unexpected model image sizes: weights={len(weight_data)} params={len(param_data)}")
OUT.mkdir(parents=True, exist_ok=True)
wc, pc = zlib.crc32(weight_data), zlib.crc32(param_data)
(FW / "include" / "model_crc.h").write_text(
    "#ifndef MODEL_CRC_H\n#define MODEL_CRC_H\n"
    f"#define MODEL_WEIGHTS_BYTES {len(weight_data)}u\n"
    f"#define MODEL_PARAMS_BYTES {len(param_data)}u\n"
    f"#define MODEL_WEIGHTS_CRC32 0x{wc:08x}u\n"
    f"#define MODEL_PARAMS_CRC32 0x{pc:08x}u\n"
    "#endif\n", encoding="ascii")
(OUT / "manifest.json").write_text(json.dumps({
    "weights_file": "weights_hw.bin", "weights_address": "0x02000000",
    "weights_bytes": len(weight_data), "weights_crc32": f"0x{wc:08x}",
    "params_file": "param_hw.bin", "params_address": "0x0210d000",
    "params_bytes": len(param_data), "params_crc32": f"0x{pc:08x}",
    "input_address": "0x02129000", "input_layout": "224x224x32 C32; RGB channels 0..2",
    "tensor_arena_address": "0x022b1000", "scores_address": "0x02439000",
}, indent=2) + "\n", encoding="utf-8")
print(f"weights {len(weight_data)} B crc32={wc:08x}; params {len(param_data)} B crc32={pc:08x}")
