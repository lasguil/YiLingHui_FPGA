// 16 条车道的 INT8 MAC 阵列：一拍 16 车道 × 每车道 12 次乘加 = 192 MAC
//
// 它就是 16 个 ngm_pe_12mac 并联：16 条车道**共用同一组 issue 信号**（同拍一起推进），
// 各自吃自己那一段操作数。本模块不持有权重槽、也不做槽选择——那些在 ngm_weight_slots 里。
//
// ============ 对外接口约定（就是 ngm_pe_12mac 的协议，16 份并联）============
//
// 位切片（第 L 条车道用自己那一段，L = 0..15）：
//   activation_operands[L*96 +: 96]    第 L 条车道的 12 个激活字节
//   weight_operands    [L*96 +: 96]    第 L 条车道的 12 个权重字节
//   bias_operands      [L*24 +: 24]    第 L 条车道的 24 位有符号累加器初值
//   result_accumulator [L*24 +: 24]    第 L 条车道的 24 位有符号结果
//
// 时序（t = 某一拍 issue=1 的周期；t_first / t_last 指首刀、末刀那一拍）：
//   activation / weight / issue_first / issue_last ：必须在 **t 那一拍**有效
//   bias                                          ：必须在 **t_first + 6 那一拍**有效
//   result_valid                                  ：在 **t_last + 7 那一拍**拉高，单拍脉冲
//   result_accumulator                            ：就在那一拍有效，**下游必须在那一拍取走**
//
//   ── 一条 2 刀的链（t 拍首刀、t+1 拍末刀）──
//     拍:                  t      t+1     t+2 … t+5     t+6          t+7
//     issue:               1       1         0            0            0
//     activation/weight:  采样     采样
//     bias:                                          ↑ 必须在这一拍稳定
//     result_valid:                                                     1
//     result_accumulator:                                               有效 → 取走
//
//   16 条车道同拍：上面这张表对 16 份操作数同时成立；result_valid 取第 0 条车道那一位
//   （16 条同步，取一条即可）。
//
// 累加器与 bias 都是 **24 位有符号**（不是 32 位）：一刀 12 项上界 20 位、一个输出值最多
// 36 项上界 21 位、bias 上界 16 位（依据见 quant/mem_rq16/manifest.json）。bias 在哪一拍被
// 取、以及"它那一条边沿就是初始化本身"的含义，见 ngm_pe_12mac 的文件头。
module ngm_mac_array_16x12 (
    input  logic         clk,
    input  logic         reset,

    // 16 车道 × 12 个激活字节
    input  logic [1535:0] activation_operands,

    // 16 车道 × 12 个权重字节
    input  logic [1535:0] weight_operands,

    // 16 车道 × 24 位累加器初值
    input  logic [16*24-1:0] bias_operands,

    // 一次 issue
    input  logic          issue,
    input  logic          issue_first,
    input  logic          issue_last,

    // 16 条车道同步，所以结果有效只需一位
    output logic          result_valid,
    output logic [16*24-1:0] result_accumulator
);
    localparam int unsigned PE_COUNT = 16;

    logic [PE_COUNT-1:0] pe_result_valid;

    for (genvar pe = 0; pe < PE_COUNT; pe++) begin : g_pe
        ngm_pe_12mac u_pe (
            .clk                (clk),
            .reset              (reset),
            .activation         (activation_operands[pe*96 +: 96]),
            .weight             (weight_operands[pe*96 +: 96]),
            .bias               ($signed(bias_operands[pe*24 +: 24])),
            .issue              (issue),
            .issue_first        (issue_first),
            .issue_last         (issue_last),
            .result_valid       (pe_result_valid[pe]),
            .result_accumulator (result_accumulator[pe*24 +: 24])
        );
    end

    // 16 条车道同时出结果，取一条即可
    assign result_valid = pe_result_valid[0];

endmodule
