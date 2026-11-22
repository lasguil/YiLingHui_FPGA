`timescale 1ns/1ps
module tb_decoder_reset_gate;
  reg pclk = 0;
  always #5 pclk = ~pclk;

  reg pll_locked = 1;
  reg raw_busy = 0;
  reg raw_done = 0;
  reg raw_invalid = 0;
  reg [5:0] raw_tap = 0;
  wire decoder_pll_lock = pll_locked && raw_done &&
                          (raw_tap == 6'd5) && !raw_busy && !raw_invalid;
  reg [12:0] rst_cnt = 0;
  wire core_rst_n = rst_cnt[12];
  always @(posedge pclk or negedge decoder_pll_lock) begin
    if (!decoder_pll_lock) rst_cnt <= 0;
    else if (!rst_cnt[12]) rst_cnt <= rst_cnt + 1'b1;
  end

  reg [9:0] rawdata = 10'h354;
  wire bitslip, align_fail, paligned, sync_code, pos_sync_code;
  wire [9:0] shifted, bonded;
  wire bond_rdy;
  wire red_vde, red_pos;
  wire [7:0] red_pixel;
  tmds_decoder u_tmds (
    .rst_n(core_rst_n), .pixelclk(pclk), .ctrl_time(1'b0), .datain(rawdata),
    .potherchrdy(2'b11), .all_align(1'b0), .re_channelbond(1'b0),
    .re_algin_start(1'b0), .align_fail(align_fail), .pmerdy(),
    .debug_bond_rdy(bond_rdy), .paligned(paligned), .bond_data(bonded),
    .sync_code(sync_code), .pos_sync_code_dbg(red_pos), .pc0(), .pc1(),
    .pvde(red_vde), .pdatain(red_pixel)
  );

  wire dly_inc, dly_rst, dly_ena, cal_done, de_sync_en, re_align, pll_rst_n;
  wire [31:0] good_mask;
  wire [15:0] best_count;
  wire [5:0] best_code;
  lvds_dynamic_delay u_dpa (
    .clk(pclk), .rst_n(core_rst_n), .align_fail(1'b0),
    .align_success(1'b0), .de_sync_check_en(de_sync_en),
    .de_sync_pass(1'b0), .de_sync_fail(1'b0), .debug_pos(1'b0),
    .good_mask(good_mask), .best_count(best_count), .best_code(best_code),
    .DLY_INC(dly_inc), .DLY_RST(dly_rst), .DLY_ENA(dly_ena),
    .re_algin_start(re_align), .pll_rst_n(pll_rst_n), .cal_done(cal_done)
  );

  wire resync;
  channelboad_ctrl u_bond_ctrl(
    .clk(pclk), .rst_n(core_rst_n), .align(1'b0),
    .sync1(1'b0), .sync2(1'b0), .sync3(1'b0), .re_sync(resync)
  );

  task automatic check(input logic condition, input string message);
    if (!condition) begin $error("FAIL: %s", message); $fatal(1); end
  endtask

  initial begin
    repeat (4) @(posedge pclk);
    check(!decoder_pll_lock && !core_rst_n, "decoder stays reset before tap-5 result");

    raw_done = 1; raw_tap = 4; raw_busy = 0; raw_invalid = 0; #1;
    check(!decoder_pll_lock, "wrong tap cannot release decoder");
    raw_tap = 5; raw_busy = 1; #1;
    check(!decoder_pll_lock, "busy scan cannot release decoder");
    raw_busy = 0; raw_invalid = 1; #1;
    check(!decoder_pll_lock, "invalid scan cannot release decoder");
    raw_invalid = 0; #1;
    check(decoder_pll_lock, "valid completed tap 5 releases decoder");
    wait(core_rst_n);
    repeat (3) @(posedge pclk);

    // Dirty each control state, then emulate host ACK/advance away from tap 5.
    @(negedge pclk);
    u_tmds.u_bitslip.Output_switch = 4'd7;
    u_tmds.u_phasealgin.align_cnt = 24'd12345;
    u_tmds.u_phasealgin.timeout_cnt = 21'h1fffff;
    u_tmds.u_phasealgin.state = 2'd3;
    u_dpa.state = 4'd4;
    u_dpa.cal_done = 1;
    u_bond_ctrl.state = 2'd3;
    u_bond_ctrl.cnt1 = 6'd27;
    u_bond_ctrl.cnt2 = 6'd9;
    raw_done = 0; // scanner ACKs tap 5; the decoder must reset immediately.
    #1;
    check(!decoder_pll_lock && !core_rst_n, "ACK asynchronously reasserts decoder reset");
    repeat (3) @(posedge pclk);
    #1;
    check(u_tmds.u_bitslip.Output_switch == 0, "bitslip word offset cleared");
    check(u_tmds.u_phasealgin.align_cnt == 0 &&
          u_tmds.u_phasealgin.timeout_cnt == 0, "phasealign stale time/state cleared");
    check(u_dpa.state == 0 && !u_dpa.cal_done, "DPA state and cal_done cleared");
    check(u_bond_ctrl.state == 0 && u_bond_ctrl.cnt1 == 0 &&
          u_bond_ctrl.cnt2 == 0 && !u_bond_ctrl.re_sync,
          "channel-bond controller state cleared");
    check(u_tmds.u_channelbond.invalid == 0 &&
          !u_tmds.u_channelbond.we && !u_tmds.u_channelbond.iamrdy &&
          !u_tmds.u_channelbond.ra_en && u_tmds.u_channelbond.wa == 0 &&
          u_tmds.u_channelbond.ra == 0, "channel-bond FIFO controls cleared");
    $display("PASS decoder reset gate and stale-state clearing");
    $finish;
  end
endmodule
