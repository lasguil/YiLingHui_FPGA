`include "isp_params.vh"

// SC431HAI optical black from dark frame (65 LSB). No runtime port, no HS.
module isp_blc (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             in_vs,
    input  wire             in_de,
    input  wire [9:0]       in_raw,
    output reg              out_vs,
    output reg              out_de,
    output reg  [9:0]       out_raw
);
    wire [9:0] sub = (in_raw > `ISP_BLC) ? (in_raw - `ISP_BLC) : 10'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vs  <= 1'b0;
            out_de  <= 1'b0;
            out_raw <= 10'd0;
        end else begin
            out_vs  <= in_vs;
            out_de  <= in_de;
            out_raw <= in_de ? sub : 10'd0;
        end
    end
endmodule
