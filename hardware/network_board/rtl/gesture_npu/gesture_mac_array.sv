// 32 条 int8 MAC 通道的阵列：16 颗 EFX_DSP48，每颗 2 条通道。
//
// lane 索引 = 2*dsp + 轨（低轨在前）。引擎按「展平的 (像素, 输出通道)」分配 lane，
// 所以阵列本身只要求 act_flat / wgt_flat 的第 lane 字节对应该 lane 当前要算的那一项。
module gesture_mac_array #(
    parameter int DSP_N = 16
) (
    input  logic                        clk,
    input  logic                        reset,
    input  logic                        acc_clear,
    input  logic                        acc_enable,
    input  logic [DSP_N*2*8-1:0]        act_flat,
    input  logic [DSP_N*2*8-1:0]        wgt_flat,
    output logic [DSP_N*2*32-1:0]       acc_flat
);
    for (genvar d = 0; d < DSP_N; d++) begin : g_dsp
        gesture_dual_mac u_mac (
            .clk       (clk),
            .reset     (reset),
            .acc_clear (acc_clear),
            .acc_enable(acc_enable),
            .act_lo    (act_flat[(2*d+0)*8 +: 8]),
            .act_hi    (act_flat[(2*d+1)*8 +: 8]),
            .wgt_lo    (wgt_flat[(2*d+0)*8 +: 8]),
            .wgt_hi    (wgt_flat[(2*d+1)*8 +: 8]),
            .acc_lo    (acc_flat[(2*d+0)*32 +: 32]),
            .acc_hi    (acc_flat[(2*d+1)*32 +: 32])
        );
    end
endmodule
