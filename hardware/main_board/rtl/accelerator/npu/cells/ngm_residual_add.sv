// 一路同域残差相加 + 裁剪。一个 lane 一份。
//
// ===================== 对外接口约定 =====================
//
// 【1】纯组合，无时钟、无寄存器、无乘法器
//   加法、比较、选择都在一拍内完成，不占 DSP，不引入流水级。
//
// 【2】数值合同（golden `quant/rq16_narrow_golden.py:208` + 主 Spec §15/§31）
//     total = branch + skip          ← 两支都是同域 INT8 码值，直接相加；
//                                      禁止插入 skip/branch scale 对齐乘法器
//     out   = clamp(total, 0, 127)
//
//   裁剪顺序不可调换：branch 在 RQ16 lane 里已经按本层激活要求饱和过一次
//   （6 个残差层的 vconv 在模型里 relu6 = False，所以那次是对称饱和到 ±127，
//   不做 ReLU6），这里是**第二次**裁剪，并且无条件裁到非负。
//
// 【3】enable = 0（本层没有残差，17 层里共 11 层）时输出 branch 直通
//   直通不裁剪：非残差层要能保持负值（例如 head 无 ReLU6）。所以 enable = 0 时
//   skip 被完全忽略，上层不需要为这些层准备零值。
//
// 【4】位宽
//   branch ∈ [-127, 127]（lane 饱和保证不出现 -128）
//   skip   ∈ [-127, 127]（上一层输出的码值）
//   和 ∈ [-254, 254]，9 位有符号；裁剪后落在 [0, 127]，第 8 位恒为 0
// ======================================================
module ngm_residual_add (
    input  logic signed [7:0] branch_code,
    input  logic signed [7:0] skip_code,
    input  logic              residual_enable,
    output logic signed [7:0] output_code
);
    logic signed [8:0] total;
    logic signed [8:0] clamped;

    assign total = branch_code + skip_code;

    assign clamped = (total < 9'sd0)   ? 9'sd0   :
                     (total > 9'sd127) ? 9'sd127 : total;

    assign output_code = residual_enable ? clamped[7:0] : branch_code;

endmodule
