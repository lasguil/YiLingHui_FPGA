# Second-board gesture pipeline: CPU/APB runs at 100 MHz; NPU, capture,
# ROI, AXI arbitration and DDR AXI run at 180 MHz. DDR PHY internals remain
# on the controller's independent 100 MHz core clock and 400 MHz CK outputs.
# HDMI recovered slow pixel clock carries one RGB pixel per cycle from the
# board 1 150 MHz DVI source; the symbol-preserving RX-to-TX path keeps timing.
create_clock -period 40.000 -name rxc [get_ports {rxc}]
create_clock -period 10.0000 core_clk
create_clock -period 5.5556 proc_clk
create_clock -period 2.5000 sdram_clk
create_clock -period 2.5000 rx_cal_clk
create_clock -period 2.5000 tx_cal_clk
create_clock -period 2.5000 tx_cal_clk_90edge
create_clock -period 40.0000 [get_ports {CLK_25M}]
create_clock -period 6.6667 hdmi_rx_slow_clk
# USER1 debug is supported through the board loader at no more than 800 kHz.
# Model the external TAP clock at that confirmed upper bound (adapter speed
# 800 kHz in tools/gesture_ftdi.cfg); this does not relax core/proc timing.
create_clock -period 1250.000 -name jtag_inst1_TCK [get_ports {jtag_inst1_TCK}]

# SPI Flash is sampled by a two-stage synchronizer in the CPU clock domain.
# Only the asynchronous input to the first stage is exempt from timing.
set_false_path -from [get_ports {flash_miso}] -to [get_pins {u_flash_model_apb/miso_meta_q~FF|D}]
set_output_delay -clock core_clk -max 0 [get_ports {flash_cs_n flash_clk flash_mosi flash_wp_n flash_hold_n}]
set_output_delay -clock core_clk -min 0 [get_ports {flash_cs_n flash_clk flash_mosi flash_wp_n flash_hold_n}]

# CPU/core and processing clocks are phase-unrelated but are deliberately
# timed together here so the bundled mailbox payload paths can receive a real
# max-delay bound. The DDR PHY's command/return FIFOs and HDMI pixel FIFO remain
# genuinely asynchronous to these synchronous fabric domains.
set_clock_groups -asynchronous -group {core_clk proc_clk rxc} -group {sdram_clk rx_cal_clk tx_cal_clk tx_cal_clk_90edge}

# Mailbox toggle synchronizers: only the first synchronizer stages are cut.
# Payload buses are NOT false-pathed; their source-hold/destination-capture
# paths below are explicitly bounded. The second synchronizer stage remains
# timed from the first stage in its own clock domain.
set_false_path -from [get_cells -regexp {^u_cpu_ddr_bridge/u_(aw|w|ar|b|r)_mailbox/(req|ack)_toggle_q~FF$}] -to [get_cells -regexp {^u_cpu_ddr_bridge/u_(aw|w|ar|b|r)_mailbox/(req|ack)_sync1_q~FF$}]
set_false_path -from [get_cells -regexp {^(g_apb_cdc|v_apb_cdc)/(req_toggle|ack_toggle)~FF$}] -to [get_cells -regexp {^(g_apb_cdc|v_apb_cdc)/(req_sync1|ack_sync1)~FF$}]
set_false_path -from [get_clocks proc_clk] -to [get_cells -regexp {^u_cpu_ddr_bridge/m_up_sync1_q~FF$}]
set_false_path -from [get_clocks core_clk] -to [get_cells -regexp {^u_cpu_ddr_bridge/s_up_sync1_q~FF$}]
set_false_path -to [get_pins -regexp {^u_clock_reset/cal_done_core_meta~FF\|D$}]
set_false_path -to [get_pins -regexp {^u_clock_reset/cal_done_proc_meta~FF\|D$}]

# The CPU/DDR bridge reset pipes are asynchronous-assert, locally synchronous
# release synchronizers. Cut only their asynchronous SR pins; keep each
# reset_pipe_q[0] Q -> reset_pipe_q[1] D recovery chain fully timed.
set cpu_ddr_m_reset_sr [get_pins -regexp {^u_cpu_ddr_bridge/m_reset_pipe_q\[[01]\]~FF\|SR$}]
set cpu_ddr_s_reset_sr [get_pins -regexp {^u_cpu_ddr_bridge/s_reset_pipe_q\[[01]\]~FF\|SR$}]
set_false_path -to $cpu_ddr_m_reset_sr
set_false_path -to $cpu_ddr_s_reset_sr

# Runtime calibration loss deliberately asserts the proc CDC epoch reset.
# Only the local reset-pipeline async SR pins are cut; its D release chain is
# still timed at proc_clk.
set proc_cdc_reset_pipe0_sr [get_pins -regexp {^u_clock_reset/proc_cdc_reset_pipe\[0\]~FF\|SR$}]
set proc_cdc_reset_pipe1_sr [get_pins -regexp {^proc_cdc_reset_n~FF\|SR$}]
set proc_cdc_reset_sr [concat $proc_cdc_reset_pipe0_sr $proc_cdc_reset_pipe1_sr]
set_false_path -from [get_cells -regexp {^led\[7\]~FF$}] -to $proc_cdc_reset_sr

