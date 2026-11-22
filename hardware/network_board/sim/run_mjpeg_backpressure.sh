#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CCACHE_DIR="${CCACHE_DIR:-tmp/efinity_mjpeg_ccache}"
export CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-tmp/ccache_tmp}"
EFINITY_ROOT="${EFINITY_HOME:-${EFINITY_ROOT:-}}"
if [[ -z "$EFINITY_ROOT" && -n "${EFINITY_BIN:-}" ]]; then EFINITY_ROOT="${EFINITY_BIN%/bin}"; fi
EFINITY_ROOT="${EFINITY_ROOT:-/home/grant/efinity/2026.1}"
SRL_MODEL="$EFINITY_ROOT/sim_models/verilog/efx_srl8.v"
[[ -f "$SRL_MODEL" ]] || { echo "Efinity EFX_SRL8 simulation model missing: $SRL_MODEL" >&2; exit 1; }
mkdir -p "$CCACHE_DIR" "$CCACHE_TEMPDIR"
if [[ $# -gt 0 ]]; then
python3 - "$1" <<'PY'
import sys
from pathlib import Path
from PIL import Image
image=Image.open(sys.argv[1]).convert('RGB').resize((1920,1080))
Path('build').mkdir(exist_ok=True)
with Path('build/mjpeg_desktop_rgb.hex').open('w') as f:
    for r,g,b in image.getdata():
        f.write(f'{r:02x}{g:02x}{b:02x}\n')
PY
fi
[[ -f build/mjpeg_desktop_rgb.hex ]] || { echo 'Supply a desktop/reference image as the first argument.' >&2; exit 1; }
common=("$SRL_MODEL" rtl/demo_bus_pkg.sv rtl/gesture_async_fifo.sv rtl/gesture_sync_fifo.sv
  rtl/gesture_frame_capture.sv rtl/demo_axi_merge.sv rtl/ddr_rewrite/ddr_slim_fifo.sv rtl/mjpeg_ddr_source.sv
  rtl/mjpegzero/*.v rtl/network/net_route/vid_packet.v sim/tb_mjpeg_ddr_source.sv)
opts=(--binary --timing --assert -DSIM_ASSERT -Wno-fatal -j 4
  --top-module tb_mjpeg_ddr_source -GSW=1920 -GSH=1080 -GJPEG=1 -GNETWORK=1
  -GIMAGE=1 -GFRAME_TARGET=3 -GMAC_STALL_CYCLES=40000)
# A 1.6 ms MAC wait produces more than 4 KiB of JPEG backlog. 8 KiB must
# deliver all frames; a deliberately smaller FIFO must drop once and recover.
verilator "${opts[@]}" --Mdir build/ddr_mjpeg_fifo_margin_sim "${common[@]}" \
  >build/ddr_mjpeg_fifo_margin_compile.log 2>&1
build/ddr_mjpeg_fifo_margin_sim/Vtb_mjpeg_ddr_source +JPEG_PREFIX=build/margin_frame \
  >build/ddr_mjpeg_fifo_margin_run.log 2>&1
verilator "${opts[@]}" -GJPEG_FIFO_AW=12 -GALLOW_DROPS=1 \
  --Mdir build/ddr_mjpeg_overflow_recovery_fixed_sim "${common[@]}" \
  >build/ddr_mjpeg_overflow_recovery_fixed_compile.log 2>&1
build/ddr_mjpeg_overflow_recovery_fixed_sim/Vtb_mjpeg_ddr_source +JPEG_PREFIX=build/recovery_frame \
  >build/ddr_mjpeg_overflow_recovery_fixed_run.log 2>&1
cat build/ddr_mjpeg_fifo_margin_run.log build/ddr_mjpeg_overflow_recovery_fixed_run.log
