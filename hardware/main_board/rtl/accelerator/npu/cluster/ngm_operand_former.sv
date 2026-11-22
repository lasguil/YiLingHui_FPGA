/* OPTIMIZATION_NOTE_20261005
 * 共享路由约束（2026-10-05）：共用kind译码及逐字节mask-OR，不增加流水或改变字节映射。
 * 正确性依赖五类固定通路、窗口角色和导出包lane顺序；改图结构/布局须一起改bank与window。
 * 保留原无效kind行为，不能把此面积优化解释为新增通用模型或任意通道布局支持。
 * 详见 docs/OPTIMIZATION_CONSTRAINTS.md。
 */
// 协议契约：Decoder-V窗口为物理H0/H2，三位槽标签随窗口保存，不以行奇偶猜测帧边界。
// 协议契约：RGB窗口是两行四列Head源数据，行列奇偶来自当前真实计算组；其他kind布局不变。
// ============================================================================
// 操作数成形器：把抽头窗口的 768 位（24 格 = 96 字节）按当前层摊成
// 16 条车道 × 12 个乘法的 1,536 位激活操作数，喂给 ngm_compute_cluster。
//
// 第 L 条车道的第 j 个乘法取窗口的哪个字节，是下面五条通路各自的固定接线。
// 与权重侧一一对应：第 L 条车道第 j 个乘法的权重 = 权重表里第 L 条车道第 j 个字节
// （导出包的 lane 序：值 << (lane*96 + k*8)）。这边错一位，数就全错。
//
// --------------------------- 五条通路（kind 0..4）---------------------------
// 约定：窗口字节号 = 格×4 + 格内字节（一格 4 字节 = 4 个通道，按通道顺序排）。
// 窗口里装的是**该层的全部输入通道**（不随 batch 换内容）——最大的 body 正好
// 3 个位置 × 32 通道 = 96 字节 = 一整窗。
//
//   kind 层                       形状        分组          窗口占位               取数规则（字节号）
//   ---- ----------------------- ---------- ------------ -------------------- ----------------------------------
//    0   stem / reduce / down    1×1        1 或 2（每组 32）12 / 32 / 64 字节    32*batch + 夹(12*slot + j, 32)
//    1   enc / dec 的 hconv/vconv 1×3 / 3×1  4（每组 4）   3 位置 × 16 通道      16*(j%3) + 4*(L/4) + (j/3)
//    2   body 的 hconv/vconv     1×3 / 3×1  4（每组 8）   3 位置 × 32 通道      32*(j%3) + 16*batch + 8*(L/8) + 4*slot + (j/3)
//    3   head                   1×1        1            4 点 × 16 通道        16*(L/4) + 夹(12*slot + j, 16)
//    4   rgb                    3×3        1            2 源行 × 4 源列 × 4 通道  按输出行奇偶和nearest关系固定映射源行列
//
// 三条 1×1 共用一个通路：stem 就是 reduce 的 slot=0，reduce 就是 down 的 batch=0
// （前提是上游对用不到的那一位给 0：stem/reduce 的 batch、stem 的 slot）。
// head 与 rgb 的点号隐含在车道号里（每点固定占 4 条 / 3 条车道），不需要额外输入。
//
// 分组（模型实测，见 ml/students/quantize_v2e_int8.py 里 QuantConv2d(...,groups)）：
//   enc/dec/body 的 hconv/vconv 都是 4 组 —— 车道 L 只吃**它那一组**的输入通道：enc/dec
//   每组 4 个通道（4 条车道一组）、body 每组 8 个（8 条车道一组）；down 是 2 组且每批
//   （16 个输出通道）整批落在同一组里，所以整批读同一份字节、靠 batch 选 32 字节的偏移。
//   其余层都是 1 组。
//
// --------------------------- 补零的乘法不做选择 ---------------------------
// 那些位置的权重是 0，激活固定接常量 0（省掉选择器，且仿真不会出 X）：
//   · head 的第二个 slot：只有前 4 项有效（12 + 4 = 16）；
//   · 1×1 通路的第三拍：只有前 8 项有效（12*2 + 8 = 32）。
//
// ------------------------------- 怎么写得省 -------------------------------
// 1) 每条通路先算好自己的取数，**"哪几条车道共用同一份字节"就只算一份**（通路 0 全部车道
//    共用；1 每 4 条一份；2 每 8 条一份；3 每 4 条一份；4 每 3 条一份），最后按 kind 选。
// 2) 窗口取数的下标**必须是编译期常量**。第几拍/哪个批次的差别要写成"先取好几个常量字节、
//    再选一个"；一旦把它加进下标（例如 win[32*batch + 12*slot + j]），下标就成了运行期值，
//    一个字节变成 96 选 1 —— 实测整块会从 861 XLR 涨到 33,756 XLR。
// 3) 取字节写成"常量地址 + 直接位选"，**不要用自动函数**：Questa 会把"函数 + 常量实参"的
//    调用折叠掉，直接赋给信号时读出来是 X（最小复现：assign y = fn(3); 得 X，而
//    assign y = win[3*8 +: 8]; 正确）。纯常量的中间 wire 同样会被折叠成 X。
// ============================================================================
module ngm_operand_former #(
    parameter int unsigned WINDOW_CELLS = 24,          // 抽头窗口的格数
    parameter int unsigned CELL_BITS    = 32,          // 每格的位数
    parameter int unsigned LANE_COUNT   = 16,          // 车道条数
    parameter int unsigned SLOT_COUNT   = 12           // 每条车道一拍的乘法个数
) (
    // 通路编号（见上表）、第几拍、第几个输出通道批次：由点引擎按层给
    input  logic [2:0] kind,
    input  logic [1:0] slot,
    input  logic       batch,
    input logic [1:0] dec_v, // Decoder-V物理两源映射。
    input logic rgb_x_odd,rgb_y_odd, // 源窗口到逻辑抽头的两个固定相位。

    // 算的那一半窗口，24 格 = 96 字节
    input  logic [WINDOW_CELLS*CELL_BITS-1:0]  window_cells,

    // 16 条车道 × 12 个字节，组合输出、0 拍延迟
    output logic [LANE_COUNT*SLOT_COUNT*8-1:0] activation_operands
);

    wire one=kind==0,triple=kind==1,body=kind==2,head_sel=kind==3;
    wire rgb=!(one || triple || body || head_sel);
    wire [2:0] slot3={slot!=0 && slot!=1,slot==1,slot==0};
    wire [1:0] slot2={slot!=0,slot==0};
    wire [5:0] one_sel,rgb_sel;
    wire [3:0] body_sel;
    wire [1:0] head_mask;
    for(genvar s=0;s<3;s++)begin:g_s3
        assign one_sel[s]=one && !batch && slot3[s];
        assign one_sel[s+3]=one && batch && slot3[s];
        assign rgb_sel[s]=rgb && !rgb_y_odd && slot3[s];
        assign rgb_sel[s+3]=rgb && rgb_y_odd && slot3[s];
    end
    for(genvar s=0;s<2;s++)begin:g_s2
        assign body_sel[s]=body && !batch && slot2[s];
        assign body_sel[s+2]=body && batch && slot2[s];
        assign head_mask[s]=head_sel && slot2[s];
    end
    wire [2:0] enc_h0,enc_h2,enc_mid;
    wire enc_normal=triple && dec_v!=1 && dec_v!=2;
    for(genvar p=0;p<3;p++)begin:g_enc_sel
        assign enc_h0[p]=triple && ((dec_v==1 && !window_cells[256+p]) ||
            (dec_v==2 && p!=1 && !window_cells[384+p]));
        assign enc_h2[p]=triple && ((dec_v==1 && window_cells[256+p]) ||
            (dec_v==2 && p!=1 && window_cells[384+p]));
        assign enc_mid[p]=triple && dec_v==2 && p==1;
    end
    for(genvar L=0;L<LANE_COUNT;L++)begin:g_lane
        localparam int P_HEAD=L/4,P_RGB=(L/3<4) ? L/3 : 3;
        localparam int G_ENC=L/4,G_BODY=L/8;
        for(genvar j=0;j<SLOT_COUNT;j++)begin:g_slot
            wire [7:0] result_one[3],result_rgb[3];
            for(genvar s=0;s<3;s++)begin:g_pick
                localparam int A=s*SLOT_COUNT+j;
                if(A<32)assign result_one[s]=
                    ({8{one_sel[s]}} & window_cells[A*8+:8]) |
                    ({8{one_sel[s+3]}} & window_cells[(32+A)*8+:8]);
                else assign result_one[s]=0;
                localparam int R=s*12+j;
                localparam int A0=32*((R%9)/3>=1)+4*((P_RGB+R%3+1)/2)+R/9;
                localparam int A1=32*((R%9)/3==2)+4*((P_RGB+R%3+1)/2)+R/9;
                assign result_rgb[s]=({8{rgb_sel[s]}} & window_cells[A0*8+:8]) |
                    ({8{rgb_sel[s+3]}} & window_cells[A1*8+:8]);
            end
            localparam int PH0=4*G_ENC+j/3,PH2=16+PH0;
            localparam int ENC_A=16*(j%3)+PH0;
            wire [7:0] result_enc=({8{enc_normal}} & window_cells[ENC_A*8+:8]) |
                ({8{enc_h0[j%3]}} & window_cells[PH0*8+:8]) |
                ({8{enc_h2[j%3]}} & window_cells[PH2*8+:8]) |
                ({8{enc_mid[j%3]}} & window_cells[(32+PH0)*8+:8]);
            localparam int BODY_A=32*(j%3)+8*G_BODY+j/3;
            wire [7:0] result_body=({8{body_sel[0]}} & window_cells[BODY_A*8+:8]) |
                ({8{body_sel[1]}} & window_cells[(BODY_A+4)*8+:8]) |
                ({8{body_sel[2]}} & window_cells[(BODY_A+16)*8+:8]) |
                ({8{body_sel[3]}} & window_cells[(BODY_A+20)*8+:8]);
            wire [7:0] head_next;
            if(12+j<16)assign head_next={8{head_mask[1]}} & window_cells[(16*P_HEAD+12+j)*8+:8];
            else assign head_next=0;
            wire [7:0] result_head=({8{head_mask[0]}} & window_cells[(16*P_HEAD+j)*8+:8]) | head_next;
            assign activation_operands[L*SLOT_COUNT*8+j*8+:8]=
                result_one[0] | result_one[1] | result_one[2] | result_enc |
                result_body | result_head | result_rgb[0] | result_rgb[1] | result_rgb[2];
        end
    end
endmodule
