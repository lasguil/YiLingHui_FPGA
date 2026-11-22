// 一颗 DSP 完成 RQ16 的 19x18 定标乘法。
//
// 【为什么不需要符号补偿】
// Ti60 EFX_DSP48 的 NORMAL 模式对 A/B 使用同一套 signed 设置，所以关键是让
// M18 在两种读法下取值相同。导出工具把 M18 归一化到 [2^16, 2^17)，
// **bit17 恒为 0**，所以字段只用 17 位（bit17 不携带信息）；送给 DSP 的 B 口
// 在最高位补常量 0，补出来的仍是同一个非负值，按 signed 读等于按 unsigned 读。
// value 保持 signed 19 位。于是 SIGNED(1) 的一颗 DSP 就直接算出 value × M18，
// 不再需要早期方案那条 37 位补偿加法器（那一版把 M18 归一化到 [2^17, 2^18)，
// bit17 恒为 1，按 signed 读是负数，必须再补 value × 2^18）。
//
// 尾数相对精度因此从 2^-18 降到 2^-17，对输出码值的贡献约 0.001 LSB，
// 远小于 INT8 自身 ±0.5 LSB 的舍入误差（主 Spec §50 的 2026-09-25 修订）。
//
// 延迟：P_REG = 1，所以 out_valid 与 product 都比输入晚一拍。
module ngm_rq16_mult (
    input  logic               clk,
    input  logic               reset,
    input  logic               in_valid,
    input  logic signed [18:0] value_s19,
    input  logic        [16:0] multiplier_m18,
    output logic               out_valid,
    output logic signed [36:0] product
);
    logic        [47:0] dsp_output;
    logic               valid_stage1;

    assign out_valid = valid_stage1;
    assign product   = $signed(dsp_output[36:0]);

    EFX_DSP48 #(
        .MODE       ("NORMAL"),
        .A_REG      (0),
        .B_REG      (0),
        .C_REG      (0),
        .P_REG      (1),
        .OP_REG     (0),
        .W_REG      (0),
        .O_REG      (0),
        .SHIFTER    (0),
        .SIGNED     (1),
        .P_EXT      ("ALIGN_RIGHT"),
        .C_EXT      ("ALIGN_RIGHT"),
        .M_SEL      ("P"),
        .N_SEL      ("CONST0"),
        .W_SEL      ("X")
    ) u_dsp48 (
        .A          (value_s19),
        .B          ({1'b0, multiplier_m18}),
        .C          (18'd0),
        .CASCIN     (48'd0),
        .OP         (2'b00),
        .SHIFT_ENA  (1'b0),
        .CLK        (clk),
        .CE         (1'b1),
        .RST        (reset),
        .O          (dsp_output),
        .CASCOUT    (),
        .OVFL       ()
    );

    always_ff @(posedge clk) begin
        if (reset) valid_stage1 <= 1'b0;
        else       valid_stage1 <= in_valid;
    end

`ifdef SIM_ASSERT
    always_ff @(posedge clk) begin
        // 0 是 head/rgb 未用通道的填充值（导出脚本 pack_channel_parameters
        // 跳过越界通道，留 0）；真实通道必须落在归一化窗口 [2^16, 2^17) 内。
        if (!reset && in_valid && multiplier_m18 != 17'd0 &&
            !multiplier_m18[16])
            $fatal(1, "RQ16 M18 must be normalized into [2^16, 2^17)");
    end
`endif
endmodule
