# Canonical development constraints, normalized 2026-10-15.
# Target: compact CSI + integrated renderer, proc 180 MHz / core 100 MHz.
# PHY delays retain current Interface Designer I3 models.
# Historical build snapshots retain their original constraints and hashes.
# CDC budgets are intentionally unchanged; no multicycle waiver is added.

# Fabric clocks and unrelated clock groups
create_clock -period 10.0000 core_clk
create_clock -period 2.5000 tx_cal_clk_90edge
create_clock -period 2.5000 sdram_clk
create_clock -period 2.5000 rx_cal_clk
create_clock -period 2.5000 tx_cal_clk
create_clock -period 10.0000 clk_100m
create_clock -period 8.0000 i_mipi_tx_pclk

create_clock -period 13.3333 vid_clk_dvi2
create_clock -period 10.0000 i_mipi_rx_pclk
create_clock -period 6.6667 hdmi_tx_slow_clk
create_clock -waveform {0.3333 1.0000} -period 1.3333 hdmi_tx_fast_clk

set_clock_groups -asynchronous -group {core_clk} -group {tx_cal_clk} -group {i_mipi_tx_pclk} -group {vid_clk_dvi2} -group {i_mipi_rx_pclk} -group {sdram_clk} -group {rx_cal_clk}
set_clock_groups -asynchronous -group {i_mipi_tx_pclk}    -group {i_mipi_rx_pclk}
set_clock_groups -asynchronous -group {hdmi_tx_slow_clk} -group {core_clk} -group {i_mipi_rx_pclk}

# Board reference clock and DDR hard-interface constraints
#########################
create_clock -period 40.0000 [get_ports {CLK_25M}]
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

