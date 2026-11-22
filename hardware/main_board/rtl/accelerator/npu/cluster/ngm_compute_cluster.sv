// 协议契约：bias第6拍、RQ参数第7拍、skip和残差使能第8拍捕获，最终结果仍第9拍输出。
// 第8拍DSP后的商与舍入标志切拍；第9拍组合舍入、饱和及残差；替换原末端寄存，不增加外部延迟。
// skip的128位和使能只延迟一拍，与新RQ分支对齐；数据不复位，所有valid同步复位；输出无回压。
// 计算簇：唯一物理阵列 + 16 lane 重量化 + 同域残差，接成一条流水。
//
//   操作数捆 → ngm_mac_array_16x12 → ngm_requant_ppu → ngm_residual_bank → 结果
//
// 操作数成形与常驻槽不在本模块内：它们在 ngm_point_engine 上（ngm_operand_former / ngm_weight_slots）。
// 结果的散写也不在这里 —— ngm_result_former 已挪到存储侧（rtl/mem/），因为激活 bank 的写口在那边。
//
// ===================== 对外接口约定 =====================
//
// 【1】时序链（以 issue 那一拍为 0）
//   0 拍：activation_operands / weight_operands / bias_operands 三捆必须有效
//   +7 拍：阵列 result_valid（ngm_pe_12mac：6 级 DSP 级联 + 组合两轨相加 + 1 级累加器寄存器）
//   +8 拍：重量化保存商、舍入标志；同拍捕获skip及残差使能
//   +9 拍：重量化组合舍入与饱和，分支码与延迟skip进入组合残差
//   +9 拍：组合残差输出；与既有第9拍标签对齐后写bank。
//   所以一次issue的最终结果出现在第9拍，整簇只需一位有效位。
//
// 【2】操作数与重量化参数的变化频率不同
//   三捆操作数逐拍变化（每一刀 chunk 不同）；
//   pre_shifts / multipliers_m18 / post_shifts / relu6_enable 是逐层固定的，
//   由 ngm_weight_slots 在层边界摆好，PPU 在结果返回那一拍取用，所以它们必须
//   在各自消费时刻提供对应层/批参数，预取期间由常驻槽地址历史保持。
//
// 【3】同域残差的两支
//   branch 在本模块内部产生；skip_codes 由上层按时送到，与结果同拍。
//   skip_codes 是**第8拍已经选好的 128 位半字**：C32 层按 batch 选高低半（低 = 通道 0-15），
//   C16 层按 x 奇偶选（低 128 = 偶 x，高 128 = 奇 x）。选择在上层完成——本模块不关心
//   这批数来自哪一半，也不产生读请求、不携带地址。
//   residual_enable = 0 时残差单元直通 branch（不裁剪），skip 被忽略。
//
// 【4】结果
//   最终码值从量化中间寄存后的组合残差引到result_*端口，交给上层转给存储侧的 ngm_result_former 去散写。
//
// 【5】尚未实现
//   三客户（前端 / 主体 / 尾部）所有权仲裁不在这里——它只门控 issue 与各 enable，
//   不影响本模块内部接线。
// ======================================================
module ngm_compute_cluster ( // 固定模型的计算与标签控制模块。
    input  logic              clk, // 工作时钟。
    input  logic              reset, // 同步复位，只清控制和有效位。

    // 操作数捆，来自 ngm_operand_former
    input  logic [1535:0]     activation_operands, // 16车道各12个INT8激活操作数。
    input  logic [1535:0]     weight_operands, // 与激活逐项对应的INT8权重。
    input  logic [16*24-1:0]  bias_operands, // 16车道各24位bias，在首片后第6拍使用。

    // 一次 issue
    input  logic              issue, // 本拍阵列执行一个切片。
    input  logic              issue_first, // 本批首片，开启新的累加。
    input  logic              issue_last, // 本批末片，发起本批结果流水。

    // 逐通道重量化参数，来自 ngm_weight_slots（逐层固定）
    input  logic [16*3-1:0]   pre_shifts, // 16车道的重量化预移位。
    input  logic [16*17-1:0]  multipliers_m18, // 16车道的17位量化乘数。
    input  logic [16*5-1:0]   post_shifts, // 16车道的重量化后移位。
    input  logic              relu6_enable, // 当前批分支的ReLU裁剪授权。

    // 同域残差的 skip 半字，由上层按时送到，与结果同拍
    input  logic [16*8-1:0]   skip_codes, // 第8拍消费的同域INT8残差半字。
    input  logic              residual_enable, // 第8拍残差相加及最终裁剪授权。

    // 最终结果
    output logic              result_valid, // 最终第9拍结果有效。
    output logic [16*8-1:0]   result_codes // 最终16车道INT8码值。
); // 端口连接或参数定义结束。
    // 阵列 → 重量化
    logic             array_result_valid; // 阵列第7拍累加结果有效。
    logic [16*24-1:0] array_result_accumulator; // 16车道24位阵列累加值。

    // 重量化 → 残差
    logic             branch_valid; // 第9拍重量化分支有效。
    logic [16*8-1:0]  branch_codes; // 第9拍量化分支的16车道码值。

    ngm_mac_array_16x12 u_mac_array ( // 唯一96-DSP阵列，逐片累加。
        .clk                (clk), // 工作时钟。
        .reset              (reset), // 同步复位，只清控制和有效位。
        .activation_operands(activation_operands), // 16车道各12个INT8激活操作数。
        .weight_operands    (weight_operands), // 与激活逐项对应的INT8权重。
        .bias_operands      (bias_operands), // 16车道各24位bias，在首片后第6拍使用。
        .issue              (issue), // 本拍阵列执行一个切片。
        .issue_first        (issue_first), // 本批首片，开启新的累加。
        .issue_last         (issue_last), // 本批末片，发起本批结果流水。
        .result_valid       (array_result_valid), // 阵列第7拍累加结果有效。
        .result_accumulator (array_result_accumulator) // 第7拍16车道INT24累加值。
    ); // 端口连接或参数定义结束。

    ngm_requant_ppu u_requant_ppu ( // 16-DSP重量化PPU，与阵列结果对齐。
        .clk             (clk), // 工作时钟。
        .reset           (reset), // 同步复位，只清控制和有效位。
        .in_valid        (array_result_valid), // 输入流水有效位。
        .accumulators    (array_result_accumulator), // 阵列累加值送入重量化。
        .pre_shifts      (pre_shifts), // 16车道的重量化预移位。
        .multipliers_m18 (multipliers_m18), // 16车道的17位量化乘数。
        .post_shifts     (post_shifts), // 16车道的重量化后移位。
        .relu6_enable    (relu6_enable), // 当前批分支的ReLU裁剪授权。
        .out_valid       (branch_valid), // 输出流水有效位。
        .output_codes    (branch_codes) // 16车道最终码值。
    ); // 端口连接或参数定义结束。

    logic [127:0] skip_q;logic residual_enable_q; // 第8拍接口采样，实际相加移到第9拍。
    always_ff @(posedge clk)begin // 与量化商的新增寄存级同步推进。
        skip_q<=skip_codes;residual_enable_q<=residual_enable; // 不复位无效数据，分支valid屏蔽复位残留。
    end // 残差输入延迟结束。
    wire residual_valid;wire [127:0] residual_codes; // 与既有第9拍标签对齐。
    ngm_residual_bank u_residual_bank ( // 第9拍组合残差相加及裁剪。
        .in_valid        (branch_valid), // 输入流水有效位。
        .branch_codes    (branch_codes), // 第9拍量化分支的16车道码值。
        .skip_codes      (skip_q), // 第8拍捕获、第9拍相加的同域INT8残差半字。
        .residual_enable (residual_enable_q), // 第8拍捕获、第9拍裁剪授权。
        .out_valid       (residual_valid), // 输出流水有效位。
        .output_codes    (residual_codes) // 16车道最终码值。
    ); // 端口连接或参数定义结束。

    assign result_valid=residual_valid; // 两拍RQ加七拍阵列，结果有效仍为第9拍。
    assign result_codes=residual_codes; // 原末端寄存已移到量化商处，没有重复增加输出一级。
endmodule // 本段控制或模块定义结束。
