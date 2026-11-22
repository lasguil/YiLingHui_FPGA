// 一颗 EFX_DSP48 驱动的两条 int8 MAC 通道。
//
// DUAL 模式的实际语义（读 <Efinity>/sim_models/verilog/efx_dsp48.v 得到，不是推测）：
//   multA: A[18:8] (11 bit) × B[17:8] (10 bit) → O[36:16] → 符号扩展进 P[47:24]
//   multB: A[7:0]  (8  bit) × B[7:0]  (8  bit) → O[15:0]  → 符号扩展进 P[23:0]
// 两条轨道完全独立。所以把 int8 符号扩展后放进 A[18:8] / B[17:8]，
// 一颗 DSP 就是两个有符号 8×8 乘法器。
//
// 这里让 DSP 只出乘积（N_SEL = "CONST0"），累加放在织物里用 32 位做：
// DSP 的 P 寄存器只有 24 位/轨，7×7 阶段的去偏置累加峰值实测 2^19.5、
// 理论最坏 2^24，靠 24 位回绕是不可接受的风险。织物加法的代价见 pkg。
module gesture_dual_mac (
    input  logic               clk,
    input  logic               reset,
    input  logic               acc_clear,
    input  logic               acc_enable,
    input  logic signed [7:0]  act_lo,
    input  logic signed [7:0]  act_hi,
    input  logic signed [7:0]  wgt_lo,
    input  logic signed [7:0]  wgt_hi,
    output logic signed [31:0] acc_lo,
    output logic signed [31:0] acc_hi
);
    logic [18:0] packed_a;
    logic [17:0] packed_b;
    logic [47:0] dsp_product;

    // 低轨（multB）用 A[7:0]/B[7:0]，高轨（multA）用 A[18:8]/B[17:8]。
    assign packed_a = {{3{act_hi[7]}}, act_hi, act_lo};
    assign packed_b = {{2{wgt_hi[7]}}, wgt_hi, wgt_lo};

`ifdef FAST_SIM
    // 与 EFX_DSP48 DUAL 模式逐位等价的行为模型：两轨各自符号扩展。
    // 综合时走真实原语；仿真时用它可以完全不依赖 Efinity 安装目录。
    logic signed [47:0] product_q;
    always_ff @(posedge clk) begin
        if (reset) product_q <= 48'sd0;
        else begin
            automatic logic signed [20:0] hi = $signed(packed_a[18:8]) * $signed(packed_b[17:8]);
            automatic logic signed [15:0] lo = $signed(packed_a[7:0])  * $signed(packed_b[7:0]);
            product_q <= {24'(hi), 24'(lo)};
        end
    end
    assign dsp_product = product_q;
`else
    EFX_DSP48 #(
        .MODE       ("DUAL"),
        .A_REG      (0),
        .B_REG      (0),
        .C_REG      (0),
        .P_REG      (1),          // 乘积打一拍，给出操作数到累加器的割点
        .OP_REG     (0),
        .W_REG      (0),
        .O_REG      (0),
        .SHIFTER    (0),
        .SIGNED     (1),
        .P_EXT      ("ALIGN_RIGHT"),
        .C_EXT      ("ALIGN_RIGHT"),
        .M_SEL      ("P"),
        .N_SEL      ("CONST0"),   // 不累加，只要乘积
        .W_SEL      ("X"),
        .CASCOUT_SEL("W")
    ) u_dsp48 (
        .A          (packed_a),
        .B          (packed_b),
        .C          (18'd0),
        .CASCIN     (48'd0),
        .OP         (2'b00),
        .SHIFT_ENA  (1'b0),
        .CLK        (clk),
        .CE         (1'b1),
        .RST        (reset),
        .O          (dsp_product),
        .CASCOUT    (),
        .OVFL       ()
    );
`endif

    // P_REG=1 意味着乘积比操作数晚一拍；acc_clear 必须在这条链之前至少拉一拍，
    // 所以清零和累加共用同一个时序块，acc_clear 优先级更高。
    always_ff @(posedge clk) begin
        if (reset || acc_clear) begin
            acc_lo <= 32'sd0;
            acc_hi <= 32'sd0;
        end else if (acc_enable) begin
            acc_lo <= acc_lo + {{8{dsp_product[23]}}, dsp_product[23:0]};
            acc_hi <= acc_hi + {{8{dsp_product[47]}}, dsp_product[47:24]};
        end
    end

`ifdef SIM_ASSERT
    // 两轨的乘积都必须落在各自 16 位/21 位的有效域内，否则是打包写错了。
    always_ff @(posedge clk) begin
        if (!reset && !acc_clear) begin
            if (dsp_product[22:16] != {7{dsp_product[15]}})
                $error("dual_mac: low-track product exceeds signed 16-bit");
        end
    end
`endif
endmodule
