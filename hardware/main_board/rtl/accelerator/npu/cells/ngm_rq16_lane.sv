/* OPTIMIZATION_NOTE_20261005
 * 固定量化合同（2026-10-05）：pre_shift仅0..2，舍入后须能用signed19位精确表示。
 * 有效通道post_shift仅20..28；0仅用于未用通道填充，不能当作有效通道的通用不移位运算。
 * 这是已有固定模型部署边界，共享舍入加法器未新增限制；同结构新权重重新标定也须复核。
 * 超范围输入无硬件拒绝保证：SIM_ASSERT在综合后不存在，部署前检查而非上板碰运气。
 * round-to-even、溢出/饱和及两拍valid合同不变；改移位窗口须重新验证极值及上下游对齐。
 * 详见 docs/OPTIMIZATION_CONSTRAINTS.md。
 */
// 协议契约：输入到码值仍为两拍；第二拍寄存完成舍入、饱和及ReLU的最终8位码。
// 本模块吞吐仍为每拍一批，valid同步复位；所有数值标志与ReLU随同一乘积过流水。
// 一条 RQ16-Narrow 重量化 lane。
// // 重量化字段赋值、表达式或语句边界。
// 运算链（主 Spec §50）：
//   INT24 累加值（已含 folded bias）
//     -> round-to-even 右移 pre_shift（每层固定，0..2）
//     -> signed 19 位
//     -> × M18（一颗 19×18 DSP，M18 归一化到 [2^16, 2^17)，无需符号补偿）
//     -> round-to-even 右移 post_shift（每输出通道一个）
//     -> 饱和到 INT8
//     -> 可选 ReLU6
// // 重量化字段赋值、表达式或语句边界。
// 【post_shift 只用窄档选择，不做通用桶形移位器】
// post_shift 由标定决定（= 16 − floor(log2(requant_scale × 2^pre_shift))），
// 换权重重新标定会让整组值整体漂移；实测漂移量级是 ±1~2。当前导出包的真实通道
// 落在 {22..26}（0 只出现在 head/rgb 未用通道的填充槽），窗口按 ±2 取 {20..28}。
// 所以这里按这 9 个移位切固定的商+保护位窗口，而不是搭一条通用移位器——
// 实测 16 lane 从 4,349 LUT 降到 1,576 LUT。
// // 重量化字段赋值、表达式或语句边界。
// 若重新标定后有效通道post_shift漂出{20..28}，须在部署前拒绝该包并重新评窗口；SIM_ASSERT只在仿真检查。
module ngm_rq16_lane ( // 单车道重量化接口。
    input  logic               clk, // 本批输入或同步控制。
    input  logic               reset, // 本批输入或同步控制。
    input  logic               in_valid, // 本批输入或同步控制。
    input  logic signed [23:0] accumulator, // 本批输入或同步控制。
    input  logic        [2:0]  pre_shift, // 本批输入或同步控制。
    input  logic        [16:0] multiplier_m18, // 本批输入或同步控制。
    input  logic        [4:0]  post_shift, // 本批输入或同步控制。
    input  logic               relu6_enable, // 本批输入或同步控制。
    output logic               out_valid, // 第二拍输出码值与有效位。
    output logic signed [7:0]  output_code // 第二拍输出码值与有效位。
); // 重量化字段赋值、表达式或语句边界。
    logic signed [23:0] pre_shifted_s24; // 重量化中间量或流水字段。
    logic signed [18:0] pre_shifted_s19; // 重量化中间量或流水字段。
    logic signed [36:0] product_s37; // 重量化中间量或流水字段。
    logic               multiplier_valid; // 重量化中间量或流水字段。

    logic        [4:0]  post_shift_stage1; // 重量化中间量或流水字段。
    logic               relu6_stage1; // 重量化中间量或流水字段。

    // 窄档窗口：9 个合法移位各自切 9 位 [商 8 位 | 保护位 1 位]
    logic        [8:0]  quotient_guard_window; // 重量化中间量或流水字段。
    logic               sticky_bit; // 重量化中间量或流水字段。
    logic               quotient_overflow; // 重量化中间量或流水字段。

    logic signed [7:0]  quotient_s8; // 重量化中间量或流水字段。
    logic               guard_bit; // 重量化中间量或流水字段。
    logic               round_up; // 重量化中间量或流水字段。
    logic signed [7:0]  rounded_s8; // 重量化中间量或流水字段。
    logic signed [7:0]  saturated_s8; // 重量化中间量或流水字段。

    assign pre_shifted_s24 = round_even_pre_shift(accumulator, pre_shift); // 固定连线及对应数值关系。
    assign pre_shifted_s19 = pre_shifted_s24[18:0]; // 固定连线及对应数值关系。

    // Factor the fixed 20-bit base shift from the remaining 0..8 positions.
    wire [3:0] residual_shift = 4'(post_shift_stage1 - 5'd20);
    wire signed [17:0] shifted_tail = $signed(product_s37[36:19]) >>> residual_shift;
    wire [7:0] sticky_mask = ~(8'hff << residual_shift);
    wire post_legal = post_shift_stage1 >= 20 && post_shift_stage1 <= 28;
    always_comb begin
        quotient_guard_window = post_legal ? shifted_tail[8:0] : 9'd0;
        sticky_bit = post_legal && ((|product_s37[18:0]) ||
                                   (|(product_s37[26:19] & sticky_mask)));
        quotient_overflow = post_legal &&
                            (|(shifted_tail[17:8] ^ {10{product_s37[36]}}));
    end

    logic valid_q;
    logic signed [7:0] next_code;
    // Keep the same second stage: register the finished code, rather than
    // guard/overflow flags that would leave rounding on the RAM-write path.
    // Eight data bits replace thirteen flag/data bits per lane; no extra cycle.
    always_ff @(posedge clk) begin
        if(reset)valid_q<=1'b0;else valid_q<=multiplier_valid;
        output_code<=next_code;
    end

    assign quotient_s8 = $signed(quotient_guard_window[8:1]); // 固定连线及对应数值关系。
    assign guard_bit   = quotient_guard_window[0]; // 固定连线及对应数值关系。

    always_comb begin // 当前流水区段组合计算。
        round_up   = guard_bit && (sticky_bit || quotient_s8[0]); // 重量化字段赋值、表达式或语句边界。
        rounded_s8 = quotient_s8 + round_up; // 重量化字段赋值、表达式或语句边界。

        if (quotient_overflow || // 依据当前流水参数选择结果。
            (!product_s37[36] && quotient_s8 == 8'sd127 && round_up)) begin // 重量化字段赋值、表达式或语句边界。
            saturated_s8 = product_s37[36] ? -8'sd127 : 8'sd127; // 重量化字段赋值、表达式或语句边界。
        end else if (quotient_s8 == -8'sd128) begin // 当前分支或区段结束。
            saturated_s8 = -8'sd127; // 重量化字段赋值、表达式或语句边界。
        end else begin // 当前分支或区段结束。
            saturated_s8 = rounded_s8; // 重量化字段赋值、表达式或语句边界。
        end // 当前分支或区段结束。

        if (relu6_stage1 && saturated_s8 < 0) // 依据当前流水参数选择结果。
            next_code = 8'sd0; // 第二拍输出码值与有效位。
        else // 对应条件的其他分支。
            next_code = saturated_s8; // 第二拍输出码值与有效位。
    end // 当前分支或区段结束。

    assign out_valid = valid_q; // 固定连线及对应数值关系。

    ngm_rq16_mult u_rq16_mult ( // 重量化字段赋值、表达式或语句边界。
        .clk            (clk), // 乘法器参数或数据端口连接。
        .reset          (reset), // 乘法器参数或数据端口连接。
        .in_valid       (in_valid), // 乘法器参数或数据端口连接。
        .value_s19      (pre_shifted_s19), // 乘法器参数或数据端口连接。
        .multiplier_m18 (multiplier_m18), // 乘法器参数或数据端口连接。
        .out_valid      (multiplier_valid), // 乘法器参数或数据端口连接。
        .product        (product_s37) // 乘法器参数或数据端口连接。
    ); // 重量化字段赋值、表达式或语句边界。

    always_ff @(posedge clk) begin // 逐拍保存量化参数或有效位。
        if (reset) begin // 依据当前流水参数选择结果。
            post_shift_stage1 <= '0; // 重量化字段赋值、表达式或语句边界。
            relu6_stage1      <= 1'b0; // 重量化字段赋值、表达式或语句边界。
        end else begin // 当前分支或区段结束。
            post_shift_stage1 <= post_shift; // 重量化字段赋值、表达式或语句边界。
            relu6_stage1      <= relu6_enable; // 重量化字段赋值、表达式或语句边界。
        end // 当前分支或区段结束。
    end // 当前分支或区段结束。

    // Select the quotient first; all legal pre-shifts share one rounding adder.
    function automatic logic signed [23:0] round_even_pre_shift(
        input logic signed [23:0] value,
        input logic [2:0] shift
    );
        logic signed [23:0] quotient;
        logic increment;
        begin
            quotient = value;
            increment = 1'b0;
            case (shift)
                3'd1: begin
                    quotient = value >>> 1;
                    increment = value[0] && value[1];
                end
                3'd2: begin
                    quotient = value >>> 2;
                    increment = value[1] && (value[0] || value[2]);
                end
                default: begin end
            endcase
            round_even_pre_shift = quotient + 24'(increment);
        end
    endfunction

`ifdef SIM_ASSERT // 仿真检查编译边界。
    always_ff @(posedge clk) begin // 逐拍保存量化参数或有效位。
        if (!reset && in_valid) begin // 依据当前流水参数选择结果。
            if (pre_shift > 3'd2) // 依据当前流水参数选择结果。
                $fatal(1, "RQ16 pre_shift exceeds the exported 0..2 range"); // 非法量化输入必须触发失败。
            if (pre_shifted_s24[23:19] != {5{pre_shifted_s24[18]}}) // 依据当前流水参数选择结果。
                $fatal(1, "RQ16 pre-shift result does not fit signed 19-bit"); // 非法量化输入必须触发失败。
            if (post_shift != 5'd0 && // 依据当前流水参数选择结果。
                (post_shift < 5'd20 || post_shift > 5'd28)) // 重量化字段赋值、表达式或语句边界。
                $fatal(1, "RQ16 post_shift is outside the 20..28 window"); // 非法量化输入必须触发失败。
        end // 当前分支或区段结束。
    end // 当前分支或区段结束。
`endif // 仿真检查编译边界。
endmodule // 当前分支或区段结束。
