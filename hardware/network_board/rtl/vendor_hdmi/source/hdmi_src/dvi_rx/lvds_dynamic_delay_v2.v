module lvds_dynamic_delay(
input clk,
input rst_n,
input align_fail,
input align_success,
output reg cal_done,
output reg de_sync_check_en,
input de_sync_pass,
input de_sync_fail,
input debug_pos,
output reg [31:0] good_mask,
output reg [15:0] best_count,
output reg [5:0] best_code,
output DLY_INC,
output DLY_RST,
output DLY_ENA,
output reg re_algin_start,
output reg pll_rst_n
);

localparam S_IDLE         = 4'd0;
localparam S_START        = 4'd1;
localparam S_DELAY        = 4'd2;
localparam S_ALIGN_CHECK  = 4'd3;
localparam S_DE_SYNC_CHECK= 4'd4;
localparam S_STEP         = 4'd5;
localparam S_RESTART      = 4'd6;
localparam S_SCAN_END     = 4'd7;
localparam S_CALC_MID     = 4'd8;
localparam S_FINAL_PASS   = 4'd9;
localparam S_FINAL_FAIL   = 4'd10;
localparam S_PLL_RESET    = 4'd11;

reg [3:0] state = S_IDLE;
reg [5:0] dly_data = 6'd0;
reg dly_ena = 1'b0;
reg [5:0] first_good = 6'd0;
reg [5:0] last_good = 6'd0;
reg have_good = 1'b0;
reg final_verify = 1'b0;
reg [15:0] settle_cnt = 16'd0;
reg [15:0] pos_cnt = 16'd0;
reg r_pll_rst_n = 1'b1;

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    state <= S_IDLE;
    cal_done <= 1'b0;
    de_sync_check_en <= 1'b0;
    re_algin_start <= 1'b0;
    pll_rst_n <= 1'b1;
    r_pll_rst_n <= 1'b1;
    dly_data <= 6'd0;
    dly_ena <= 1'b0;
    first_good <= 6'd0;
    last_good <= 6'd0;
    have_good <= 1'b0;
    final_verify <= 1'b0;
    settle_cnt <= 16'd0;
    pos_cnt <= 16'd0;
    good_mask <= 32'd0;
    best_count <= 16'd0;
    best_code <= 6'd0;
  end else begin
    de_sync_check_en <= 1'b0;
    re_algin_start <= 1'b0;
    r_pll_rst_n <= 1'b1;
    pll_rst_n <= r_pll_rst_n;
    dly_ena <= 1'b0;

    case (state)
      S_IDLE: begin
        if (!cal_done || align_fail || de_sync_fail) begin
          state <= S_START;
          cal_done <= 1'b0;
        end
      end

      // Begin a full 0..31 code scan; each code is visited exactly once.
      S_START: begin
        dly_data <= 6'd0;
        dly_ena <= 1'b1;
        first_good <= 6'd0;
        last_good <= 6'd0;
        have_good <= 1'b0;
        final_verify <= 1'b0;
        settle_cnt <= 16'd0;
        pos_cnt <= 16'd0;
        good_mask <= 32'd0;
        best_count <= 16'd0;
        best_code <= 6'd0;
        cal_done <= 1'b0;
        re_algin_start <= 1'b1;
        state <= S_DELAY;
      end

      // Measurement window for the red lane's control-token pulses. The
      // 32-bit mask records every clock-delay code where red saw a token.
      S_DELAY: begin
        if (debug_pos) pos_cnt <= pos_cnt + 1'b1;
        if (settle_cnt[15]) begin
          if (pos_cnt != 16'd0) good_mask[dly_data] <= 1'b1;
          if (pos_cnt > best_count) begin
            best_count <= pos_cnt;
            best_code <= dly_data;
          end
          settle_cnt <= 16'd0;
          pos_cnt <= 16'd0;
          state <= S_ALIGN_CHECK;
        end else begin
          settle_cnt <= settle_cnt + 1'b1;
        end
      end

      S_ALIGN_CHECK: begin
        if (final_verify) begin
          if (align_success) state <= S_DE_SYNC_CHECK;
          else if (align_fail) state <= S_FINAL_FAIL;
        end else if (align_success) begin
          state <= S_DE_SYNC_CHECK;
        end else if (align_fail) begin
          if (have_good || dly_data == 6'd31) state <= S_SCAN_END;
          else state <= S_STEP;
        end
      end

      S_DE_SYNC_CHECK: begin
        de_sync_check_en <= 1'b1;
        if (de_sync_pass) begin
          if (final_verify) begin
            state <= S_FINAL_PASS;
          end else if (dly_data == 6'd31) begin
            state <= S_SCAN_END;
          end else begin
            state <= S_STEP;
          end
        end else if (de_sync_fail) begin
          if (final_verify) begin
            state <= S_FINAL_FAIL;
          end else if (have_good || dly_data == 6'd31) begin
            state <= S_SCAN_END;
          end else begin
            state <= S_STEP;
          end
        end
      end

      S_STEP: begin
        // The tested code was rejected. Advance by one, never skip taps.
        dly_data <= dly_data + 1'b1;
        dly_ena <= 1'b1;
        state <= S_RESTART;
      end

      S_RESTART: begin
        re_algin_start <= 1'b1;
        settle_cnt <= 16'd0;
        pos_cnt <= 16'd0;
        state <= S_DELAY;
      end

      S_SCAN_END: begin
        if (have_good) state <= S_CALC_MID;
        else state <= S_PLL_RESET;
      end

      S_CALC_MID: begin
        // Boundaries are measured passing codes, not an estimate from fail.
        dly_data <= ({1'b0, first_good} + {1'b0, last_good}) >> 1;
        dly_ena <= 1'b1;
        final_verify <= 1'b1;
        cal_done <= 1'b0;
        state <= S_RESTART;
      end

      S_FINAL_PASS: begin
        // Publish calibration only after midpoint alignment and DE recheck.
        final_verify <= 1'b0;
        cal_done <= 1'b1;
        state <= S_IDLE;
      end

      S_FINAL_FAIL: begin
        // Never report success for a midpoint that failed either check.
        final_verify <= 1'b0;
        cal_done <= 1'b0;
        have_good <= 1'b0;
        dly_data <= 6'd0;
        dly_ena <= 1'b1;
        settle_cnt <= 16'd0;
        re_algin_start <= 1'b1;
        state <= S_DELAY;
      end

      S_PLL_RESET: begin
        r_pll_rst_n <= 1'b0;
        cal_done <= 1'b0;
        have_good <= 1'b0;
        state <= S_IDLE;
      end

      default: state <= S_IDLE;
    endcase

    // Record only taps which passed both alignment and DE synchronization.
    if (state == S_DE_SYNC_CHECK && de_sync_pass && !final_verify) begin
      if (!have_good) first_good <= dly_data;
      last_good <= dly_data;
      have_good <= 1'b1;
    end
  end
end

wire dly_inc = 1'b0;
wire [4:0] dly_d = ~dly_data[4:0];
dyn_delay dyn_delay_inst (
  .clk(clk),
  .rst_n(rst_n),
  .dyn_en(dly_ena),
  .dly_d({1'b0,dly_d}),
  .dly_inc(dly_inc),
  .mode(1'b0),
  .dyn_rst(DLY_RST),
  .dyn_inc(DLY_INC),
  .dyn_ena(DLY_ENA),
  .dly_cnt(),
  .cal_busy()
);

endmodule
