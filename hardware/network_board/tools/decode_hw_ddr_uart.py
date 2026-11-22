"""Decode the independent DDR diagnostic UART; no CPU/JTAG dependency."""
import json
import re
import sys
from pathlib import Path

FLAGS = ["board_reset_released", "cpu_pll", "ddr_pll", "video_pll", "proc_pll",
         "global_reset_released", "ddr_reset_released", "cal_done", "cal_reset_active",
         "core_heartbeat", "proc_heartbeat", "video_reset_released", "proc_reset_released",
         "camera_config_done", "sensor_ae_fault", "cpu_gpio"]

def decode(word):
    return dict(flags={name: bool(word & (1 << (48 + bit))) for bit, name in enumerate(FLAGS)},
                init_state=(word >> 40) & 127, idelay_ld=bool(word & (1 << 47)),
                rd_level_check=(word >> 32) & 255, wr_level_check=(word >> 24) & 255,
                retry=(word >> 20) & 7, timeout_progress=(word & 0xfffff))

if __name__ == "__main__":
    data = Path(sys.argv[1]).read_text(encoding="utf-8-sig")
    rows = re.findall(r"DDR ([0-9A-Fa-f]{16})", data)
    if not rows:
        raise SystemExit("No complete hardware DDR UART records; no status conclusion is valid")
    for row in rows:
        print(json.dumps(decode(int(row, 16)), ensure_ascii=False))