# MIPI RX Lane Constraints
############################
create_clock -period 12.6984 [get_ports {i_cam_ck_CLKOUT}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.604 [get_ports {cam_d0_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min 0.070 [get_ports {cam_d0_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.362 [get_ports {cam_d0_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min -0.140 [get_ports {cam_d0_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.725 [get_ports {cam_d0_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min 0.420 [get_ports {cam_d0_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.560 [get_ports {cam_d0_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min 0.325 [get_ports {cam_d0_HS_IN[*]}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.604 [get_ports {cam_d1_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min 0.070 [get_ports {cam_d1_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.362 [get_ports {cam_d1_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min -0.140 [get_ports {cam_d1_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.725 [get_ports {cam_d1_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min 0.420 [get_ports {cam_d1_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.560 [get_ports {cam_d1_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min 0.325 [get_ports {cam_d1_HS_IN[*]}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.604 [get_ports {cam_d2_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min 0.070 [get_ports {cam_d2_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.362 [get_ports {cam_d2_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min -0.140 [get_ports {cam_d2_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.725 [get_ports {cam_d2_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min 0.420 [get_ports {cam_d2_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.560 [get_ports {cam_d2_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min 0.325 [get_ports {cam_d2_HS_IN[*]}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.604 [get_ports {cam_d3_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min 0.070 [get_ports {cam_d3_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.362 [get_ports {cam_d3_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min -0.140 [get_ports {cam_d3_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.725 [get_ports {cam_d3_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min 0.420 [get_ports {cam_d3_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.560 [get_ports {cam_d3_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min 0.325 [get_ports {cam_d3_HS_IN[*]}]
set_clock_groups -asynchronous -group {i_cam_ck_CLKOUT} -group {core_clk} -group {i_mipi_rx_pclk}

# LVDS Tx Constraints
#######################
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -max 0.435 [get_ports {tmds_tx_clk_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -min -0.140 [get_ports {tmds_tx_clk_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -max 0.435 [get_ports {tmds_tx_clk_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -min -0.140 [get_ports {tmds_tx_clk_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -max 0.435 [get_ports {tmds_tx_data0_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -min -0.140 [get_ports {tmds_tx_data0_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -max 0.435 [get_ports {tmds_tx_data0_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -min -0.140 [get_ports {tmds_tx_data0_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -max 0.435 [get_ports {tmds_tx_data1_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -min -0.140 [get_ports {tmds_tx_data1_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -max 0.435 [get_ports {tmds_tx_data1_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -min -0.140 [get_ports {tmds_tx_data1_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -max 0.435 [get_ports {tmds_tx_data2_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -min -0.140 [get_ports {tmds_tx_data2_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -max 0.435 [get_ports {tmds_tx_data2_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -min -0.140 [get_ports {tmds_tx_data2_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -max 0.483 [get_ports {tmds_tx_clk_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -min -0.175 [get_ports {tmds_tx_clk_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -max 0.483 [get_ports {tmds_tx_data0_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -min -0.175 [get_ports {tmds_tx_data0_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -max 0.483 [get_ports {tmds_tx_data1_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -min -0.175 [get_ports {tmds_tx_data1_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -max 0.483 [get_ports {tmds_tx_data2_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -min -0.175 [get_ports {tmds_tx_data2_TX_RST}]

# Integrated NPU/IPX + DDR AXI domain: 180 MHz, independent of core_clk.
create_clock -period 5.5556 proc_clk

# Display CDC: toggle handshakes with held bundles and dual-clock line RAMs.
# Clock groups remove inter-domain setup/hold; bundle/Gray transport bounds
# below are additional physical requirements, not a blanket CDC safety proof.
# This must follow the
# proc_clk create_clock above or the group references a clock that does not
# exist yet and is silently dropped.
set_clock_groups -asynchronous -group {hdmi_tx_slow_clk} -group {proc_clk}

# Only the first stages of audited two-flop synchronizers are asynchronous.
# Second stages and all NPU/IPX/AXI data paths retain their clock constraints.
set_false_path -from [get_ports {gesture_uart_rx}] -to [get_pins {u_gesture_uart_rx/rx_meta~FF|D}]
set_false_path -to [get_pins {checker0/cap_wr_gray_sync1*|D}]
set_false_path -to [get_pins {checker0/cap_rd_gray_sync1*|D}]
set_false_path -to [get_pins {checker0/cam_frame_start_meta*|D}]
set_false_path -to [get_pins {checker0/cam_frame_end_meta*|D}]
set_false_path -to [get_pins {checker0/origin_tog_meta*|D}]
# Diagnostic LED selection prunes the capture-overflow output synchronizer.
# Restore its first-stage constraint when restoring the business LEDs.
set_false_path -to [get_pins {checker0/cap_good_meta*|D}]

# A bundled-data snapshot: origin_bin/mode are held for a whole camera frame.
# The toggle crosses two flops, and capture starts eight input clocks later.
# Bound its transport to one input clock; do not remove its physical delay check.
set_max_delay 6.6667 -from [get_clocks {hdmi_tx_slow_clk}] -to [get_pins {checker0/origin_bin_axi*|D}]
set_max_delay 6.6667 -from [get_clocks {hdmi_tx_slow_clk}] -to [get_pins {checker0/origin_mode_axi*|D}]

# Async assertion into reset synchronizers; each domain deasserts synchronously.
set_false_path -to [get_pins {proc_reset_pipe*|SR}]
set_false_path -to [get_pins {checker0/input_reset_pipe*|SR}]
set_false_path -from [get_pins {cal_rst_active*|CLK}] -to [get_pins {u_ddr3_top/u_phy_top/u_ddr_phy_if/u3_dout_fifo/u_efx_fifo_top/genblk2.rd_rst*|SR}]

# 180/100MHz status/reset synchronizer heads. Later stages stay timed.
set_false_path -to [get_pins {ddr_ready_pipe[0]*|D}]
set_false_path -to [get_pins {proc_reset_pipe[0]*|D}]
set_false_path -to [get_pins {u_ddr3_top/axi_clk_rst_d1*|D}]
set_false_path -to [get_pins {u_ddr3_top/u_axi4_bus_ctl/init_head|D}]
# SoC interrupt line: cpu_control_irq is sampled by the vendor buffercc, whose
# first stage Efinity packs into one SRL8. Only that head is asynchronous.
set_false_path -to [get_pins {u_sapphire_soc/u_EfxSapphireSoc/userInterruptA_buffercc/i7_2|D}]
# Vendor Gray-pointer synchronizers were mapped to two-tap SRLs.
# Bound transport into their D input to one faster-domain clock.

set_false_path -from [get_pins {cal_rst_active*|CLK}] -to [get_pins {u_ddr3_top/lb2_axi_clk.u_lb2_axi_clk/u_return_fifo/u_efx_fifo_top/genblk2.rd_rst*|SR}]
# Stream AXI/CDC FIFO instance names (two combined FIFOs, not the vendor three).
set_max_delay 5.5556 -to [get_pins {u_ddr3_top/lb2_axi_clk.u_lb2_axi_clk/u_command_write_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7.xrd2wr_addr_sync/dff_5/i*_2|D}]
set_max_delay 5.5556 -to [get_pins {u_ddr3_top/lb2_axi_clk.u_lb2_axi_clk/u_command_write_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7.wr2rd_addr_sync/dff_5/i*_2|D}]
set_max_delay 5.5556 -to [get_pins {u_ddr3_top/lb2_axi_clk.u_lb2_axi_clk/u_return_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7.xrd2wr_addr_sync/dff_5/i*_2|D}]
set_max_delay 5.5556 -to [get_pins {u_ddr3_top/lb2_axi_clk.u_lb2_axi_clk/u_return_fifo/u_efx_fifo_top/xefx_fifo_ctl/genblk7.wr2rd_addr_sync/dff_5/i*_2|D}]
set_false_path -to [get_pins {u_ddr3_top/lb2_axi_clk.u_lb2_axi_clk/u_command_write_fifo/u_efx_fifo_top/genblk2.wr_rst*|SR}]
set_false_path -to [get_pins {u_ddr3_top/lb2_axi_clk.u_lb2_axi_clk/u_command_write_fifo/u_efx_fifo_top/genblk2.rd_rst*|SR}]
set_false_path -to [get_pins {u_ddr3_top/lb2_axi_clk.u_lb2_axi_clk/u_return_fifo/u_efx_fifo_top/genblk2.wr_rst*|SR}]
set_false_path -to [get_pins {u_ddr3_top/lb2_axi_clk.u_lb2_axi_clk/u_return_fifo/u_efx_fifo_top/genblk2.rd_rst*|SR}]
# Only these RTL leaf-register classes have asynchronous SR in style_cpu_control.
# Never cut u_frame/u_csr or sticky_* synchronous SR paths.
# Recheck SR_SYNC in the mapped netlist after RTL/synthesis changes.
set_false_path -to [get_pins {g_accelerated.u_cpu_control/ack_head*|SR g_accelerated.u_cpu_control/ack_level*|SR g_accelerated.u_cpu_control/ack_tail*|SR g_accelerated.u_cpu_control/address_hold*|SR g_accelerated.u_cpu_control/boot_requested*|SR g_accelerated.u_cpu_control/claimed_base*|SR g_accelerated.u_cpu_control/claimed_mode*|SR g_accelerated.u_cpu_control/claimed_sequence*|SR g_accelerated.u_cpu_control/cpu_release*|SR g_accelerated.u_cpu_control/cpu_state*|SR g_accelerated.u_cpu_control/data_hold*|SR g_accelerated.u_cpu_control/display_pending*|SR g_accelerated.u_cpu_control/frame_clear*|SR g_accelerated.u_cpu_control/frame_start*|SR g_accelerated.u_cpu_control/mode_busy*|SR g_accelerated.u_cpu_control/mode_sequence*|SR g_accelerated.u_cpu_control/proc_release*|SR g_accelerated.u_cpu_control/request_head*|SR g_accelerated.u_cpu_control/request_level*|SR g_accelerated.u_cpu_control/request_tail*|SR g_accelerated.u_cpu_control/response_hold*|SR g_accelerated.u_cpu_control/state*|SR g_accelerated.u_cpu_control/target_base*|SR g_accelerated.u_cpu_control/write_hold*|SR}]
# Read-only, two-stage CPU diagnostics; only the asynchronous sampling heads.
# Status words may be transitional and are read repeatedly during bring-up.
# Their second stages and the APB response remain timed in the CPU domain.
set_false_path -to [get_pins {diag_flags_meta*|D}]
set_false_path -to [get_pins {diag_phy_meta*|D}]
set_false_path -to [get_pins {diag_engine_meta*|D}]

# Slow SPI Flash input is oversampled; only its two-stage synchronizer head
# is asynchronous. The sample stage and reader remain timed at 180MHz.
# Efinity packs the two sampling stages into this SRL8; its D pin is the head.
set_false_path -from [get_ports {flash_miso}] -to [get_pins {g_accelerated.u_model_boot/i6_2|D}]
set_output_delay -clock proc_clk -max 0 [get_ports {flash_cs_n flash_clk flash_mosi flash_wp_n flash_hold_n}]
set_output_delay -clock proc_clk -min 0 [get_ports {flash_cs_n flash_clk flash_mosi flash_wp_n flash_hold_n}]

# CPU control mailbox: held payload + four-phase level handshake.
# response_error is pruned in the current map; response_hold remains bounded.
# Explicit EFX_FF instances preserve the first-stage endpoint names.
set_false_path -to [get_pins {g_accelerated.u_cpu_control/request_head|D}]
set_false_path -to [get_pins {g_accelerated.u_cpu_control/ack_head|D}]
# Payload is held until ACK. Bound propagation to one receiving clock.
set_max_delay 5.5556 -from [get_pins {g_accelerated.u_cpu_control/address_hold*|CLK g_accelerated.u_cpu_control/data_hold*|CLK g_accelerated.u_cpu_control/write_hold*|CLK}] -to [get_clocks {proc_clk}]
set_min_delay 0 -from [get_pins {g_accelerated.u_cpu_control/address_hold*|CLK g_accelerated.u_cpu_control/data_hold*|CLK g_accelerated.u_cpu_control/write_hold*|CLK}] -to [get_clocks {proc_clk}]
set_max_delay 10 -from [get_pins {g_accelerated.u_cpu_control/response_hold*|CLK }] -to [get_clocks {core_clk}]
set_min_delay 0 -from [get_pins {g_accelerated.u_cpu_control/response_hold*|CLK }] -to [get_clocks {core_clk}]

# Four-mode CPU control: explicit synchronizer heads.
set_false_path -to [get_pins {mode_switch_head|D mode_fault_head|D g_mode_active*.head|D key3_head|D}]
# Wave trial: only the first D pin of the two-flop event synchronizer is async.
# The tail and GPIO/CPU paths retain their ordinary core_clk timing checks.
set_false_path -to [get_pins {wave_event_head|D wave_left_head|D}]
# Capture format is held alongside origin_mode until the origin toggle arrives.
set_max_delay 6.6667 -from [get_clocks {hdmi_tx_slow_clk}] -to [get_pins {checker0/origin_format_axi*|D}]
