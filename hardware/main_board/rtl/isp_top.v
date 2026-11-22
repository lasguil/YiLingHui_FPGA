`include "isp_params.vh"

// Pixel-order trial: physical BGGR -> sRGB.
// Map the window phase into the existing GBRG interpolator below:
// BLC=65 -> 3x3 window -> edge-directed demosaic -> CCM -> Gamma.
// Fixed white balance is folded into CCM; no separate WB stages.
module isp_top #(
    parameter WIDTH  = `ISP_WIDTH,
    parameter HEIGHT = `ISP_HEIGHT
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_vs,
    input  wire        in_de,
    input  wire [9:0]  in_raw,
    input wire [1:0] mode,
    input wire        bayer_y_xor,
    output reg [1:0] mode_hold,

    output wire        out_vs,
    output wire        out_de,
    output wire [7:0]  out_r,
    output wire [7:0]  out_g,
    output wire [7:0]  out_b,
    output wire        win_keep,
    output wire [10:0] raw_x,
    output wire [10:0] raw_y,
    output wire        raw_y0
);
    wire [10:0] x0, y0;
    reg mode_vs_d;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin mode_vs_d<=0;mode_hold<=2'd1;end
        else begin
            mode_vs_d<=in_vs;
            if(in_vs && !mode_vs_d)mode_hold<=mode;
        end
    end
    assign raw_x = x0;
    assign raw_y0 = y0[0];
    assign raw_y = y0;

    isp_coord #(.WIDTH(WIDTH)) u_coord (
        .clk     (clk),
        .rst_n   (rst_n),
        .in_vs   (in_vs),
        .in_de   (in_de),
        .x       (x0),
        .y       (y0),
        .vs_rise ()
    );

    wire        vs1, de1;
    wire [9:0]  raw1;

    isp_blc u_blc (
        .clk     (clk),
        .rst_n   (rst_n),
        .in_vs   (in_vs),
        .in_de   (in_de),
        .in_raw  (in_raw),
        .out_vs  (vs1),
        .out_de  (de1),
        .out_raw (raw1)
    );

    // Match the line-RAM coordinates to the one-cycle BLC latency.
    reg [10:0] x_d1, y_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_d1 <= 11'd0;
            y_d1 <= 11'd0;
        end else begin
            x_d1 <= x0;
            y_d1 <= y0;
        end
    end

    wire        vs3, de3;
    wire [10:0] x3, y3;
    wire [9:0]  win_nw, win_n, win_ne;
    wire [9:0]  win_w,  win_c, win_e;
    wire [9:0]  win_sw, win_s, win_se;

    isp_window3 #(.WIDTH(WIDTH), .HEIGHT(HEIGHT)) u_win (
        .clk    (clk),
        .rst_n  (rst_n),
        .in_vs  (vs1),
        .in_de  (de1),
        .in_pix (raw1),
        .in_x   (x_d1),
        .in_y   (y_d1),
        .out_vs (vs3),
        .out_de (de3),
        .out_x  (x3),
        .out_y  (y3),
        .nw(win_nw), .n(win_n), .ne(win_ne),
        .w (win_w),  .c(win_c), .e (win_e),
        .sw(win_sw), .s(win_s), .se(win_se)
    );

    wire        vs5, de5;
    wire [9:0]  rgb_r, rgb_g, rgb_b;

    assign win_keep = ^{win_nw, win_n, win_ne,
                        win_w,  win_c, win_e,
                        win_sw, win_s, win_se};

    // RAW coordinates now start at physical sensor row 0 for every VS lead.
    // Window metadata is one column ahead of its center; its y is the
    // actual center row. Map physical BGGR into the GBRG interpolator.
    isp_demosaic_3x3 u_debayer (
        .clk    (clk),
        .rst_n  (rst_n),
        .in_vs  (vs3),
        .in_de  (de3),
        .in_x0  (x3[0]),
        .in_y0  (y3[0] ^ bayer_y_xor),
        .nw(win_nw), .n(win_n), .ne(win_ne),
        .w (win_w),  .c(win_c), .e (win_e),
        .sw(win_sw), .s(win_s), .se(win_se),
        .out_vs (vs5),
        .out_de (de5),
        .out_r  (rgb_r),
        .out_g  (rgb_g),
        .out_b  (rgb_b)
    );

    // out_x==0 is one sample ahead of the center pixel, so its Bayer phase
    // is wrong and CCM turns that gray into a purple/red column. Hold the
    // demosaic result one cycle and, for that column only, use the next
    // pixel. The next pixel is the same sensor sample with a mirrored
    // west neighbor. Line length stays 1920.
    reg        q_vs, q_de;
    reg [10:0] x3_d, q_x;
    reg [9:0]  q_r, q_g, q_b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x3_d <= 11'd0;
            q_vs <= 1'b0;
            q_de <= 1'b0;
            q_x  <= 11'd0;
            q_r  <= 10'd0;
            q_g  <= 10'd0;
            q_b  <= 10'd0;
        end else begin
            x3_d <= x3;
            q_vs <= vs5;
            q_de <= de5;
            q_x  <= x3_d;
            q_r  <= rgb_r;
            q_g  <= rgb_g;
            q_b  <= rgb_b;
        end
    end

    wire        left_fix = q_de && (q_x == 11'd0) && de5;
    wire [9:0]  edge_r = left_fix ? rgb_r : q_r;
    wire [9:0]  edge_g = left_fix ? rgb_g : q_g;
    wire [9:0]  edge_b = left_fix ? rgb_b : q_b;

    wire resized_vs,resized_de;
    wire [29:0] resized_rgb;
    isp_hfilter_resize #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_resize (
        .clk(clk),.rst_n(rst_n),.mode(mode_hold),
        .in_vs(q_vs),.in_de(q_de),.in_rgb({edge_r,edge_g,edge_b}),
        .out_vs(resized_vs),.out_de(resized_de),.out_rgb(resized_rgb)
    );
    wire        vs6, de6;
    wire [9:0]  ccm_r, ccm_g, ccm_b;

    isp_ccm u_ccm (
        .clk    (clk),
        .rst_n  (rst_n),
        .in_vs  (resized_vs),
        .in_de  (resized_de),
        .in_r   (resized_rgb[29:20]),
        .in_g   (resized_rgb[19:10]),
        .in_b   (resized_rgb[9:0]),
        .out_vs (vs6),
        .out_de (de6),
        .out_r  (ccm_r),
        .out_g  (ccm_g),
        .out_b  (ccm_b)
    );

    wire        vs_g, de_g;
    wire [7:0]  g_r, g_g, g_b;

    isp_gamma u_gamma (
        .clk    (clk),
        .rst_n  (rst_n),
        .in_vs  (vs6),
        .in_de  (de6),
        .in_r   (ccm_r),
        .in_g   (ccm_g),
        .in_b   (ccm_b),
        .out_vs (vs_g),
        .out_de (de_g),
        .out_r  (g_r),
        .out_g  (g_g),
        .out_b  (g_b)
    );

    // Unity saturation was redundant. Remove its register with matching
    // pixel/control latency: Gamma now directly drives the ISP outputs.
    assign out_vs = vs_g;
    assign out_de = de_g;
    assign out_r  = g_r;
    assign out_g  = g_g;
    assign out_b  = g_b;

endmodule
