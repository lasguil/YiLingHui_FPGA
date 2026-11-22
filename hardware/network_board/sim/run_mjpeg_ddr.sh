#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CCACHE_DIR="${CCACHE_DIR:-tmp/efinity_mjpeg_ccache}"
export CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-tmp/ccache_tmp}"
mkdir -p build
EFINITY_ROOT="${EFINITY_HOME:-${EFINITY_ROOT:-}}"
if [[ -z "$EFINITY_ROOT" && -n "${EFINITY_BIN:-}" ]]; then EFINITY_ROOT="${EFINITY_BIN%/bin}"; fi
EFINITY_ROOT="${EFINITY_ROOT:-/home/grant/efinity/2026.1}"
SRL_MODEL="$EFINITY_ROOT/sim_models/verilog/efx_srl8.v"
[[ -f "$SRL_MODEL" ]] || { echo "Efinity EFX_SRL8 simulation model missing: $SRL_MODEL" >&2; exit 1; }
mkdir -p "$CCACHE_DIR" "$CCACHE_TEMPDIR"
common=("$SRL_MODEL" rtl/demo_bus_pkg.sv rtl/gesture_async_fifo.sv rtl/gesture_sync_fifo.sv rtl/gesture_frame_capture.sv rtl/ddr_rewrite/ddr_slim_fifo.sv)
opts=(--binary --timing --assert -DSIM_ASSERT -Wno-fatal -j 4)
verilator "${opts[@]}" --top-module tb_capture_recovery --Mdir build/ddr_capture_regression \
  "${common[@]}" sim/tb_capture_recovery.sv >build/ddr_capture_regression_compile.log 2>&1
build/ddr_capture_regression/Vtb_capture_recovery >build/ddr_capture_regression_run.log 2>&1
verilator "${opts[@]}" --top-module tb_mjpeg_ddr_source -GSW=1920 -GSH=1080 \
  --Mdir build/ddr_mjpeg_720p_sim "${common[@]}" rtl/mjpeg_ddr_source.sv \
  sim/tb_mjpeg_ddr_source.sv >build/ddr_mjpeg_720p_compile.log 2>&1
build/ddr_mjpeg_720p_sim/Vtb_mjpeg_ddr_source >build/ddr_mjpeg_720p_run.log 2>&1
verilator "${opts[@]}" --top-module tb_mjpeg_ddr_source -GSW=1920 -GSH=1080 -GJPEG=1 -GNETWORK=1 \
  --Mdir build/ddr_mjpeg_network_sim "${common[@]}" rtl/demo_axi_merge.sv rtl/mjpeg_ddr_source.sv \
  rtl/mjpegzero/*.v rtl/network/net_route/vid_packet.v sim/tb_mjpeg_ddr_source.sv \
  >build/ddr_mjpeg_network_compile.log 2>&1
build/ddr_mjpeg_network_sim/Vtb_mjpeg_ddr_source >build/ddr_mjpeg_network_run.log 2>&1
python3 - <<'PY'
from pathlib import Path
from PIL import Image
for i in range(3):
    path=Path(f'build/ddr_mjpeg_frame_{i}.jpg')
    with Image.open(path) as im:
        im.load()
        assert im.size==(1280,720), (path,im.size)
    print(f'PASS: {path}, 1280x720, {path.stat().st_size} bytes')
PY
