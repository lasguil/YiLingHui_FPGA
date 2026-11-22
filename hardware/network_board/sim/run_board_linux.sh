#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CCACHE_DIR="${CCACHE_DIR:-/tmp/efinity-perf-ccache}"
export CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-/tmp}"
common=(rtl/demo_bus_pkg.sv rtl/gesture_async_fifo.sv rtl/gesture_sync_fifo.sv
 rtl/gesture_frame_capture.sv rtl/gesture_roi_resize.sv rtl/cpu_axi32_ddr128.sv
 rtl/cpu_axi32_ddr128_cdc.sv rtl/demo_axi_merge.sv rtl/apb_csr_cdc.sv
 rtl/gesture_uart.sv rtl/gesture_clock_reset.sv)
for test in tb_cpu_axi32_ddr128 tb_cpu_axi32_ddr128_cdc tb_gesture_clock_reset tb_apb_csr_cdc tb_gesture_uart tb_gesture_async_fifo tb_gesture_video tb_gesture_bus_integration; do
 verilator --binary --timing --assert -Wno-fatal -DSIM_ASSERT --top-module "$test" \
   --Mdir "build/board_$test" "${common[@]}" "sim/$test.sv" > "build/${test}_linux_compile.log" 2>&1
 "build/board_$test/V$test" | tee "build/${test}_linux_run.log"
done
