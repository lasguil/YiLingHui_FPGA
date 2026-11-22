`include "isp_params.vh"
`include "isp_clip.vh"

// 3x3 CCM, Q8, signed saturating.
// Python in the handoff: srgb = encode( (linear * wb) @ ccm )
// FPGA 10-bit after WB is that linear*wb * 1023, so
//   out10 = clip10( (r*c0 + g*c1 + b*c2) >>> 8 )
// Keep products/accumulators signed and wide. Saturate to 0..1023 before
// narrowing; the noise-aware unity-path fit includes this exact clamp and
// sensor-clipped white anchors. White balance is folded into coefficients.
module isp_ccm (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vs,
    input  wire        in_de,
    input  wire [9:0]  in_r,
    input  wire [9:0]  in_g,
    input  wire [9:0]  in_b,
    output reg         out_vs,
    output reg         out_de,
    output reg  [9:0]  out_r,
    output reg  [9:0]  out_g,
    output reg  [9:0]  out_b
);
    wire signed [11:0] sr = $signed({2'b0, in_r});
    wire signed [11:0] sg = $signed({2'b0, in_g});
    wire signed [11:0] sb = $signed({2'b0, in_b});

    wire signed [13:0] c00 = `ISP_CCM00;
    wire signed [13:0] c01 = `ISP_CCM01;
    wire signed [13:0] c02 = `ISP_CCM02;
    wire signed [13:0] c10 = `ISP_CCM10;
    wire signed [13:0] c11 = `ISP_CCM11;
    wire signed [13:0] c12 = `ISP_CCM12;
    wire signed [13:0] c20 = `ISP_CCM20;
    wire signed [13:0] c21 = `ISP_CCM21;
    wire signed [13:0] c22 = `ISP_CCM22;

    wire signed [25:0] pr0 = sr * c00;
    wire signed [25:0] pg0 = sg * c10;
    wire signed [25:0] pb0 = sb * c20;
    wire signed [25:0] pr1 = sr * c01;
    wire signed [25:0] pg1 = sg * c11;
    wire signed [25:0] pb1 = sb * c21;
    wire signed [25:0] pr2 = sr * c02;
    wire signed [25:0] pg2 = sg * c12;
    wire signed [25:0] pb2 = sb * c22;

    wire signed [31:0] acc_r = {{6{pr0[25]}}, pr0} + {{6{pg0[25]}}, pg0} + {{6{pb0[25]}}, pb0};
    wire signed [31:0] acc_g = {{6{pr1[25]}}, pr1} + {{6{pg1[25]}}, pg1} + {{6{pb1[25]}}, pb1};
    wire signed [31:0] acc_b = {{6{pr2[25]}}, pr2} + {{6{pg2[25]}}, pg2} + {{6{pb2[25]}}, pb2};

    wire [9:0] r_c = isp_clip10(acc_r >>> 8);
    wire [9:0] g_c = isp_clip10(acc_g >>> 8);
    wire [9:0] b_c = isp_clip10(acc_b >>> 8);

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
            out_r  <= in_de ? r_c : 10'd0;
            out_g  <= in_de ? g_c : 10'd0;
            out_b  <= in_de ? b_c : 10'd0;
        end
    end
endmodule
