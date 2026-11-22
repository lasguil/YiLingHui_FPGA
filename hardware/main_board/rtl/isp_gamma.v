`include "isp_params.vh"

// 10-bit linear RGB -> 8-bit sRGB. Three LUT copies so each channel is a 1R RAM.
module isp_gamma (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vs,
    input  wire        in_de,
    input  wire [9:0]  in_r,
    input  wire [9:0]  in_g,
    input  wire [9:0]  in_b,
    output reg         out_vs,
    output reg         out_de,
    output reg  [7:0]  out_r,
    output reg  [7:0]  out_g,
    output reg  [7:0]  out_b
);
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [7:0] lut_r [0:1023];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [7:0] lut_g [0:1023];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [7:0] lut_b [0:1023];

    initial begin
        $readmemh("gamma_srgb_10to8.hex", lut_r);
        $readmemh("gamma_srgb_10to8.hex", lut_g);
        $readmemh("gamma_srgb_10to8.hex", lut_b);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vs <= 1'b0;
            out_de <= 1'b0;
            out_r  <= 8'd0;
            out_g  <= 8'd0;
            out_b  <= 8'd0;
        end else begin
            out_vs <= in_vs;
            out_de <= in_de;
            out_r  <= lut_r[in_r];
            out_g  <= lut_g[in_g];
            out_b  <= lut_b[in_b];
        end
    end
endmodule
