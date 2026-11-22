/* OPTIMIZATION_NOTE_20261005
 * 精确位宽约束（2026-10-05）：signed INT8乘积范围[-16256,16384]。
 * 每轨6项范围[-97536,98304]，signed18位足够；12项[-195072,196608]，signed19位足够。
 * 截轨高位是数学上冗余的符号扩展，不依赖训练样本；bias/psum仍24位并保留原回绕语义。
 * 共享LUT加法器不增加DSP或流水拍：bias在first+6消费，PE结果last+7，簇延迟仍9拍。
 * 改输入位宽、每轨项数、DSP级联参数或流水时序，须重证范围并协同重验RQ/残差及调度。
 * 详见 docs/OPTIMIZATION_CONSTRAINTS.md。
 */
// 一个 PE：12 个 INT8 乘法 + 级联累加 + 累加器
//
// 12 个乘积由 6 个双乘法对串成两级：
//   每对产出一高一低两个 24 位部分和；
//   第 6 对（终端对）的 48 位输出里，低 24 位是低轨道的 6 项和，
//   高 24 位是高轨道的 6 项和。
// 两条轨道的和再相加，得到这一刀的 12 项和 chunk_sum。
//
// 从 issue 到结果锁存是 7 拍：6 级 DSP 级联 + 组合的两轨相加 + 1 级累加器寄存器。
// 六个有符号INT8乘积之和必定落在18位域；两轨之和用19位，显式符号扩展到20位。
// LUT实现利用同一数学边界，不增加DSP或流水级，bias和24位回绕规则不变。
// 权重与 bias 都由外部供应，本模块不持有任何上下文。
//
// ===================== 对外接口约定 =====================
//
// 【1】操作数时序（t = 某一拍 issue=1 的周期；t_first / t_last 指首刀、末刀那一拍）
//   activation / weight：必须在 **t 那一拍**有效（该拍结束的时钟沿被采样）。
//   bias：必须在 **t_first + 6 那一拍**有效 —— 累加那条边沿（issue_first 之后第 6 拍）
//         把当拍输入直接读进 psum 的 D 口，而且**这条边沿就是累加器的初始化**
//         （写的是 `bias + chunk_sum`，不是"加到已有值上"）。t_first 那一拍给的 bias
//         没用；给错拍会静默算错，不报错。本模块不锁存它（锁存反而会被紧随的下一批覆盖）。
//
// 【2】issue 协议（一个输出值 = 若干刀 issue）
//   第 0 刀    : issue=1, issue_first=1, issue_last=0
//   中间刀      : issue=1, issue_first=0, issue_last=0
//   最后一刀    : issue=1, issue_first=0, issue_last=1
//   只有一刀时  : issue=1, issue_first=1, issue_last=1（头尾同拍）
//   issue_first / issue_last 不得脱离 issue 单独拉高（有断言强制）。
//
// 【3】刀之间的空隙
//   刀与刀之间允许任意长度空闲（issue=0）。空闲拍不改变累加器，
//   也不影响后续刀。可以每拍连续发，也可以任意间隔。
//
// 【4】输出时序
//   result_valid：在 **t_last + 7 那一拍**拉高，**单拍脉冲**。
//   result_accumulator：就在那一拍有效 —— **下游必须在那一拍取走**。
//     它名义上会保持到下一次最后一刀的结果，但两条链挨得紧时只隔 1 拍，
//     所以按单拍脉冲对待，别指望在别的拍还能取到。
//
//   ── 一条 2 刀的链（t 拍首刀、t+1 拍末刀）──
//     拍:                  t      t+1     t+2 … t+5     t+6          t+7
//     issue:               1       1         0            0            0
//     activation/weight:  采样     采样
//     bias:                                          ↑ 必须在这一拍稳定
//     result_valid:                                                     1
//     result_accumulator:                                               有效 → 取走
//
// 【5】数值约定
//   一刀的 12 项和 = Σ(activation 第 m 字节 × weight 第 m 字节)，m = 0..11；
//   第 m 字节按有符号 8 位解释。
//   累加器初值 = 第 6 级流水上当时输入端的 bias；
//   累加顺序 = bias + 第 0 刀 + 第 1 刀 + ...
//   宽度依据（实测，见 quant/mem_rq16/manifest.json）：
//     一刀 12 项        样本上界193,548；通用INT8界196,608，19位有符号足够
//     一个输出值 36 项  上界  580,644  -> 21 位有符号（本模型最大层是 rgb）
//     bias             上界   30,770  -> 16 位有符号（body.3.hconv）
//   所以累加器与 bias 都取 24 位有符号：累加器余量 14 倍，bias 余量 272 倍。
//   导出包的 bias 字段也是 24 位（export_rq16_narrow_package.py 的 BIAS_BITS），
//   两侧宽度一致，装载时不需要截位。
//
// 【6】级联位置相关的参数（A_REG / B_REG / P_REG / PIPE_EXTRA）
//   决定本对在 6 对链上的位置与延迟对齐关系，改动前必须有 DSP 模型级证据。
// ======================================================
module ngm_pe_12mac (
    input  logic               clk,
    input  logic               reset,

    // 本拍要乘的 12 个激活字节 / 12 个权重字节
    input  logic [95:0]        activation,
    input  logic [95:0]        weight,

    // 累加器初值。不在 issue_first 那一拍锁存，而是在真正用到它的第 6 级流水上直接用当时的输入
    // —— 是哪一批的偏置由上游在正确那一拍摆好（引擎延迟 1 位批号即可），本模块不存第二份。
    input  logic signed [23:0] bias,

    input  logic               issue,
    input  logic               issue_first,
    input  logic               issue_last,

    output logic               result_valid,
    output logic signed [23:0] result_accumulator
);
    localparam int unsigned PAIR_COUNT = 6;

    logic [47:0] pair_result [0:PAIR_COUNT];
    logic signed [17:0] dot_low_lane;
    logic signed [17:0] dot_high_lane;
    logic signed [18:0] dot_combined;
    logic signed [19:0] chunk_sum;
    logic signed [23:0] psum;
    logic signed [23:0] next_psum;
    logic [6:0] issue_first_pipe_q;
    logic [6:0] issue_last_pipe_q;
    logic [6:0] issue_valid_pipe_q;

    assign pair_result[0] = 48'd0;

    // Retiming inside the first DSP: A/B_REG=1, W_REG=0 replaces
    // A/B_REG=0, W_REG=1. Multiplication is sampled at the same edge;
    // the first cascade word and all downstream issue/bias cycles are unchanged.
    // No fabric operand registers, extra DSP, or additional pipeline stage.
    for (genvar pair_id = 0; pair_id < PAIR_COUNT; pair_id++) begin : g_dual_mac
        ngm_dual_mac_pair #(
            .CASCADE_ACCUMULATE(pair_id != 0),
            .TERMINAL_PAIR     (pair_id == PAIR_COUNT-1),
            .A_REG             (1'b1),
            .B_REG             (1'b1),
            .P_REG             (pair_id >= 2),
            .W_REG             (pair_id != 0),
            .PIPE_EXTRA        ((pair_id > 2) ? pair_id-2 : 0)
        ) u_mac_pair (
            .clk         (clk),
            .act0        (activation[pair_id*16 +: 8]),
            .act1        (activation[pair_id*16+8 +: 8]),
            .weight0     (weight[pair_id*16 +: 8]),
            .weight1     (weight[pair_id*16+8 +: 8]),
            .cascade_in  (pair_result[pair_id]),
            .cascade_out (pair_result[pair_id+1])
        );
    end

    assign dot_low_lane  = $signed(pair_result[PAIR_COUNT][17:0]);
    assign dot_high_lane = $signed(pair_result[PAIR_COUNT][41:24]);
    assign dot_combined  = 19'($signed(dot_low_lane)) +
                           19'($signed(dot_high_lane));

    // 导出脚本保证 12 项的乘加上界不超过 20 位有符号
    always_comb chunk_sum = {dot_combined[18], dot_combined};

    // Select the initial or running base before one signed 24-bit adder.
    wire signed [23:0] accumulation_base = issue_first_pipe_q[5] ? bias : psum;
    assign next_psum = accumulation_base + $signed(chunk_sum);

    always_ff @(posedge clk) begin
        if (reset) begin
            issue_first_pipe_q <= '0;
            issue_last_pipe_q  <= '0;
            issue_valid_pipe_q <= '0;
            psum               <= '0;
            result_valid       <= 1'b0;
            result_accumulator <= '0;
        end else begin

            issue_first_pipe_q <= {issue_first_pipe_q[5:0], issue && issue_first};
            issue_last_pipe_q  <= {issue_last_pipe_q[5:0],  issue && issue_last};
            issue_valid_pipe_q <= {issue_valid_pipe_q[5:0], issue};

            if (issue_valid_pipe_q[5])
                psum <= next_psum;

            result_valid <= issue_last_pipe_q[5];
            if (issue_last_pipe_q[5])
                result_accumulator <= next_psum;
        end
    end

`ifdef SIM_ASSERT
    always_ff @(posedge clk) begin
        if (!reset && (issue_first || issue_last) && !issue)
            $fatal(1, "PE saw first/last without issue");
    end
`endif
endmodule
