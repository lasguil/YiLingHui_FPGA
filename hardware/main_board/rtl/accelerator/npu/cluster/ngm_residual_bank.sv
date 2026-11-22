// 16 路同域残差单元：RQ16 lane 出来的 16 个 branch 码值 + 同域 skip 码值 → 最终 INT8。
//
// 这一级是 Spec §50 运算链的最后一环，也是 §31 算子顺序里 `P^-1 → residual → ReLU6`
// 里的 residual 与 ReLU6 两段。
//
// ===================== 对外接口约定 =====================
//
// 【1】时序：同拍进同拍出，0 拍延迟（纯组合）
//   in_valid 为高那一拍，branch_codes 与 skip_codes 必须同时有效。
//   out_valid 就是 in_valid。
//
// 【2】skip 由上层调度器按时送到，本模块不产生读请求、不携带地址
//   branch 码值出现在 issue 之后第 8 拍（阵列 7 拍 + RQ16 1 拍）。
//   skip 的取数由上层 bank 控制器负责：在 issue 之后第 7 拍发出第二次读
//   （同步读 1 拍延迟），数据正好在第 8 拍落到本模块门口。
//   Body 相位该读拍落在 V 阶段 x 时隙的 3 号空闲槽（Spec §14 的 "cycle 3: spare"）；
//   前端/尾部相位的取数槽由各自 bank 控制器安排。
//   本模块只回答一个问题：给定两支码值，输出是什么。
//
// 【3】lane 与通道的对应，以及通道置换的位置
//   lane ℓ 对应该批的第 ℓ 个输出通道。模型里 block 的通道 shuffle（P16 / P32）
//   作用在残差加法两侧：skip 读的时候按该层图案选 lane，写回的时候按同一图案写位置。
//   P16为自逆转置；P32必须在完整32通道上跨批置换，且逆置换与正置换不同。
//   本模块在branch通道顺序中逐lane相加：skip须先正置换，输出由整理器逆置换回模型通道顺序。
//
// 【4】residual_enable 来自描述符字段，17 层里 6 层为真
//   真：enc.vconv、body.0..3.vconv、dec.vconv
//   假：其余 11 层，输出 branch 直通且不裁剪（保持负值），skip 被忽略
//
// 【5】资源
//   每个 lane：9 位加法 + 两级比较 + 8 位二选一。16 lane 全组合，无寄存器、无 DSP。
// ======================================================
module ngm_residual_bank (
    input  logic              in_valid,
    input  logic [16*8-1:0]   branch_codes,
    input  logic [16*8-1:0]   skip_codes,
    input  logic              residual_enable,
    output logic              out_valid,
    output logic [16*8-1:0]   output_codes
);
    localparam int unsigned LANE_COUNT = 16;

    assign out_valid = in_valid;

    for (genvar lane = 0; lane < LANE_COUNT; lane++) begin : g_lane
        ngm_residual_add u_add (
            .branch_code     ($signed(branch_codes[lane*8 +: 8])),
            .skip_code       ($signed(skip_codes[lane*8 +: 8])),
            .residual_enable (residual_enable),
            .output_code     (output_codes[lane*8 +: 8])
        );
    end

endmodule
