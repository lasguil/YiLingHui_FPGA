// 协议契约：D原生写层没有配对，配对暂存只保存自然顺序的Stem偶列或C32低批；P16只出现在即时128位出口。
// 最终写字每个字节以固定车道索引一次选择，不经过formed/head/doubled三条中间宽总线。
// 协议契约：D原生128位逐像素写，layer2/13/14不配对，Reduce不展开横向重复；其他bank配对不变。
// 协议契约：layer1每拍直接输出一个低128位像素，其余层仍沿用正式配对。
// 协议契约：Reduce/Head只物理写一次横向放大行；相邻两条真实行由D源行标签共同表示。
// Head的code_slot是Head源行三槽号，Decoder-H的槽只允许0/2，Decoder-V结果固定写H槽1。
// 固定模型结果写回：Stem偶奇、C32双批拼字；A/B前端与D逐像素128位，Reduce/Head不物理复制nearest。
// 上游码流没有回压口；调度器须保证目标写口在结果拍可用。
// C32 的低批与高批必须来自同一像素并依次到达；行引擎在批间留出的拍数不改变次序。
// 本模块共用一份 128 位暂存，不另存坐标标签；层号须保持到该层所有在途结果返回。
// Stem按同一行偶列、奇列配对；Encoder/Decoder的原生128位结果逐像素写，行内仍按真实列顺序到达。
// V结果按真实模型inverse permutation恢复：C16自逆P16，C32必须拼齐两批再跨批逆P32。
// V残差输入在读侧先按同一P置换，使分支加法及饱和后逆P等价于模型先逆P再相加；H写回保持自然顺序。
// code_x、emit_lo/hi、center_lo/hi 都使用该层张量的真实列号；strip 局部组号先由调度侧换算。
// RGB阶段没有C16/C32码写入；输出对齐器可独占saved_lanes_q保存不足一个AXI拍的前缀，不另设128位寄存器。
// prefix_write仅在layer16且先前配对已排空时有效；中止必须等已授权W发送完才能复位本模块。
module ngm_result_former #(                                     // 整理器参数。
    parameter int unsigned ROW_W=11,                             // 真实行号位宽。
    parameter int unsigned COL_W=11                              // 真实列号位宽。
)(                                                               // 端口开始。
    input logic clk,                                             // 工作时钟。
    input logic reset,                                           // 同步复位。
    input logic prefix_write, // RGB输出对齐更新共享寄存器。
    input logic [127:0] prefix_data, // 下一个有效前缀，长度由输出对齐器保存。
    output wire [127:0] prefix_value, // 既有saved_lanes_q直通，无新增数据寄存器。
    input logic [4:0] layer_id,                                  // 固定模型层号 0..16。
    input logic code_in_range, // Authoritative range bit from the existing result tag.
    input logic code_valid,                                      // 一次计算返回有效。
    output logic code_ready,                                     // 当前返回可接收。
    input logic [ROW_W-1:0] code_row,                             // 结果真实行号。
    input logic [COL_W-1:0] code_x,                               // 结果组首列。
    input logic code_batch,                                      // C32 输出的低或高 16 通道批。
    input logic [1:0] code_slot,                                 // 调度给出的目标三行槽；Head 对应放大后偶行。
    input logic [127:0] code_lanes,                              // 十六条 INT8 结果车道。
    input logic [COL_W-1:0] emit_lo,                              // 须保存的首列，包含调度所需 halo。
    input logic [COL_W-1:0] emit_hi,                              // 须保存的尾界。
    input logic [COL_W-1:0] center_lo,                            // C 片条带中心首列。
    input logic [COL_W-1:0] center_hi,                            // C 片条带中心尾界。
    input logic sink_ready,                                      // 选中目标写口可接收。
    output logic wr_valid,                                       // 一笔目标写入有效。
    output logic [2:0] wr_bank,                                  // 写目标：0=A、1=B、2=C、3=D、4=DDR。
    output logic wr_full,                                        // 选择整字类路由；D仅低128位有效，C仍是256位。
    output logic wr_front,                                       // 目标是前端相位区域。
    output logic [1:0] wr_d_half_kind,                           // D 半字口：1=H、2=HEAD、3=FRONT。
    output logic wr_d_word_kind,                                 // D 整字口：0=RES、1=RGB。
    output logic [1:0] wr_c_body,                                // C 的 X 槽编号。
    output logic wr_c_preserve,                                  // V3 原位覆盖 X3。
    output logic [ROW_W-1:0] wr_row,                              // 目标真实行号。
    output logic [COL_W-1:0] wr_x,                                // 目标首列。
    output logic [1:0] wr_slot,                                   // AB 行环或 D RGB 行槽。
    output logic [255:0] wr_data,                                 // 整字或低半字写数据。
    output logic wr_begin,                                       // 目标行首笔。
    output logic wr_last,                                        // 目标行末笔。
    output logic [COL_W-1:0] wr_center_lo,                        // C 条带中心首列直通。
    output logic [COL_W-1:0] wr_center_hi,                        // C 条带中心尾界直通。
    output logic protocol_error                                 // 错误保持到复位。
);                                                               // 端口结束。
    logic pair_valid_q;                                         // C16 偶列或 C32 低批等待配对。
    logic [127:0] saved_lanes_q;                                // C16 偶列及C32低批共用暂存，最近邻不保存重复行。
    assign prefix_value=saved_lanes_q; // 分时引出现有寄存器。
    logic in_range, c32_layer, doubled_layer, direct_layer;     // 固定层类别。
    logic [2:0] selected_bank;                                  // 当前层目标 bank。
    assign in_range=code_in_range;         // 仅写本层要求的完整输出范围。
    assign c32_layer=layer_id==5'd3 || (layer_id>=5'd4 && layer_id<=5'd11); // Down 和 Body。
    assign doubled_layer=layer_id==5'd12 || layer_id==5'd15;   // Reduce 和 Head。
    wire direct_ab=layer_id==5'd1 || layer_id==5'd2 || layer_id==5'd13 || layer_id==5'd14; // D采用原生像素端口。 // 协议契约：A/B前端原生128位逐像素写，其他C16保持配对。
    assign direct_layer=(layer_id<=5'd2 || layer_id==5'd13 || layer_id==5'd14) && !direct_ab; // C16 直写。
    wire inv16=layer_id==2 || layer_id==14; // 两个C16 V结果恢复自然通道顺序。
    wire inv32=layer_id==5 || layer_id==7 || layer_id==9 || layer_id==11; // 四个Body V结果跨批恢复。
    wire [255:0] raw_word={code_lanes,saved_lanes_q}; // 两批齐全时的卷积分支通道顺序。
    wire [255:0] canonical32; // 固定逆P32连线，不增加宽寄存器。
    for(genvar c=0;c<32;c++)begin:g_inv32 // 真实P32为四乘八转置，其逆不同于正向。
        assign canonical32[c*8+:8]=raw_word[(4*(c%8)+c/8)*8+:8]; // 接齐高低批才允许写出。
    end // C32恢复结束。
    wire small_write=direct_ab || doubled_layer; // 原生128位输出与配对256位输出分时。
    for(genvar c=0;c<16;c++)begin:g_write_byte // 索引全为生成期常量。
        assign wr_data[c*8+:8]=inv32 ? canonical32[c*8+:8] : small_write ? (inv16 ? code_lanes[(4*(c%4)+c/4)*8+:8] : code_lanes[c*8+:8]) : saved_lanes_q[c*8+:8]; // 低半字仅选真实来源。
        assign wr_data[128+c*8+:8]=inv32 ? canonical32[128+c*8+:8] : small_write ? 8'b0 : code_lanes[c*8+:8]; // 高半字无不必要的P16网络。
    end // 固定写字结束。
    always_comb begin                                           // 固定层到物理目标译码。
        selected_bank=3'd3;                                     // 默认 D 片。
        case (layer_id)                                         // 模型拓扑唯一映射。
            5'd0: selected_bank=3'd2;                           // Stem 写 C 前端行。
            5'd1: selected_bank=code_row[0] ? 3'd1 : 3'd0;     // Encoder-H 按行奇偶写 A/B。
            5'd2: selected_bank=3'd3;                           // Encoder-V 写 D 前端双行。
            5'd3: selected_bank=3'd4;                           // Down 写 DDR 的 X0。
            5'd4,5'd6: selected_bank=3'd0;                     // Body0/1 的 H 写 A。
            5'd8,5'd10: selected_bank=3'd1;                    // Body2/3 的 H 写 B。
            5'd5,5'd7,5'd9,5'd11: selected_bank=3'd2;         // Body-V 写 C 的 X1..X4。
            default: selected_bank=3'd3;                       // Tail 写 D 片。
        endcase                                                 // 目标译码结束。
    end                                                         // 目标选择结束。
    always_comb begin                                           // 一拍至多产生一笔写入。
        wr_valid=1'b0;                                          // 默认空闲。
        wr_bank=selected_bank;               // 固定层选择目标。
        wr_full=1'b1;                                           // C16、C32 和最近邻结果都在这里写成整字。
        wr_front=layer_id<=5'd2;                  // 前端三层共用前端区域。
        wr_d_half_kind=layer_id==5'd2 ? 2'd3 : layer_id==5'd13 ? 2'd1 : 2'd2; // D 半字口类别。
        wr_d_word_kind=layer_id==5'd15;                             // Head 去 RGB，其余去 RES。
        wr_c_body=layer_id==5'd5 ? 2'd1 : layer_id==5'd7 ? 2'd2 : 2'd3; // V0/V1/V2/V3 的 C 槽。
        wr_c_preserve=layer_id==5'd11;            // V3 原位转换 X3 为 X4。
        wr_row=doubled_layer ? ROW_W'(code_row<<1) : code_row; // 最近邻只写偶逻辑行，D标签保存源行。
        wr_x=doubled_layer ? COL_W'(code_x<<1) : code_x; // 最近邻目标列。
        wr_slot=code_slot;           // 行槽直接取调度侧环号。
        wr_begin=direct_ab ? code_x==emit_lo : doubled_layer ? code_x==emit_lo : direct_layer ? code_x==emit_lo+1'b1 : code_x==emit_lo && code_batch; // 首笔真正提交的整字。
        wr_last=(layer_id==5'd15 ? code_x+COL_W'(4)>=emit_hi : code_x==emit_hi-1'b1) && (!c32_layer || code_batch); // 只提交实际末字。
        wr_center_lo=center_lo;                                 // C 中心起点。
        wr_center_hi=center_hi;                                 // C 中心尾界。
        if (code_valid && in_range && (direct_ab || doubled_layer || ((c32_layer && code_batch || direct_layer && code_x[0]) && pair_valid_q))) wr_valid=1'b1; // 原生像素逐拍写；需要配对的层仅齐字后写。
        code_ready= direct_ab ? sink_ready : (!code_valid || !in_range || (c32_layer && !code_batch) || (direct_layer && !code_x[0]) || sink_ready); // 首半字只写暂存。
        if (code_valid && in_range && ((c32_layer && code_batch) || (direct_layer && code_x[0])) && !pair_valid_q) code_ready=1'b0; // 只检查真实返回，空闲不得按旧奇列阻止行排空。
        if (code_valid && in_range && ((c32_layer && !code_batch) || (direct_layer && !code_x[0])) && pair_valid_q) code_ready=1'b0; // 真实前半字不得覆盖暂存，空闲ready正常恢复。
        if (layer_id==5'd16) code_ready=1'b1;              // RGB 最终像素绕过存储。
    end                                                         // 写口组合结束。
    always_ff @(posedge clk) begin                              // 唯一必要的数据暂存。
        if (reset) begin                                        // 同步复位。
            pair_valid_q<=1'b0;                                 // 无待配 C16 偶列或 C32 低批。
            saved_lanes_q<='0;                                  // 共用码暂存清零。
            protocol_error<=1'b0;                               // 清错误。
        end else begin                                          // 正常输出整理。
            if(prefix_write && layer_id==16)saved_lanes_q<=prefix_data; // RGB阶段独占，配对阶段禁止外部覆盖。
            else if (code_valid && code_ready && in_range && ((c32_layer && !code_batch) || (direct_layer && !code_x[0]))) // 两种配对用途共用原始码。
                saved_lanes_q<=code_lanes; // C16偶列先恢复自然序，C32低批原样保存至跨批恢复。
            if (code_valid && code_ready && in_range && (c32_layer || direct_layer)) begin // C16 偶奇与 C32 双批共用配对状态。
                if (c32_layer ? !code_batch : !code_x[0]) pair_valid_q<=1'b1; // 收到前半字，等待后半字。
                else pair_valid_q<=1'b0;                       // 后半字已提交整字。
            end                                                 // 配对状态更新结束。
            if (code_valid && !code_ready) protocol_error<=1'b1; // 上游无回压口，阻塞必须暴露。
            if (code_valid && !(direct_ab || direct_layer || c32_layer || doubled_layer || layer_id==5'd16)) protocol_error<=1'b1; // 未知层。
        end                                                     // 正常状态结束。
    end                                                         // 暂存与自查结束。
`ifdef SIM_ASSERT // Early classification must equal the original predicate on every valid result.
    always @(posedge clk)if(!reset && code_valid &&
        code_in_range !== (code_x>=emit_lo && code_x<emit_hi))
        $fatal(1,"RESULT early range bit does not match row geometry");
`endif
`ifdef SIM_ASSERT // 外部前缀复用不允许破坏在途配对。
    always @(posedge clk)if(!reset && prefix_write && (layer_id!=16 || pair_valid_q || code_valid))$fatal(1,"RESULT prefix ownership"); // 必须处于排空后的RGB阶段。
`endif // 仿真契约结束。
endmodule                                                       // 结果整理器结束。
