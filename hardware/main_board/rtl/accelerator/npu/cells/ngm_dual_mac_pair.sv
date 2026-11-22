// 一个双 INT8 乘法对：一颗 EFX_DSP48 的 DUAL 模式同时算两个 8x8 乘积，
// 再用 48 位级联通道把 6 对串成 12 项累加，避免在 XLR 里搭 12 输入加法树。
//
// 两条轨道（低/高）各自独立累加：每一对的 CASCOUT 把上一对的 48 位和送进
// 本对的 CASCIN，所以 6 对串完之后：
//   cascade_out[23:0]  = 低轨道 6 个乘积之和
//   cascade_out[47:24] = 高轨道 6 个乘积之和
//
// PIPE_EXTRA 给操作数补延迟，让每一对的操作数与它的级联和同拍对齐。
module ngm_dual_mac_pair #(
    parameter bit CASCADE_ACCUMULATE = 1'b0,
    parameter bit TERMINAL_PAIR      = 1'b0,
    parameter bit A_REG              = 1'b0,
    parameter bit B_REG              = 1'b0,
    parameter bit P_REG              = 1'b1,
    parameter bit W_REG              = 1'b0,
    parameter int unsigned PIPE_EXTRA = 0
) (
    input  logic               clk,
    input  logic signed [7:0]  act0,
    input  logic signed [7:0]  act1,
    input  logic signed [7:0]  weight0,
    input  logic signed [7:0]  weight1,
    input  logic        [47:0] cascade_in,
    output logic        [47:0] cascade_out
);
    logic [18:0] packed_a;
    logic [17:0] packed_b;
    logic [31:0] operand_bundle_in;
    logic [31:0] operand_bundle;

    assign operand_bundle_in = {act0, act1, weight0, weight1};

    if (PIPE_EXTRA == 0) begin : g_no_extra_pipe
        assign operand_bundle = operand_bundle_in;
    end else begin : g_extra_pipe
        logic [31:0] operand_pipe_q [0:PIPE_EXTRA-1];
        always_ff @(posedge clk) begin
            operand_pipe_q[0] <= operand_bundle_in;
            for (int pipe_index = 1; pipe_index < PIPE_EXTRA; pipe_index++)
                operand_pipe_q[pipe_index] <= operand_pipe_q[pipe_index-1];
        end
        assign operand_bundle = operand_pipe_q[PIPE_EXTRA-1];
    end

    // DUAL 模式：A 装两个 8 位激活，B 装两个 8 位权重
    assign packed_a = {{3{operand_bundle[23]}}, operand_bundle[23:16],
                       operand_bundle[31:24]};
    assign packed_b = {{2{operand_bundle[7]}}, operand_bundle[7:0],
                       operand_bundle[15:8]};

    if (TERMINAL_PAIR) begin : g_terminal_pair
        EFX_DSP48 #(
            .MODE       ("DUAL"),
            .A_REG      (A_REG),
            .B_REG      (B_REG),
            .C_REG      (0),
            .P_REG      (P_REG),
            .OP_REG     (0),
            .W_REG      (W_REG),
            .O_REG      (0),
            .SHIFTER    (0),
            .SIGNED     (1),
            .P_EXT      ("ALIGN_RIGHT"),
            .C_EXT      ("ALIGN_RIGHT"),
            .M_SEL      ("P"),
            .N_SEL      (CASCADE_ACCUMULATE ? "CASCIN" : "CONST0"),
            .W_SEL      ("X"),
            .CASCOUT_SEL("W")
        ) u_dsp48 (
            .A          (packed_a),
            .B          (packed_b),
            .C          (18'd0),
            .CASCIN     (cascade_in),
            .OP         (2'b00),
            .SHIFT_ENA  (1'b0),
            .CLK        (clk),
            .CE         (1'b1),
            .RST        (1'b0),
            .O          (cascade_out),
            .CASCOUT    (),
            .OVFL       ()
        );
    end else begin : g_cascade_pair
        EFX_DSP48 #(
            .MODE       ("DUAL"),
            .A_REG      (A_REG),
            .B_REG      (B_REG),
            .C_REG      (0),
            .P_REG      (P_REG),
            .OP_REG     (0),
            .W_REG      (W_REG),
            .O_REG      (0),
            .SHIFTER    (0),
            .SIGNED     (1),
            .P_EXT      ("ALIGN_RIGHT"),
            .C_EXT      ("ALIGN_RIGHT"),
            .M_SEL      ("P"),
            .N_SEL      (CASCADE_ACCUMULATE ? "CASCIN" : "CONST0"),
            .W_SEL      ("X"),
            .CASCOUT_SEL("W")
        ) u_dsp48 (
            .A          (packed_a),
            .B          (packed_b),
            .C          (18'd0),
            .CASCIN     (cascade_in),
            .OP         (2'b00),
            .SHIFT_ENA  (1'b0),
            .CLK        (clk),
            .CE         (1'b1),
            .RST        (1'b0),
            .O          (),
            .CASCOUT    (cascade_out),
            .OVFL       ()
        );
    end
endmodule
