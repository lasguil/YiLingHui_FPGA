`timescale 1ns/1ps
module tb_phasealign_hdmi_lines;
  localparam integer ACTIVE = 1920;
  localparam integer LINE = 2200;
  localparam integer START_WORD = ACTIVE + 50;
  localparam integer RUN_CYCLES = 120000;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg re_start = 0;
  reg [9:0] raw_word = 0;
  wire [9:0] sliced;
  wire align_fail, sync_code, pos_sync, bitslip, aligned;
  frame_bitslip fb(.clk(clk), .rst_n(rst_n), .bitslip(bitslip),
                   .data_in(raw_word), .data_out(sliced), .align_fail(align_fail));
  phasealign_v1 #(.kTimeoutBit(12), .kAlignedBit(12), .kAlignWaitBit(11)) pa(
    .clk(clk), .rst_n(rst_n), .vin(sliced), .re_algin_start(re_start),
    .sync_code(sync_code), .pos_sync_code(pos_sync), .bitslip(bitslip), .aligned(aligned));

  integer offset, cycle, j, bit_pos, word_idx, shift, symbol;
  integer pulse_run, max_pulse, changes, last_switch, valid_tokens;
  reg [3:0] final_switch;

  function automatic [9:0] source_word(input integer wi);
    integer x;
    begin
      x = wi % LINE;
      source_word = (x >= ACTIVE) ? 10'h354 : 10'h155;
    end
  endfunction

  function automatic [9:0] serial_window(input integer cyc, input integer off);
    integer k, p, wi;
    reg [9:0] result, sym;
    begin
      result = 10'd0;
      for (k=0; k<10; k=k+1) begin
        p = (cyc + START_WORD)*10 + off + k;
        wi = p / 10;
        sym = source_word(wi);
        result[k] = sym[p % 10];
      end
      serial_window = result;
    end
  endfunction

  task automatic check(input logic ok, input string msg);
    if (!ok) begin $error("FAIL: %s", msg); $fatal(1); end
  endtask

  initial begin
    for (offset=0; offset<10; offset=offset+1) begin
      rst_n = 0; re_start = 0; raw_word = 0;
      pulse_run = 0; max_pulse = 0; changes = 0; valid_tokens = 0;
      final_switch = 0; last_switch = 0;
      repeat(8) @(negedge clk);
      rst_n = 1;
      @(negedge clk); re_start = 1;
      @(negedge clk); re_start = 0;
      for (cycle=0; cycle<RUN_CYCLES; cycle=cycle+1) begin
        raw_word = serial_window(cycle, offset);
        @(posedge clk);
        if (pa.bitslip1) begin
          pulse_run = pulse_run + 1;
          if (pulse_run > max_pulse) max_pulse = pulse_run;
        end else pulse_run = 0;
        if (fb.Output_switch != last_switch) begin
          changes = changes + 1;
          last_switch = fb.Output_switch;
        end
        if (cycle >= RUN_CYCLES-2*LINE && (sliced == 10'h354))
          valid_tokens = valid_tokens + 1;
        if (cycle == RUN_CYCLES-2*LINE) final_switch = fb.Output_switch;
        @(negedge clk);
      end
      $display("DEBUG offset=%0d aligned=%b aligned1=%b cnt=%0d state=%0d timer=%0d switch=%0d bitslip=%b",
               offset, aligned, pa.aligned1, pa.align_cnt, pa.state, pa.timeout_cnt,
               fb.Output_switch, bitslip);
      check(aligned, $sformatf("offset %0d did not reach align timeout", offset));
      check(valid_tokens >= 2*280-4,
            $sformatf("offset %0d final blank had only %0d exact CTL0 symbols", offset, valid_tokens));
      check(fb.Output_switch == final_switch,
            $sformatf("offset %0d switch changed after final sample", offset));
      $display("OFFSET=%0d final_switch=%0d changes=%0d exact_ctl0=%0d max_bitslip1=%0d aligned=%0b",
               offset, final_switch, changes, valid_tokens, max_pulse, aligned);
    end
    $display("PASS all 10 TMDS serial word offsets recover 1080p control boundaries");
    $finish;
  end
endmodule
