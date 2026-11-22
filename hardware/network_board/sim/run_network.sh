#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/net_sim
iverilog -g2012 -I rtl -DSIM_ASSERT -s tb_web_control_mailbox -o build/tb_web_control_mailbox \
  rtl/gesture_async_fifo.sv rtl/web_control_mailbox.sv sim/tb_web_control_mailbox.sv
vvp build/tb_web_control_mailbox | tee build/web_control_mailbox_run.log
iverilog -g2012 -I rtl -s tb_net_status -o build/tb_net_status \
  rtl/network/net_route/udp_regs.v sim/tb_net_status.sv
vvp build/tb_net_status | tee build/net_status_run.log
iverilog -g2012 -I rtl -s udp_test_top -o build/net_elaboration \
  rtl/network/udp_test_top.v rtl/network/net_route/*.v \
  rtl/network/heijin_test/mac/*.v rtl/network/heijin_test/mac/rx/*.v \
  rtl/network/heijin_test/mac/tx/*.v rtl/network/heijin_test/arbi/*.v \
  rtl/network/heijin_test/rgmii2gmii_altera/*.v
iverilog -g2012 -I rtl -s tb_net_packet -o build/tb_net_packet \
  rtl/network/net_route/vid_packet.v sim/tb_net_packet.sv
vvp build/tb_net_packet | tee build/net_packet_run.log
iverilog -g2012 -I rtl -s tb_jpeg_vid_packet -o build/tb_jpeg_vid_packet \
  rtl/network/net_route/vid_packet.v sim/tb_jpeg_vid_packet.sv
vvp build/tb_jpeg_vid_packet | tee build/jpeg_net_packet_run.log
python3 -I -B sim/check_pc_protocol.py | tee build/pc_protocol_run.log
common=(rtl/demo_bus_pkg.sv rtl/gesture_async_fifo.sv rtl/gesture_net_reader.sv)
for test in tb_net_reader tb_gesture_net_integration; do
  files=("${common[@]}")
  if [[ "$test" == tb_gesture_net_integration ]]; then
    files+=(rtl/gesture_sync_fifo.sv rtl/gesture_frame_capture.sv \
      rtl/gesture_roi_resize.sv rtl/cpu_axi32_ddr128.sv rtl/demo_axi_merge.sv)
  fi
  verilator --cc --exe --main --timing --assert -Wno-fatal --top-module "$test" \
    --Mdir build/net_sim "${files[@]}" "sim/$test.sv" > "build/${test}_compile.log" 2>&1
  make -C build/net_sim -f "V${test}.mk" -j 4 > "build/${test}_make.log" 2>&1
  "build/net_sim/V$test" | tee "build/${test}_run.log"
done
verilator --binary --timing --assert -Wno-fatal --top-module tb_capture_recovery \
  --Mdir build/capture_sim rtl/demo_bus_pkg.sv rtl/gesture_async_fifo.sv \
  rtl/gesture_sync_fifo.sv rtl/gesture_frame_capture.sv sim/tb_capture_recovery.sv \
  > build/capture_recovery_compile.log 2>&1
build/capture_sim/Vtb_capture_recovery | tee build/capture_recovery_run.log
