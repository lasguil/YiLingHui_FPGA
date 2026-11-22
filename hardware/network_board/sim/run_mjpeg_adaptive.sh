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
common=("$SRL_MODEL" rtl/demo_bus_pkg.sv rtl/gesture_async_fifo.sv rtl/gesture_sync_fifo.sv rtl/gesture_frame_capture.sv rtl/ddr_rewrite/ddr_slim_fifo.sv rtl/mjpeg_ddr_source.sv)
opts=(--binary --timing --assert -DSIM_ASSERT -Wno-fatal -j 4)
for spec in small npu full npu_full; do
  args=()
  [[ "$spec" == *full* ]] && args+=(-GSW=1920 -GSH=1080)
  [[ "$spec" == npu* ]] && args+=(-GNPU_ONLY=1)
  verilator "${opts[@]}" --top-module tb_mjpeg_adaptive "${args[@]}" \
    --Mdir "build/adaptive_capture_${spec}_sim" "${common[@]}" sim/tb_mjpeg_adaptive.sv \
    >"build/adaptive_capture_${spec}_compile.log" 2>&1
  "build/adaptive_capture_${spec}_sim/Vtb_mjpeg_adaptive" >"build/adaptive_capture_${spec}_run.log" 2>&1
  cat "build/adaptive_capture_${spec}_run.log"
done
[[ -f build/mjpeg_desktop_rgb.hex ]] || { echo 'Generate build/mjpeg_desktop_rgb.hex from a 1920x1080 RGB reference first.' >&2; exit 1; }
verilator "${opts[@]}" --top-module tb_mjpeg_ddr_source -GSW=1920 -GSH=1080 \
  -GJPEG=1 -GNETWORK=1 -GAUTO_INPUT=1 -GINPUT_720P=1 -GIMAGE=1 \
  --Mdir build/adaptive_native720_network_sim "${common[@]}" rtl/demo_axi_merge.sv \
  rtl/mjpegzero/*.v rtl/network/net_route/vid_packet.v sim/tb_mjpeg_ddr_source.sv \
  >build/adaptive_native720_network_compile.log 2>&1
build/adaptive_native720_network_sim/Vtb_mjpeg_ddr_source +JPEG_PREFIX=build/adaptive_native720_frame \
  >build/adaptive_native720_network_run.log 2>&1
cat build/adaptive_native720_network_run.log
python3 - <<'PY'
from pathlib import Path
from PIL import Image
for path in sorted(Path('build').glob('adaptive_native720_frame_*.jpg')):
    with Image.open(path) as im:
        im.load();assert im.size==(1280,720),path
    print('PASS: native 720p JPEG decode',path)
PY