# Vendor command/write FIFO reset is asynchronous-assert, clock-synchronous
# release. The calibration watchdog drives both instances' reset synchronizers.
# Cut only their asynchronous SR pins; each local D release chain remains timed.
# Split every pin query because Efinity get_pins does not accept alternation in
# this regexp reliably.
set command_fifo_rd_reset_sr [get_pins -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_command_write_fifo/u_efx_fifo_top/genblk2\.rd_rst\[[01]\]~FF\|SR$}]
set command_fifo_wr_reset_sr [get_pins -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_command_write_fifo/u_efx_fifo_top/genblk2\.wr_rst\[[01]\]~FF\|SR$}]
set return_fifo_rd_reset_sr [get_pins -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_return_fifo/u_efx_fifo_top/genblk2\.rd_rst\[[01]\]~FF\|SR$}]
set return_fifo_wr_reset_sr [get_pins -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_return_fifo/u_efx_fifo_top/genblk2\.wr_rst\[[01]\]~FF\|SR$}]
set ddr_fifo_reset_sr [concat $command_fifo_rd_reset_sr $command_fifo_wr_reset_sr $return_fifo_rd_reset_sr $return_fifo_wr_reset_sr]
set_false_path -from [get_cells -regexp {^u_ddr3_top/axi_clk_rst_d3~FF$}] -to $ddr_fifo_reset_sr
# The calibration watchdog asynchronously asserts the same reset pins via
# ddr3_rstn/reset_all; constrain its actual mapped source as well.
set_false_path -from [get_cells -regexp {^cal_rst_active~FF$}] -to $ddr_fifo_reset_sr
# This is the first proc_clk synchronizer stage for the DDR AXI reset input.
# Cut only its D input; subsequent reset-release stages stay timed.
set_false_path -from [get_cells -regexp {^cal_rst_active~FF$}] -to [get_pins -regexp {^u_ddr3_top/axi_clk_rst_d1~FF\|D$}]
# DDR initialization completion is synchronized into the AXI/proc domain;
# cut only the asynchronous source to the first stage D pin.
set_false_path -from [get_cells -regexp {^u_ddr3_top/cal_done_r~FF$}] -to [get_pins -regexp {^u_ddr3_top/u_axi4_bus_ctl/init_head\|D$}]
# The two DDR AXI-side vendor FIFOs cross Gray pointers between core_clk and
# proc_clk. These are the first SRL8 sampling stages of the documented
# efx_fifo_datasync pipeline; cut only source Gray-register Q to that first
# stage D. Later synchronizer stages and Gray-to-binary logic remain timed.
set command_rgray_src [get_cells -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_command_write_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7\.raddr_cntr_gry_r\[[0-8]\]~FF$}]
set command_rgray_dst [get_pins -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_command_write_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7\.xrd2wr_addr_sync/dff_5/i[0-9]+_2\|D$}]
# Gray buses are launched from registered Gray counters. Bound every source
# bit to the first receiving synchronizer stage, then cut hold analysis only.
# core_clk is 100 MHz (10 ns); proc_clk is 180 MHz (5.5556 ns).
set_max_delay -from $command_rgray_src -to $command_rgray_dst 9.000
set_false_path -hold -from $command_rgray_src -to $command_rgray_dst
set command_wgray_src [get_cells -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_command_write_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7\.waddr_cntr_gry_r\[[0-8]\]~FF$}]
set command_wgray_dst [get_pins -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_command_write_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7\.wr2rd_addr_sync/dff_5/i[0-9]+_2\|D$}]
set_max_delay -from $command_wgray_src -to $command_wgray_dst 5.000
set_false_path -hold -from $command_wgray_src -to $command_wgray_dst
set return_rgray_src [get_cells -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_return_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7\.raddr_cntr_gry_r\[[0-8]\]~FF$}]
set return_rgray_dst [get_pins -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_return_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7\.xrd2wr_addr_sync/dff_5/i[0-9]+_2\|D$}]
set_max_delay -from $return_rgray_src -to $return_rgray_dst 5.000
set_false_path -hold -from $return_rgray_src -to $return_rgray_dst
set return_wgray_src [get_cells -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_return_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7\.waddr_cntr_gry_r\[[0-8]\]~FF$}]
set return_wgray_dst [get_pins -regexp {^u_ddr3_top/lb2_axi_clk\.u_lb2_axi_clk/u_return_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7\.wr2rd_addr_sync/dff_5/i[0-9]+_2\|D$}]
set_max_delay -from $return_wgray_src -to $return_wgray_dst 9.000
set_false_path -hold -from $return_wgray_src -to $return_wgray_dst

