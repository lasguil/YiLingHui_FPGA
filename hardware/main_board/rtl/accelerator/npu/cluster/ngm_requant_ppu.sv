// 协议契约：RQ输入到输出两拍，每拍一批；第1拍DSP乘积、第2拍选定商及标志，之后组合舍入饱和。
// 16 条车道的 RQ16-Narrow 重量化单元。
// // 量化车道接口、逐位连接或流水区段边界。
// 一次输入 = 阵列一次返回的 16 个 INT24 累加值，一次输出 = 16 个 INT8 码值。
// 16 条车道同步推进，所以有效位只需一位（与阵列的 result_valid 同一口径）。
// // 量化车道接口、逐位连接或流水区段边界。
// ===================== 对外接口约定 =====================
// // 量化车道接口、逐位连接或流水区段边界。
// 【1】时序
//   in_valid 为高那一拍，accumulators 与三组逐通道参数必须同时有效。
//   它们被 lane 的组合逻辑取用后立即进入乘法器；乘法器的 P_REG = 1 拍，
//   随后商与舍入标志再寄存一拍，所以 out_valid 比 in_valid 晚两拍。
//     out_valid 高那一拍：output_codes 有效（16×8 位）。
// // 量化车道接口、逐位连接或流水区段边界。
// 【2】参数是逐输出通道的，必须与本拍累加值属于同一批
//   pre_shifts      16 × 3 位  每层固定；合同范围 0..2，3 位留到 0..7 的余量
//   multipliers_m18 16 × 17 位 归一化到 [2^16, 2^17)，bit17 恒为 0 故不占位
//   post_shifts     16 × 5 位  真实通道取 20..28（当前包落在 22..26）；0 = 未使用
//   relu6_enable    1 位       每层属性（描述符 activation_mode）
// // 量化车道接口、逐位连接或流水区段边界。
// 【3】输出
//   已饱和到 signed INT8 并按 relu6_enable 裁剪；未使用的通道输出 0。
// // 量化车道接口、逐位连接或流水区段边界。
// 【4】资源
//   16 颗 DSP（每 lane 一颗 19×18）。加上 96-DSP 的 MAC 阵列，
//   完整 NPU 恰好 112 DSP —— 这是冻结值，不得增删 lane 或改位宽。
// ====================================================== // 量化车道接口、逐位连接或流水区段边界。
module ngm_requant_ppu ( // 量化车道接口、逐位连接或流水区段边界。
    input  logic               clk, // 量化流水工作时钟。
    input  logic               reset, // 同步复位两级有效位。
    input  logic               in_valid, // 当前INT24批次和参数同时有效。
    input  logic [16*24-1:0]   accumulators, // 十六车道各24位累加值。
    input  logic [16*3-1:0]    pre_shifts, // 十六车道各3位合法前移位档。
    input  logic [16*17-1:0]   multipliers_m18, // 十六车道各17位非负归一化乘数。
    input  logic [16*5-1:0]    post_shifts, // 十六车道各5位固定后移位档。
    input  logic               relu6_enable, // 本批负值裁零授权，随数值过流水。
    output logic               out_valid, // 输入后两拍输出有效，持续吞吐一批每拍。
    output logic [16*8-1:0]    output_codes // 十六车道各8位饱和INT8输出。
); // 量化车道接口、逐位连接或流水区段边界。
    localparam int unsigned LANE_COUNT = 16; // 量化车道接口、逐位连接或流水区段边界。

    // 16 条车道同步，所以只要一条的有效位。用端口接出来（层次引用综合器不认）。
    logic [LANE_COUNT-1:0] lane_valid; // 量化车道接口、逐位连接或流水区段边界。

    for (genvar lane = 0; lane < LANE_COUNT; lane++) begin : g_lane // 量化车道接口、逐位连接或流水区段边界。
        ngm_rq16_lane u_lane ( // 量化车道接口、逐位连接或流水区段边界。
            .clk            (clk), // 量化车道接口、逐位连接或流水区段边界。
            .reset          (reset), // 量化车道接口、逐位连接或流水区段边界。
            .in_valid       (in_valid), // 量化车道接口、逐位连接或流水区段边界。
            .accumulator    ($signed(accumulators[lane*24 +: 24])), // 量化车道接口、逐位连接或流水区段边界。
            .pre_shift      (pre_shifts[lane*3 +: 3]), // 量化车道接口、逐位连接或流水区段边界。
            .multiplier_m18 (multipliers_m18[lane*17 +: 17]), // 量化车道接口、逐位连接或流水区段边界。
            .post_shift     (post_shifts[lane*5 +: 5]), // 量化车道接口、逐位连接或流水区段边界。
            .relu6_enable   (relu6_enable), // 量化车道接口、逐位连接或流水区段边界。
            .out_valid      (lane_valid[lane]), // 量化车道接口、逐位连接或流水区段边界。
            .output_code    (output_codes[lane*8 +: 8]) // 量化车道接口、逐位连接或流水区段边界。
        ); // 量化车道接口、逐位连接或流水区段边界。
    end // 量化车道接口、逐位连接或流水区段边界。

    // 取 lane 0 的；其余 15 位没有消费者，综合会裁掉
    assign out_valid = lane_valid[0]; // 量化车道接口、逐位连接或流水区段边界。

endmodule // 量化车道接口、逐位连接或流水区段边界。
