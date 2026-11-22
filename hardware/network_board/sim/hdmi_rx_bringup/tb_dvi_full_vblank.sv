`timescale 1ns/1ps
module tb_dvi_full_vblank;
  localparam integer H_TOTAL = 2200;
  localparam integer H_ACTIVE = 1920;
  localparam integer V_TOTAL = 1125;
  localparam integer V_BLANK = 45;
  localparam integer FRAME_CLOCKS = H_TOTAL * V_TOTAL;

  reg pclk = 0;
  always #3.333 pclk = ~pclk;

  reg pll_locked = 1;
  reg raw_busy = 0;
  reg raw_done = 1;       // scanner halted on the selected tap
  reg raw_invalid = 0;
  reg [5:0] raw_tap = 5;
  wire decoder_lock = pll_locked && raw_done && (raw_tap == 5) &&
                      !raw_busy && !raw_invalid;

  integer x = 0;
  integer y = 0;
  reg [9:0] bdata = 10'h354;
  reg [9:0] gdata = 10'h354;
  reg [9:0] rdata = 10'h354;
  wire hs, vs, de;
  wire [7:0] red, green, blue;
  wire pll_rst_n;
  wire cal_done, align_success, de_sync_pass, all_align;
  wire bond_rdy, b_align, g_align, r_align;
  wire b_rdy, g_rdy, r_rdy;
  wire red_pos;
  wire [31:0] red_window;
  wire [15:0] best_count;
  wire [5:0] best_code;

  // Alignment counter thresholds are shortened only for this TB. The 2200x1125
  // raster, 280-clock line blank, and 45 full vertical-blank lines are real.
  dvi_decoder #(
    .PA_TIMEOUT_BIT(20), .PA_ALIGNED_BIT(8), .PA_ALIGN_WAIT_BIT(7)
  ) dut (
    .pclk(pclk), .bdata(bdata), .gdata(gdata), .rdata(rdata),
    .pll_lock(decoder_lock), .pll_rst_n(pll_rst_n),
    .hsync(hs), .vsync(vs), .de(de), .red(red), .green(green), .blue(blue),
    .debug_cal_done(cal_done), .debug_align_success(align_success),
    .debug_de_sync_pass(de_sync_pass), .debug_all_align(all_align),
    .debug_bond_rdy(bond_rdy), .debug_blue_rdy(b_rdy),
    .debug_green_rdy(g_rdy), .debug_red_rdy(r_rdy),
    .debug_b_align(b_align), .debug_g_align(g_align), .debug_r_align(r_align),
    .debug_red_pos(red_pos), .debug_red_window(red_window),
    .debug_best_count(best_count), .debug_best_code(best_code)
  );

  // Source is aligned to 10-bit word boundaries (phase zero). Active pixels
  // are non-control words; red/green are CTL0 in blanking; blue carries CTL
  // sync bits. HS pulse is 44 clocks inside each 280-clock line blank.
  always @(negedge pclk) begin
    if ((y < V_BLANK) || (x >= H_ACTIVE)) begin
      rdata = 10'h354;
      gdata = 10'h354;
      if (x >= H_ACTIVE && x < H_ACTIVE+44)
        bdata = (y < 3) ? 10'h2ab : 10'h0ab; // HS=1, VS during first 3 lines
      else
        bdata = (y < 3) ? 10'h154 : 10'h354; // HS=0, VS during first 3 lines
    end else begin
      rdata = 10'h0ff;
      gdata = 10'h155;
      bdata = 10'h233;
    end
  end

  integer frames = 0;
  integer de_lines = 0;
  integer line_width = 0;
  integer min_width = 99999;
  integer max_width = 0;
  integer sync_fail_count = 0;
  integer bit_slip_high_cycles = 0;
  integer cal_rises = 0;
  integer cal_falls = 0;
  integer last_cal = 0;
  integer last_state = -1;
  reg prev_vs = 0;
  reg prev_de = 0;

  always @(posedge pclk) begin
    #1;
    if (vs && !prev_vs) begin
      frames = frames + 1;
      $display("FRAME %0d y=%0d cal=%b dpa_state=%0d align=%b lanes=%b%b%b bond=%b DElines=%0d",
               frames,y,cal_done,dut.lvds_dynamic_delay_inst.state,
               align_success,r_align,g_align,b_align,bond_rdy,de_lines);
    end
    if (de && !prev_de) line_width = 1;
    else if (de && prev_de) line_width = line_width + 1;
    if (!de && prev_de) begin
      de_lines = de_lines + 1;
      if (line_width < min_width) min_width = line_width;
      if (line_width > max_width) max_width = line_width;
    end
    if (dut.sync_fail) begin
      sync_fail_count = sync_fail_count + 1;
      if (sync_fail_count <= 8)
        $display("SYNC_FAIL n=%0d raster=%0d,%0d de=%b decoder_de={%b%b%b} bond=%b timeout=%0d de_state=%0d/%0d dpa_state=%0d",
                 sync_fail_count,x,y,de,dut.de_b,dut.de_g,dut.de_r,bond_rdy,
                 dut.de_sync_inst.timeout_cnt,dut.de_sync_inst.pre_state,
                 dut.de_sync_inst.nx_state,dut.lvds_dynamic_delay_inst.state);
    end
    if (dut.u_tmds_decoder_0.u_phasealgin.bitslip ||
        dut.u_tmds_decoder_1.u_phasealgin.bitslip ||
        dut.u_tmds_decoder_2.u_phasealgin.bitslip)
      bit_slip_high_cycles = bit_slip_high_cycles + 1;
    if (cal_done && !last_cal) cal_rises = cal_rises + 1;
    if (!cal_done && last_cal) cal_falls = cal_falls + 1;
    if (dut.lvds_dynamic_delay_inst.state != last_state) begin
      $display("DPA state %0d->%0d at raster %0d,%0d cal=%b deSync=%b align=%b lanes=%b%b%b slip=%b%b%b",
               last_state,dut.lvds_dynamic_delay_inst.state,x,y,cal_done,
               de_sync_pass,align_success,r_align,g_align,b_align,
               dut.u_tmds_decoder_0.u_phasealgin.bitslip,
               dut.u_tmds_decoder_1.u_phasealgin.bitslip,
               dut.u_tmds_decoder_2.u_phasealgin.bitslip);
      last_state = dut.lvds_dynamic_delay_inst.state;
    end
    last_cal = cal_done;
    prev_vs = vs;
    prev_de = de;
  end

  always @(posedge pclk) begin
    if (x == H_TOTAL-1) begin
      x <= 0;
      if (y == V_TOTAL-1) y <= 0;
      else y <= y + 1;
    end else x <= x + 1;
  end

  initial begin
    repeat (FRAME_CLOCKS) @(posedge pclk);
    #2;
    $display("SUMMARY frames=%0d DE_lines=%0d width[min,max]=[%0d,%0d] cal_rises=%0d cal_falls=%0d sync_fail=%0d bitslip_high_cycles=%0d final{cal=%b dpa=%0d align=%b lanes=%b%b%b bond=%b blue=%b green=%b red=%b deSync=%b rawBondCtrl={%b/%b/%b} iamrdy={%b/%b/%b} de={%b%b%b}",
             frames,de_lines,min_width,max_width,cal_rises,cal_falls,
             sync_fail_count,bit_slip_high_cycles,cal_done,
             dut.lvds_dynamic_delay_inst.state,align_success,r_align,g_align,
             b_align,bond_rdy,b_rdy,g_rdy,r_rdy,de_sync_pass,
             dut.u_tmds_decoder_0.u_channelbond.invalid,
             dut.u_tmds_decoder_1.u_channelbond.invalid,
             dut.u_tmds_decoder_2.u_channelbond.invalid,
             dut.u_tmds_decoder_0.u_channelbond.iamrdy,
             dut.u_tmds_decoder_1.u_channelbond.iamrdy,
             dut.u_tmds_decoder_2.u_channelbond.iamrdy,
             dut.de_b,dut.de_g,dut.de_r);
    $finish;
  end
endmodule
