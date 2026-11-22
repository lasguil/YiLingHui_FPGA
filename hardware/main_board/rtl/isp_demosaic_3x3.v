`include "isp_params.vh"

// 3x3 demosaic, SC431HAI GBRG only.
// Green at R/B sites follows the smoother neighbor pair so a flat
// average does not leave a one-pixel vertical zipper.
module isp_demosaic_3x3 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vs,
    input  wire        in_de,
    input  wire        in_x0,
    input  wire        in_y0,
    input  wire [9:0]  nw, n, ne,
    input  wire [9:0]  w,  c, e,
    input  wire [9:0]  sw, s, se,
    output reg         out_vs,
    output reg         out_de,
    output reg  [9:0]  out_r,
    output reg  [9:0]  out_g,
    output reg  [9:0]  out_b
);
    wire is_g_gb = ~in_y0 & ~in_x0;
    wire is_b    = ~in_y0 &  in_x0;
    wire is_r    =  in_y0 & ~in_x0;
    wire is_g_rg =  in_y0 &  in_x0;

    wire [11:0] g4 = {2'b0, n} + {2'b0, s} + {2'b0, w} + {2'b0, e};
    wire [11:0] d4 = {2'b0, nw} + {2'b0, ne} + {2'b0, sw} + {2'b0, se};
    wire [10:0] h2 = {1'b0, w} + {1'b0, e};
    wire [10:0] v2 = {1'b0, n} + {1'b0, s};

    wire [9:0] g_rb = g4[11:2];
    wire [9:0] diag = d4[11:2];
    wire [9:0] hor  = h2[10:1];
    wire [9:0] ver  = v2[10:1];

    wire [9:0] dw = (w > e) ? (w - e) : (e - w);
    wire [9:0] dh = (n > s) ? (n - s) : (s - n);
    wire [10:0] dw_b = {1'b0, dw} + 11'd16;
    wire [10:0] dh_b = {1'b0, dh} + 11'd16;
    wire        hor_g = dw_b < {1'b0, dh};
    wire        ver_g = dh_b < {1'b0, dw};
    wire [9:0]  g_dir = hor_g ? hor : (ver_g ? ver : g_rb);

    wire [9:0] r_pix = is_r ? c : (is_g_gb ? ver : (is_b ? diag : hor));
    wire [9:0] g_sel = (is_g_gb | is_g_rg) ? c : g_dir;
    wire [9:0] b_pix = is_b ? c : (is_g_gb ? hor : (is_r ? diag : ver));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vs <= 1'b0;
            out_de <= 1'b0;
            out_r  <= 10'd0;
            out_g  <= 10'd0;
            out_b  <= 10'd0;
        end else begin
            out_vs <= in_vs;
            out_de <= in_de;
            out_r  <= r_pix;
            out_g  <= g_sel;
            out_b  <= b_pix;
        end
    end
endmodule
