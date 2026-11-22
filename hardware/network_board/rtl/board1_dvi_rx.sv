`timescale 1ns/1ps

// Fixed-mode DVI receiver and symbol-preserving repeater. The three RX lanes
// are word-aligned and channel-bonded before they reach both the monitor and
// TX pins. No HDMI auxiliary packet parsing or TMDS re-encoding is used.
module board1_dvi_rx #(
    parameter PA_TIMEOUT_BIT = 20,
    parameter PA_ALIGNED_BIT = 20,
    parameter PA_ALIGN_WAIT_BIT = 19
) (
    input  wire        pclk,
    input  wire        pll_locked,
    input  wire [9:0]  rx_blue,
    input  wire [9:0]  rx_green,
    input  wire [9:0]  rx_red,
    output reg  [9:0]  tx_blue,
    output reg  [9:0]  tx_green,
    output reg  [9:0]  tx_red,
    output reg         hsync,
    output reg         vsync,
    output reg         de,
    output reg  [7:0]  red,
    output reg  [7:0]  green,
    output reg  [7:0]  blue,
    output wire        rx_dly_inc,
    output wire        rx_dly_rst,
    output wire        rx_dly_ena,
    output wire        debug_cal_done,
    output wire        debug_align_success,
    output wire        debug_de_sync_pass,
    output wire        debug_all_align,
    output wire        debug_bond_ready,
    output wire        debug_blue_ready,
    output wire        debug_green_ready,
    output wire        debug_red_ready,
    output wire        debug_b_align,
    output wire        debug_g_align,
    output wire        debug_r_align,
    output wire        debug_pass_open
);
    reg [12:0] rst_cnt = 13'd0;
    always @(posedge pclk or negedge pll_locked) begin
        if (!pll_locked) rst_cnt <= 13'd0;
        else if (!rst_cnt[12]) rst_cnt <= rst_cnt + 1'b1;
    end
    wire rst_n = rst_cnt[12];

    wire [9:0] b_word, g_word, r_word;
    wire b_align, g_align, r_align;
    wire b_align_fail, g_align_fail, r_align_fail;
    wire b_sync, g_sync, r_sync;
    wire b_sync_pos, g_sync_pos, r_sync_pos;
    wire b_ready, g_ready, r_ready;
    wire b_bond_ready, g_bond_ready, r_bond_ready;
    wire [9:0] b_bond_data, g_bond_data, r_bond_data;
    wire re_channelbond;
    wire cal_done;
    wire b_bitslip, g_bitslip, r_bitslip;
    wire re_algin_start;
    reg all_align = 1'b0;

    frame_bitslip u_b_bitslip(
        .clk(pclk), .rst_n(rst_n), .bitslip(b_bitslip), .data_in(rx_blue),
        .data_out(b_word), .align_fail(b_align_fail)
    );
    frame_bitslip u_g_bitslip(
        .clk(pclk), .rst_n(rst_n), .bitslip(g_bitslip), .data_in(rx_green),
        .data_out(g_word), .align_fail(g_align_fail)
    );
    frame_bitslip u_r_bitslip(
        .clk(pclk), .rst_n(rst_n), .bitslip(r_bitslip), .data_in(rx_red),
        .data_out(r_word), .align_fail(r_align_fail)
    );

    phasealign_v1 #(
        .kTimeoutBit(PA_TIMEOUT_BIT), .kAlignedBit(PA_ALIGNED_BIT),
        .kAlignWaitBit(PA_ALIGN_WAIT_BIT)
    ) u_b_phasealign(
        .clk(pclk), .rst_n(rst_n), .vin(b_word),
        .re_algin_start(re_algin_start), .sync_code(b_sync),
        .pos_sync_code(b_sync_pos), .bitslip(b_bitslip), .aligned(b_align)
    );
    phasealign_v1 #(
        .kTimeoutBit(PA_TIMEOUT_BIT), .kAlignedBit(PA_ALIGNED_BIT),
        .kAlignWaitBit(PA_ALIGN_WAIT_BIT)
    ) u_g_phasealign(
        .clk(pclk), .rst_n(rst_n), .vin(g_word),
        .re_algin_start(re_algin_start), .sync_code(g_sync),
        .pos_sync_code(g_sync_pos), .bitslip(g_bitslip), .aligned(g_align)
    );
    phasealign_v1 #(
        .kTimeoutBit(PA_TIMEOUT_BIT), .kAlignedBit(PA_ALIGNED_BIT),
        .kAlignWaitBit(PA_ALIGN_WAIT_BIT)
    ) u_r_phasealign(
        .clk(pclk), .rst_n(rst_n), .vin(r_word),
        .re_algin_start(re_algin_start), .sync_code(r_sync),
        .pos_sync_code(r_sync_pos), .bitslip(r_bitslip), .aligned(r_align)
    );

    channelbond u_b_bond(
        .clk(pclk), .rst_n(rst_n), .i_data(b_word), .pos_sync_code(b_sync_pos),
        .align_flag0(all_align && !re_channelbond),
        .other_ch0_rdy(g_ready), .other_ch1_rdy(r_ready),
        .iamrdy(b_ready), .bond_rdy(b_bond_ready), .sdata(b_bond_data)
    );
    channelbond u_g_bond(
        .clk(pclk), .rst_n(rst_n), .i_data(g_word), .pos_sync_code(g_sync_pos),
        .align_flag0(all_align && !re_channelbond),
        .other_ch0_rdy(b_ready), .other_ch1_rdy(r_ready),
        .iamrdy(g_ready), .bond_rdy(g_bond_ready), .sdata(g_bond_data)
    );
    channelbond u_r_bond(
        .clk(pclk), .rst_n(rst_n), .i_data(r_word), .pos_sync_code(r_sync_pos),
        .align_flag0(all_align && !re_channelbond),
        .other_ch0_rdy(b_ready), .other_ch1_rdy(g_ready),
        .iamrdy(r_ready), .bond_rdy(r_bond_ready), .sdata(r_bond_data)
    );

    always @(posedge pclk or negedge rst_n)
        if (!rst_n) all_align <= 1'b0;
        else        all_align <= b_align && g_align && r_align;

    channelboad_ctrl u_channelbond_ctrl(
        .clk(pclk), .rst_n(rst_n), .cal_done(cal_done),
        .sync1(r_sync), .sync2(g_sync), .sync3(b_sync),
        .re_sync(re_channelbond)
    );

    wire align_success = b_align && g_align && r_align;
    wire align_fail = b_align_fail || g_align_fail || r_align_fail;
    wire all_bond_ready = all_align && b_bond_ready && g_bond_ready && r_bond_ready;
    wire blue_ctl0 = b_bond_data == 10'h354;
    wire blue_ctl1 = b_bond_data == 10'h0ab;
    wire blue_ctl2 = b_bond_data == 10'h154;
    wire blue_ctl3 = b_bond_data == 10'h2ab;
    wire blue_control = blue_ctl0 || blue_ctl1 || blue_ctl2 || blue_ctl3;
    wire raw_video_de = all_bond_ready && !blue_control;

    wire de_sync_check_en;
    wire de_sync_pass, de_sync_fail;
    wire dpa_pll_rst_n_unused;
    wire [31:0] unused_good_mask;
    wire [15:0] unused_best_count;
    wire [5:0] unused_best_code;

    lvds_dynamic_delay u_clock_dpa(
        .clk(pclk), .rst_n(rst_n), .align_fail(align_fail),
        .align_success(align_success), .de_sync_check_en(de_sync_check_en),
        .de_sync_pass(de_sync_pass), .de_sync_fail(de_sync_fail),
        .debug_pos(r_sync_pos), .good_mask(unused_good_mask),
        .best_count(unused_best_count), .best_code(unused_best_code),
        .DLY_INC(rx_dly_inc), .DLY_RST(rx_dly_rst), .DLY_ENA(rx_dly_ena),
        .re_algin_start(re_algin_start), .pll_rst_n(dpa_pll_rst_n_unused),
        .cal_done(cal_done)
    );

    // DE for calibration comes directly from the bonded blue-lane control
    // symbols. It does not depend on cal_done or the auxiliary parser.
    de_sync u_de_sync(
        .clk(pclk), .rst_n(rst_n), .de_sync_en(de_sync_check_en),
        .cal_done(cal_done), .i_de(raw_video_de),
        .sync_fail(de_sync_fail), .sync_pass(de_sync_pass)
    );

    // Decode is only for the small timing monitor. The TX path below retains
    // the original bonded 10-bit symbols without a second encoder.
    function automatic [7:0] decode_tmds_byte(input [9:0] symbol);
        reg [7:0] payload;
        reg [7:0] value;
        integer i;
        begin
            payload = symbol[9] ? ~symbol[7:0] : symbol[7:0];
            value[0] = payload[0];
            for (i = 1; i < 8; i = i + 1)
                value[i] = payload[i] ^ payload[i-1] ^ !symbol[8];
            decode_tmds_byte = value;
        end
    endfunction

    reg tx_open = 1'b0;
    wire tx_pass = cal_done && all_bond_ready && (tx_open || blue_control);
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) tx_open <= 1'b0;
        else if (!cal_done || !all_bond_ready) tx_open <= 1'b0;
        else if (blue_control) tx_open <= 1'b1;
    end

    wire [1:0] token_hs_vs = blue_ctl0 ? 2'b00 : blue_ctl1 ? 2'b01 :
                             blue_ctl2 ? 2'b10 : 2'b11;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            hsync <= 1'b0; vsync <= 1'b0; de <= 1'b0;
            red <= 8'd0; green <= 8'd0; blue <= 8'd0;
            tx_blue <= 10'h354; tx_green <= 10'h354; tx_red <= 10'h354;
        end else begin
            if (tx_pass) begin
                tx_blue <= b_bond_data;
                tx_green <= g_bond_data;
                tx_red <= r_bond_data;
            end else begin
                tx_blue <= 10'h354;
                tx_green <= 10'h354;
                tx_red <= 10'h354;
            end

            de <= tx_pass && raw_video_de;
            if (tx_pass && blue_control) begin
                hsync <= token_hs_vs[0];
                vsync <= token_hs_vs[1];
            end else if (!tx_pass) begin
                hsync <= 1'b0;
                vsync <= 1'b0;
            end
            if (tx_pass && raw_video_de) begin
                blue <= decode_tmds_byte(b_bond_data);
                green <= decode_tmds_byte(g_bond_data);
                red <= decode_tmds_byte(r_bond_data);
            end
        end
    end

    assign debug_cal_done = cal_done;
    assign debug_align_success = align_success;
    assign debug_de_sync_pass = de_sync_pass;
    assign debug_all_align = all_align;
    assign debug_bond_ready = all_bond_ready;
    assign debug_blue_ready = b_bond_ready;
    assign debug_green_ready = g_bond_ready;
    assign debug_red_ready = r_bond_ready;
    assign debug_b_align = b_align;
    assign debug_g_align = g_align;
    assign debug_r_align = r_align;
    assign debug_pass_open = tx_pass;
endmodule
