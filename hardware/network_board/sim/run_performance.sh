#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CCACHE_DIR="${CCACHE_DIR:-/tmp/efinity-perf-ccache}"
export CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-/tmp}"
mkdir -p build
for profile in '320 180 60' '384 216 40' '480 270 30' '640 360 15' '640 360 20' '640 360 24'; do
  read -r w h fps <<< "$profile"
  tag="${w}x${h}_${fps}"
  verilator --binary --timing --assert -Wno-fatal --top-module tb_tx_pipeline \
    -GW="$w" -GH="$h" -GFPS="$fps" --Mdir "build/tx_$tag" \
    sim/tb_tx_pipeline.sv rtl/network/net_route/vid_packet.v rtl/network/net_route/udp_tx_arb.v \
    rtl/network/heijin_test/mac/tx/*.v rtl/network/heijin_test/mac/crc.v \
    rtl/network/heijin_test/mac/dpram.v rtl/network/heijin_test/arbi/gmii_tx_buffer.v \
    > "build/tx_${tag}_compile.log" 2>&1
  "build/tx_$tag/Vtb_tx_pipeline" +trace="build/tx_${tag}_frames.hex" | tee "build/tx_${tag}_run.log"
  python3 -I -B sim/check_tx_pipeline.py --w "$w" --h "$h" --trace "build/tx_${tag}_frames.hex" \
    | tee "build/tx_${tag}_check.log"
  cp build/tx_pipeline_summary.json "build/tx_${tag}_summary.json"
done
for profile in '320 180' '384 216' '480 270' '640 360'; do
  read -r w h <<< "$profile"
  tag="${w}x${h}"
  verilator --binary --timing --assert -Wno-fatal --top-module tb_net_reader \
    -GOW="$w" -GOH="$h" --Mdir "build/reader_$tag" \
    rtl/demo_bus_pkg.sv rtl/gesture_async_fifo.sv rtl/gesture_net_reader.sv sim/tb_net_reader.sv \
    > "build/reader_${tag}_compile.log" 2>&1
  "build/reader_$tag/Vtb_net_reader" | tee "build/reader_${tag}_run.log"
done