# AXI request/response bundled payloads. The mapper flattens the destination
# capture FFs into client_req[3] and bridge response staging; these names are
# verified per dynamic source/capture bit by verify_cdc_payloads.py.
set_max_delay -from [get_cells -regexp {^u_cpu_ddr_bridge/u_aw_mailbox/data_q\[[0-9]+\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.awaddr\[(4|[5-9]|[12][0-9]|3[01])\]~FF$}] 10.000
set_false_path -hold -from [get_cells -regexp {^u_cpu_ddr_bridge/u_aw_mailbox/data_q\[[0-9]+\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.awaddr\[(4|[5-9]|[12][0-9]|3[01])\]~FF$}]
set_max_delay -from [get_cells -regexp {^u_cpu_ddr_bridge/u_ar_mailbox/data_q\[[0-9]+\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.araddr\[(4|[5-9]|[12][0-9]|3[01])\]~FF$}] 10.000
set_false_path -hold -from [get_cells -regexp {^u_cpu_ddr_bridge/u_ar_mailbox/data_q\[[0-9]+\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.araddr\[(4|[5-9]|[12][0-9]|3[01])\]~FF$}]
set_max_delay -from [get_cells -regexp {^u_cpu_ddr_bridge/u_w_mailbox/data_q\[[0-9]+\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.(wdata\[[0-9]+\]|wstrb\[[0-9]+\])~FF$}] 10.000
set_false_path -hold -from [get_cells -regexp {^u_cpu_ddr_bridge/u_w_mailbox/data_q\[[0-9]+\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.(wdata\[[0-9]+\]|wstrb\[[0-9]+\])~FF$}]
# Constant-valued AXI metadata still has source FFs whose reset value can differ
# from the first transaction, so constrain each retained capture bank too.
set_max_delay -from [get_cells -regexp {^u_cpu_ddr_bridge/u_aw_mailbox/data_q\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|45|46|47|48)\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.(awaddr\[[0-3]\]|awsize\[[0-2]\]|awburst\[[0-1]\]|awlen\[[0-7]\]|awid\[[0-3]\])~FF$}] 10.000
set_false_path -hold -from [get_cells -regexp {^u_cpu_ddr_bridge/u_aw_mailbox/data_q\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|45|46|47|48)\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.(awaddr\[[0-3]\]|awsize\[[0-2]\]|awburst\[[0-1]\]|awlen\[[0-7]\]|awid\[[0-3]\])~FF$}]
set_max_delay -from [get_cells -regexp {^u_cpu_ddr_bridge/u_ar_mailbox/data_q\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|45|46|47|48)\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.(araddr\[[0-3]\]|arsize\[[0-2]\]|arburst\[[0-1]\]|arlen\[[0-7]\]|arid\[[0-3]\])~FF$}] 10.000
set_false_path -hold -from [get_cells -regexp {^u_cpu_ddr_bridge/u_ar_mailbox/data_q\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|45|46|47|48)\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.(araddr\[[0-3]\]|arsize\[[0-2]\]|arburst\[[0-1]\]|arlen\[[0-7]\]|arid\[[0-3]\])~FF$}]
set_max_delay -from [get_cells -regexp {^u_cpu_ddr_bridge/u_w_mailbox/data_q\[0\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.wlast~FF$}] 10.000
set_false_path -hold -from [get_cells -regexp {^u_cpu_ddr_bridge/u_w_mailbox/data_q\[0\]~FF$}] -to [get_cells -regexp {^client_req\[3\]\.wlast~FF$}]
set_max_delay -from [get_cells -regexp {^u_cpu_ddr_bridge/u_(b|r)_mailbox/data_q\[[0-9]+\]~FF$}] -to [get_cells -regexp {^u_cpu_ddr_bridge/(b_m_data|r_m_data)\[[0-9]+\]~FF$}] 18.000
set_false_path -hold -from [get_cells -regexp {^u_cpu_ddr_bridge/u_(b|r)_mailbox/data_q\[[0-9]+\]~FF$}] -to [get_cells -regexp {^u_cpu_ddr_bridge/(b_m_data|r_m_data)\[[0-9]+\]~FF$}]

# APB request payload capture FFs are flattened to the remote APB request nets.
set_max_delay -from [get_cells -regexp {^(g_apb_cdc|v_apb_cdc)/(addr_q\[[0-9]+\]|write_q|wdata_q\[[0-9]+\])~FF$}] -to [get_cells -regexp {^(g_paddr\[[0-9]+\]|g_pwrite|g_pwdata\[[0-9]+\]|v_paddr\[[0-9]+\]|v_pwrite|v_pwdata\[[0-9]+\])~FF$}] 10.000
set_false_path -hold -from [get_cells -regexp {^(g_apb_cdc|v_apb_cdc)/(addr_q\[[0-9]+\]|write_q|wdata_q\[[0-9]+\])~FF$}] -to [get_cells -regexp {^(g_paddr\[[0-9]+\]|g_pwrite|g_pwdata\[[0-9]+\]|v_paddr\[[0-9]+\]|v_pwrite|v_pwdata\[[0-9]+\])~FF$}]

# APB read-data return is captured into the core-side response FFs.
set_max_delay -from [get_cells -regexp {^(g_apb_cdc|v_apb_cdc)/remote_rdata_q\[[0-9]+\]~FF$}] -to [get_cells -regexp {^(gesture_cpu_rdata|video_cpu_rdata)\[[0-9]+\]~FF$}] 18.000
set_false_path -hold -from [get_cells -regexp {^(g_apb_cdc|v_apb_cdc)/remote_rdata_q\[[0-9]+\]~FF$}] -to [get_cells -regexp {^(gesture_cpu_rdata|video_cpu_rdata)\[[0-9]+\]~FF$}]

# Sapphire USER1 bridge CDC. Only the toggle's first BufferCC sampling stage
# is false-pathed; the second stage remains timed. Bundled payloads are held by
# the bridge protocol and receive a strict 9 ns setup bound plus hold-only cut.
set jtag_toggle_src [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/flowCCUnsafeByToggle_1/inputArea_target~FF$}]
set jtag_toggle_dst [get_pins -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/flowCCUnsafeByToggle_1/inputArea_target_buffercc/i7_2\|D$}]
set_false_path -from $jtag_toggle_src -to $jtag_toggle_dst
set jtag_cmd_payload_src [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/flowCCUnsafeByToggle_1/inputArea_data_(last|fragment\[0\])~FF$}]
set jtag_cmd_payload_dst [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge_io_remote_cmd_payload_(last|fragment\[0\])~FF$}]
set_max_delay -from $jtag_cmd_payload_src -to $jtag_cmd_payload_dst 9.000
set_false_path -hold -from $jtag_cmd_payload_src -to $jtag_cmd_payload_dst
for {set jtag_bit 0} {$jtag_bit < 32} {incr jtag_bit} {
    set jtag_shift_bit [expr {$jtag_bit + 2}]
    set jtag_rsp_src_pattern [format {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/system_rsp_payload_data\[%d\]~FF$} $jtag_bit]
    set jtag_rsp_dst_pattern [format {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/jtag_readArea_full_shifter\[%d\]~FF$} $jtag_shift_bit]
    set jtag_rsp_src [get_cells -regexp $jtag_rsp_src_pattern]
    set jtag_rsp_dst [get_cells -regexp $jtag_rsp_dst_pattern]
    if {[llength $jtag_rsp_src] != 1 || [llength $jtag_rsp_dst] != 1} {
        error "JTAG response bit $jtag_bit mapping mismatch: src=[llength $jtag_rsp_src] dst=[llength $jtag_rsp_dst]"
    }
    puts "JTAG_RESPONSE_BIT_MATCH bit=$jtag_bit src=[llength $jtag_rsp_src] dst=[llength $jtag_rsp_dst]"
    set_max_delay -from $jtag_rsp_src -to $jtag_rsp_dst 9.000
    set_false_path -hold -from $jtag_rsp_src -to $jtag_rsp_dst
}
set jtag_err_src [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/system_rsp_payload_error~FF$}]
set jtag_err_dst [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/jtag_readArea_full_shifter\[1\]~FF$}]
set_max_delay -from $jtag_err_src -to $jtag_err_dst 9.000
set_false_path -hold -from $jtag_err_src -to $jtag_err_dst
set jtag_valid_src [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/system_rsp_valid~FF$}]
set jtag_valid_dst [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/jtag_readArea_full_shifter\[0\]~FF$}]
set_max_delay -from $jtag_valid_src -to $jtag_valid_dst 9.000
set_false_path -hold -from $jtag_valid_src -to $jtag_valid_dst

# Single-bit proc-to-core diagnostic status and calibration synchronizers.
set_false_path -to [get_pins -regexp {^capture_frame_valid_core_meta~FF\|D$}]
set_false_path -to [get_pins -regexp {^npu_busy_core_meta~FF\|D$}]
set_false_path -to [get_pins -regexp {^u_sapphire_soc/u_EfxSapphireSoc/userInterruptA_buffercc/i7_2\|D$}]
# The J7 UART RX pad is an asynchronous serial input; only its first sample
# flop is excepted. The second synchronizer stage remains timed at 100 MHz.
set_false_path -from [get_ports {gesture_uart_rx}] -to [get_cells -regexp {^u_gesture_uart/rx_meta_q~FF$}]
# Board reference clock and DDR hard-interface constraints
#########################
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~95}] -max 0.302 [get_ports {ddr_addr[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~95}] -min -0.140 [get_ports {ddr_addr[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~36}] -max 0.302 [get_ports {ddr_addr[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~36}] -min -0.140 [get_ports {ddr_addr[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~70}] -max 0.302 [get_ports {ddr_addr[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~70}] -min -0.140 [get_ports {ddr_addr[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~50~1}] -max 0.302 [get_ports {ddr_addr[3]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~50~1}] -min -0.140 [get_ports {ddr_addr[3]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~25}] -max 0.302 [get_ports {ddr_addr[4]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~25}] -min -0.140 [get_ports {ddr_addr[4]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~142~1}] -max 0.302 [get_ports {ddr_addr[5]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~142~1}] -min -0.140 [get_ports {ddr_addr[5]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~59}] -max 0.302 [get_ports {ddr_addr[6]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~59}] -min -0.140 [get_ports {ddr_addr[6]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~110}] -max 0.302 [get_ports {ddr_addr[7]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~110}] -min -0.140 [get_ports {ddr_addr[7]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~26}] -max 0.302 [get_ports {ddr_addr[8]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~26}] -min -0.140 [get_ports {ddr_addr[8]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~127}] -max 0.302 [get_ports {ddr_addr[9]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~127}] -min -0.140 [get_ports {ddr_addr[9]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~138}] -max 0.302 [get_ports {ddr_addr[10]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~138}] -min -0.140 [get_ports {ddr_addr[10]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~60}] -max 0.302 [get_ports {ddr_addr[11]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~60}] -min -0.140 [get_ports {ddr_addr[11]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~35}] -max 0.302 [get_ports {ddr_addr[12]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~35}] -min -0.140 [get_ports {ddr_addr[12]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~71}] -max 0.302 [get_ports {ddr_addr[13]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~71}] -min -0.140 [get_ports {ddr_addr[13]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~74~1}] -max 0.302 [get_ports {ddr_ba[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~74~1}] -min -0.140 [get_ports {ddr_ba[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~132~1}] -max 0.302 [get_ports {ddr_ba[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~132~1}] -min -0.140 [get_ports {ddr_ba[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~126}] -max 0.302 [get_ports {ddr_ba[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~126}] -min -0.140 [get_ports {ddr_ba[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~49}] -max 0.302 [get_ports {ddr_cas_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~49}] -min -0.140 [get_ports {ddr_cas_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~149}] -max 0.302 [get_ports {ddr_ck_lo ddr_ck_hi}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~149}] -min -0.140 [get_ports {ddr_ck_lo ddr_ck_hi}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~123~1}] -max 0.302 [get_ports {ddr_cke[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~123~1}] -min -0.140 [get_ports {ddr_cke[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~95~1}] -max 0.302 [get_ports {ddr_cs_n[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~95~1}] -min -0.140 [get_ports {ddr_cs_n[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~131~1}] -max 0.302 [get_ports {ddr_dm_lo[0] ddr_dm_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~131~1}] -min -0.140 [get_ports {ddr_dm_lo[0] ddr_dm_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~83~1}] -max 0.302 [get_ports {ddr_dm_lo[1] ddr_dm_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~83~1}] -min -0.140 [get_ports {ddr_dm_lo[1] ddr_dm_hi[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~73~1}] -max 0.302 [get_ports {ddr_odt[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~73~1}] -min -0.140 [get_ports {ddr_odt[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~48}] -max 0.302 [get_ports {ddr_ras_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~48}] -min -0.140 [get_ports {ddr_ras_n}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {ddr_reset_n}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {ddr_reset_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~94}] -max 0.302 [get_ports {ddr_we_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~94}] -min -0.140 [get_ports {ddr_we_n}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~148~1}] -max 0.476 [get_ports {ddr_dq_in_lo[0] ddr_dq_in_hi[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~148~1}] -min 0.276 [get_ports {ddr_dq_in_lo[0] ddr_dq_in_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -max 0.302 [get_ports {ddr_dq_out_lo[0] ddr_dq_out_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -min -0.140 [get_ports {ddr_dq_out_lo[0] ddr_dq_out_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -max 0.302 [get_ports {ddr_dq_oe[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -min -0.140 [get_ports {ddr_dq_oe[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~157~1}] -max 0.476 [get_ports {ddr_dq_in_lo[1] ddr_dq_in_hi[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~157~1}] -min 0.276 [get_ports {ddr_dq_in_lo[1] ddr_dq_in_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -max 0.302 [get_ports {ddr_dq_out_lo[1] ddr_dq_out_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -min -0.140 [get_ports {ddr_dq_out_lo[1] ddr_dq_out_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -max 0.302 [get_ports {ddr_dq_oe[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -min -0.140 [get_ports {ddr_dq_oe[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~164~1}] -max 0.476 [get_ports {ddr_dq_in_lo[2] ddr_dq_in_hi[2]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~164~1}] -min 0.276 [get_ports {ddr_dq_in_lo[2] ddr_dq_in_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -max 0.302 [get_ports {ddr_dq_out_lo[2] ddr_dq_out_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -min -0.140 [get_ports {ddr_dq_out_lo[2] ddr_dq_out_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -max 0.302 [get_ports {ddr_dq_oe[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -min -0.140 [get_ports {ddr_dq_oe[2]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~149~1}] -max 0.476 [get_ports {ddr_dq_in_lo[3] ddr_dq_in_hi[3]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~149~1}] -min 0.276 [get_ports {ddr_dq_in_lo[3] ddr_dq_in_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -max 0.302 [get_ports {ddr_dq_out_lo[3] ddr_dq_out_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -min -0.140 [get_ports {ddr_dq_out_lo[3] ddr_dq_out_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -max 0.302 [get_ports {ddr_dq_oe[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -min -0.140 [get_ports {ddr_dq_oe[3]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~189~1}] -max 0.476 [get_ports {ddr_dq_in_lo[4] ddr_dq_in_hi[4]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~189~1}] -min 0.276 [get_ports {ddr_dq_in_lo[4] ddr_dq_in_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -max 0.302 [get_ports {ddr_dq_out_lo[4] ddr_dq_out_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -min -0.140 [get_ports {ddr_dq_out_lo[4] ddr_dq_out_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -max 0.302 [get_ports {ddr_dq_oe[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -min -0.140 [get_ports {ddr_dq_oe[4]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~156~1}] -max 0.476 [get_ports {ddr_dq_in_lo[5] ddr_dq_in_hi[5]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~156~1}] -min 0.276 [get_ports {ddr_dq_in_lo[5] ddr_dq_in_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -max 0.302 [get_ports {ddr_dq_out_lo[5] ddr_dq_out_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -min -0.140 [get_ports {ddr_dq_out_lo[5] ddr_dq_out_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -max 0.302 [get_ports {ddr_dq_oe[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -min -0.140 [get_ports {ddr_dq_oe[5]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~165~1}] -max 0.476 [get_ports {ddr_dq_in_lo[6] ddr_dq_in_hi[6]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~165~1}] -min 0.276 [get_ports {ddr_dq_in_lo[6] ddr_dq_in_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -max 0.302 [get_ports {ddr_dq_out_lo[6] ddr_dq_out_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -min -0.140 [get_ports {ddr_dq_out_lo[6] ddr_dq_out_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -max 0.302 [get_ports {ddr_dq_oe[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -min -0.140 [get_ports {ddr_dq_oe[6]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~188~1}] -max 0.476 [get_ports {ddr_dq_in_lo[7] ddr_dq_in_hi[7]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~188~1}] -min 0.276 [get_ports {ddr_dq_in_lo[7] ddr_dq_in_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -max 0.302 [get_ports {ddr_dq_out_lo[7] ddr_dq_out_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -min -0.140 [get_ports {ddr_dq_out_lo[7] ddr_dq_out_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -max 0.302 [get_ports {ddr_dq_oe[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -min -0.140 [get_ports {ddr_dq_oe[7]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~82~1}] -max 0.476 [get_ports {ddr_dq_in_lo[8] ddr_dq_in_hi[8]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~82~1}] -min 0.276 [get_ports {ddr_dq_in_lo[8] ddr_dq_in_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -max 0.302 [get_ports {ddr_dq_out_lo[8] ddr_dq_out_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -min -0.140 [get_ports {ddr_dq_out_lo[8] ddr_dq_out_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -max 0.302 [get_ports {ddr_dq_oe[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -min -0.140 [get_ports {ddr_dq_oe[8]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~39~1}] -max 0.476 [get_ports {ddr_dq_in_lo[9] ddr_dq_in_hi[9]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~39~1}] -min 0.276 [get_ports {ddr_dq_in_lo[9] ddr_dq_in_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -max 0.302 [get_ports {ddr_dq_out_lo[9] ddr_dq_out_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -min -0.140 [get_ports {ddr_dq_out_lo[9] ddr_dq_out_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -max 0.302 [get_ports {ddr_dq_oe[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -min -0.140 [get_ports {ddr_dq_oe[9]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~22~1}] -max 0.476 [get_ports {ddr_dq_in_lo[10] ddr_dq_in_hi[10]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~22~1}] -min 0.276 [get_ports {ddr_dq_in_lo[10] ddr_dq_in_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -max 0.302 [get_ports {ddr_dq_out_lo[10] ddr_dq_out_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -min -0.140 [get_ports {ddr_dq_out_lo[10] ddr_dq_out_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -max 0.302 [get_ports {ddr_dq_oe[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -min -0.140 [get_ports {ddr_dq_oe[10]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~92~1}] -max 0.476 [get_ports {ddr_dq_in_lo[11] ddr_dq_in_hi[11]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~92~1}] -min 0.276 [get_ports {ddr_dq_in_lo[11] ddr_dq_in_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -max 0.302 [get_ports {ddr_dq_out_lo[11] ddr_dq_out_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -min -0.140 [get_ports {ddr_dq_out_lo[11] ddr_dq_out_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -max 0.302 [get_ports {ddr_dq_oe[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -min -0.140 [get_ports {ddr_dq_oe[11]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~23~1}] -max 0.476 [get_ports {ddr_dq_in_lo[12] ddr_dq_in_hi[12]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~23~1}] -min 0.276 [get_ports {ddr_dq_in_lo[12] ddr_dq_in_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -max 0.302 [get_ports {ddr_dq_out_lo[12] ddr_dq_out_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -min -0.140 [get_ports {ddr_dq_out_lo[12] ddr_dq_out_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -max 0.302 [get_ports {ddr_dq_oe[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -min -0.140 [get_ports {ddr_dq_oe[12]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~38~1}] -max 0.476 [get_ports {ddr_dq_in_lo[13] ddr_dq_in_hi[13]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~38~1}] -min 0.276 [get_ports {ddr_dq_in_lo[13] ddr_dq_in_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -max 0.302 [get_ports {ddr_dq_out_lo[13] ddr_dq_out_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -min -0.140 [get_ports {ddr_dq_out_lo[13] ddr_dq_out_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -max 0.302 [get_ports {ddr_dq_oe[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -min -0.140 [get_ports {ddr_dq_oe[13]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~11~1}] -max 0.476 [get_ports {ddr_dq_in_lo[14] ddr_dq_in_hi[14]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~11~1}] -min 0.276 [get_ports {ddr_dq_in_lo[14] ddr_dq_in_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -max 0.302 [get_ports {ddr_dq_out_lo[14] ddr_dq_out_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -min -0.140 [get_ports {ddr_dq_out_lo[14] ddr_dq_out_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -max 0.302 [get_ports {ddr_dq_oe[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -min -0.140 [get_ports {ddr_dq_oe[14]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~12~1}] -max 0.476 [get_ports {ddr_dq_in_lo[15] ddr_dq_in_hi[15]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~12~1}] -min 0.276 [get_ports {ddr_dq_in_lo[15] ddr_dq_in_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -max 0.302 [get_ports {ddr_dq_out_lo[15] ddr_dq_out_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -min -0.140 [get_ports {ddr_dq_out_lo[15] ddr_dq_out_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -max 0.302 [get_ports {ddr_dq_oe[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -min -0.140 [get_ports {ddr_dq_oe[15]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~172~1}] -max 0.476 [get_ports {ddr_dqs_in_lo[0] ddr_dqs_in_hi[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~172~1}] -min 0.276 [get_ports {ddr_dqs_in_lo[0] ddr_dqs_in_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -max 0.302 [get_ports {ddr_dqs_out_lo[0] ddr_dqs_out_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -min -0.140 [get_ports {ddr_dqs_out_lo[0] ddr_dqs_out_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -max 0.302 [get_ports {ddr_dqs_oe[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -min -0.140 [get_ports {ddr_dqs_oe[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~175~1}] -max 0.302 [get_ports {ddr_dqs_oe_n[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~175~1}] -min -0.140 [get_ports {ddr_dqs_oe_n[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~30~1}] -max 0.476 [get_ports {ddr_dqs_in_lo[1] ddr_dqs_in_hi[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~30~1}] -min 0.276 [get_ports {ddr_dqs_in_lo[1] ddr_dqs_in_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -max 0.302 [get_ports {ddr_dqs_out_lo[1] ddr_dqs_out_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -min -0.140 [get_ports {ddr_dqs_out_lo[1] ddr_dqs_out_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -max 0.302 [get_ports {ddr_dqs_oe[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -min -0.140 [get_ports {ddr_dqs_oe[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~33~1}] -max 0.302 [get_ports {ddr_dqs_oe_n[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~33~1}] -min -0.140 [get_ports {ddr_dqs_oe_n[1]}]

# RX-recovered pixel clock drives the direct HDMI encoder and TX LVDS.
# These IO limits constrain the nominal 148.5 MHz 1080p60 mode; verify
# the active input mode and re-constrain if a different recovered rate is used.
set_output_delay -clock hdmi_rx_slow_clk -max 0.435 [get_ports {tmds_tx_clk_TX_DATA[*] tmds_tx_data0_TX_DATA[*] tmds_tx_data1_TX_DATA[*] tmds_tx_data2_TX_DATA[*]}]
set_output_delay -clock hdmi_rx_slow_clk -min -0.140 [get_ports {tmds_tx_clk_TX_DATA[*] tmds_tx_data0_TX_DATA[*] tmds_tx_data1_TX_DATA[*] tmds_tx_data2_TX_DATA[*]}]


# 100M-only RGMII: recovered PHY RX clock, no additional PLL.
# Keep rxc/core/proc timed together so Gray max-delay bounds remain effective.
set_false_path -to [get_pins -regexp {^net_status_meta\[[0-9]+\]~FF\|D$}]
# The MJPEG frame-start toggle crosses from recovered TX clock to proc_clk;
# busy/error status return through two-flop synchronizers. Cut only the first
# synchronizer D pins and asynchronous reset pins; keep later stages timed.
set_false_path -to [get_pins -regexp {^mjpeg_start_sync\[0\]~FF\|D$}]
set_false_path -to [get_pins -regexp {^mjpeg_busy_sync\[0\]~FF\|D$}]
set_false_path -to [get_pins -regexp {^mjpeg_error_sync\[0\]~FF\|D$}]
set_false_path -to [get_pins -regexp {^mjpeg_source_overflow_sync\[0\]~FF\|D$}]
set_false_path -to [get_pins -regexp {^mjpeg_source_error_sync\[0\]~FF\|D$}]
set_false_path -to [get_pins -regexp {^mjpeg_output_overflow_sync\[0\]~FF\|D$}]
set_false_path -to [get_pins -regexp {^u_mjpeg_source/u_capture/bad_sync1~FF\|D$}]
set_false_path -to [get_pins -regexp {^mjpeg_source_frame_sync\[0\]~FF\|D$}]
set_false_path -to [get_pins -regexp {^u_capture/bad_sync1~FF\|D$}]
set_false_path -to [get_pins -regexp {^mjpeg_start_sync\[[0-2]\]~FF\|SR$}]
set_false_path -to [get_pins -regexp {^mjpeg_stream_up\[[01]\]~FF\|SR$}]
set_false_path -to [get_pins -regexp {^mjpeg_link_abort~FF\|SR$}]
set_false_path -to [get_pins -regexp {^mjpeg_busy_sync\[[01]\]~FF\|SR$}]
set_false_path -to [get_pins -regexp {^mjpeg_error_sync\[[01]\]~FF\|SR$}]
set_false_path -to [get_pins -regexp {^mjpeg_source_overflow_sync\[[01]\]~FF\|SR$}]
set_false_path -to [get_pins -regexp {^mjpeg_source_error_sync\[[01]\]~FF\|SR$}]
set_false_path -to [get_pins -regexp {^mjpeg_output_overflow_sync\[[01]\]~FF\|SR$}]
set_false_path -to [get_pins -regexp {^mjpeg_source_frame_sync\[[01]\]~FF\|SR$}]
# Reset release is synchronized locally in the recovered HDMI pixel domain.
# Only the first-stage asynchronous reset pins are exempt; functional paths
# out of each local reset synchronizer remain timed.
set_false_path -to [get_pins -regexp {^u_capture/pclk_reset_pipe\[[01]\]~FF\|SR$}]
set_false_path -to [get_pins -regexp {^u_mjpeg_source/u_capture/pclk_reset_pipe\[[01]\]~FF\|SR$}]
# The async FIFO's common reset asserts asynchronously in both clock domains;
# its local two-stage reset release and all functional paths remain timed.
set_false_path -to [get_pins -regexp {^u_mjpeg_fifo/.*~FF\|SR$}]
set_false_path -to [get_pins -regexp {^u_mjpeg_source/u_capture/u_pixel_fifo/.*~FF\|SR$}]
set_false_path -to [get_pins -regexp {^u_capture/u_pixel_fifo/.*~FF\|SR$}]
# Efinity promotes the FWFT head and empty-state registers to top-level aliases.
# Their asynchronous reset pins still originate from the shared FIFO reset.
set_false_path -to [get_pins -regexp {^mjpeg_fifo_data\[[0-8]\]~FF\|SR$}]
set_false_path -to [get_pins -regexp {^net_pixel_valid~FF\|SR$}]
# Board timing assumptions for the 25MHz PHY interface; verify electrically on hardware.
set_input_delay -clock rxc -max 10.0 [get_ports {rxd_hi_i[*] rx_dv_LO}]
set_input_delay -clock rxc -min 0.0 [get_ports {rxd_hi_i[*] rx_dv_LO}]
set_output_delay -clock rxc -max 5.0 [get_ports {txd_hi_o[*] txd_lo_o[*] tx_en_o_HI tx_en_o_LO}]
set_output_delay -clock rxc -min 0.0 [get_ports {txd_hi_o[*] txd_lo_o[*] tx_en_o_HI tx_en_o_LO}]

# Bound both 13-bit MJPEG FIFO Gray-pointer crossings to less than the faster
# 5.556 ns proc_clk period. Do not cut setup on these first-stage paths.
set mjpeg_wgray_src [get_cells -regexp {^u_mjpeg_fifo/(wgray\[[0-9]+\]|wbin\[13\])~FF$}]
set mjpeg_wgray_dst [get_pins -regexp {^u_mjpeg_fifo/wgray_r1\[[0-9]+\]~FF\|D$}]
set_max_delay -from $mjpeg_wgray_src -to $mjpeg_wgray_dst 5.000
set_false_path -hold -from $mjpeg_wgray_src -to $mjpeg_wgray_dst
set mjpeg_rgray_src [get_cells -regexp {^u_mjpeg_fifo/(rcons_gray\[[0-9]+\]|rcons_bin\[13\])~FF$}]
set mjpeg_rgray_dst [get_pins -regexp {^u_mjpeg_fifo/rcons_gray_w1\[[0-9]+\]~FF\|D$}]
set_max_delay -from $mjpeg_rgray_src -to $mjpeg_rgray_dst 5.000
set_false_path -hold -from $mjpeg_rgray_src -to $mjpeg_rgray_dst

# Bound the recovered-HDMI-clock pixel FIFO Gray-pointer paths to the faster
# proc_clk period. Data itself crosses only through the dual-clock RAM.
set hdmi_mjpeg_wgray_src [get_cells -regexp {^u_mjpeg_source/u_capture/u_pixel_fifo/(wgray\[[0-9]+\]|wbin\[11\])~FF$}]
set hdmi_mjpeg_wgray_dst [get_pins -regexp {^u_mjpeg_source/u_capture/u_pixel_fifo/wgray_r1\[[0-9]+\]~FF\|D$}]
set_max_delay -from $hdmi_mjpeg_wgray_src -to $hdmi_mjpeg_wgray_dst 5.000
set_false_path -hold -from $hdmi_mjpeg_wgray_src -to $hdmi_mjpeg_wgray_dst
set hdmi_mjpeg_rgray_src [get_cells -regexp {^u_mjpeg_source/u_capture/u_pixel_fifo/(rcons_gray\[[0-9]+\]|rcons_bin\[11\])~FF$}]
set hdmi_mjpeg_rgray_dst [get_pins -regexp {^u_mjpeg_source/u_capture/u_pixel_fifo/rcons_gray_w1\[[0-9]+\]~FF\|D$}]
set_max_delay -from $hdmi_mjpeg_rgray_src -to $hdmi_mjpeg_rgray_dst 5.000
set_false_path -hold -from $hdmi_mjpeg_rgray_src -to $hdmi_mjpeg_rgray_dst

# Also constrain the existing 640x360 capture FIFO after exposing these
# dedicated pixel-clock synchronizers to STA.
set hdmi_capture_wgray_src [get_cells -regexp {^u_capture/u_pixel_fifo/(wgray\[[0-8]\]|wbin\[9\])~FF$}]
set hdmi_capture_wgray_dst [get_pins -regexp {^u_capture/u_pixel_fifo/wgray_r1\[[0-9]+\]~FF\|D$}]
set_max_delay -from $hdmi_capture_wgray_src -to $hdmi_capture_wgray_dst 5.000
set_false_path -hold -from $hdmi_capture_wgray_src -to $hdmi_capture_wgray_dst
set hdmi_capture_rgray_src [get_cells -regexp {^u_capture/u_pixel_fifo/(rcons_gray\[[0-8]\]|rcons_bin\[9\])~FF$}]
set hdmi_capture_rgray_dst [get_pins -regexp {^u_capture/u_pixel_fifo/rcons_gray_w1\[[0-9]+\]~FF\|D$}]
set_max_delay -from $hdmi_capture_rgray_src -to $hdmi_capture_rgray_dst 5.000
set_false_path -hold -from $hdmi_capture_rgray_src -to $hdmi_capture_rgray_dst

# Web/J7 mailbox CDC. Keep both Gray-pointer directions timed with a 5 ns
# max-delay bound; do not cut these first-stage synchronizer D paths.
set_false_path -to [get_pins -regexp {.*u_web_control_mailbox.*reset_pipe.*\|SR$}]
set web_cmd_wgray_src [get_cells -regexp {^u_web_control_mailbox/u_cmd_fifo/(wgray\[[0-7]\]|wbin\[7\])~FF$}]
set web_cmd_wgray_dst [get_pins -regexp {^u_web_control_mailbox/u_cmd_fifo/wgray_r1\[[0-7]\]~FF\|D$}]
set_max_delay -from $web_cmd_wgray_src -to $web_cmd_wgray_dst 5.000
set_false_path -hold -from $web_cmd_wgray_src -to $web_cmd_wgray_dst
set web_cmd_rgray_src [get_cells -regexp {^u_web_control_mailbox/u_cmd_fifo/(rcons_gray\[[0-7]\]|rcons_bin\[7\])~FF$}]
set web_cmd_rgray_dst [get_pins -regexp {^u_web_control_mailbox/u_cmd_fifo/rcons_gray_w1\[[0-7]\]~FF\|D$}]
set_max_delay -from $web_cmd_rgray_src -to $web_cmd_rgray_dst 5.000
set_false_path -hold -from $web_cmd_rgray_src -to $web_cmd_rgray_dst
set web_status_wgray_src [get_cells -regexp {^u_web_control_mailbox/u_status_fifo/(wgray\[[0-4]\]|wbin\[4\])~FF$}]
set web_status_wgray_dst [get_pins -regexp {^u_web_control_mailbox/u_status_fifo/wgray_r1\[[0-4]\]~FF\|D$}]
set_max_delay -from $web_status_wgray_src -to $web_status_wgray_dst 5.000
set_false_path -hold -from $web_status_wgray_src -to $web_status_wgray_dst
set web_status_rgray_src [get_cells -regexp {^u_web_control_mailbox/u_status_fifo/(rcons_gray\[[0-4]\]|rcons_bin\[4\])~FF$}]
set web_status_rgray_dst [get_pins -regexp {^u_web_control_mailbox/u_status_fifo/rcons_gray_w1\[[0-4]\]~FF\|D$}]
set_max_delay -from $web_status_rgray_src -to $web_status_rgray_dst 5.000
set_false_path -hold -from $web_status_rgray_src -to $web_status_rgray_dst

# Fixed 1080p input has no adaptive mode metadata synchronizer.

# Observational debug words are interpreted only after stable hangs.
set_false_path -to [get_pins -regexp {^u_npu_diag_uart/status_meta\[[0-9]+\]~FF\|D$}]
