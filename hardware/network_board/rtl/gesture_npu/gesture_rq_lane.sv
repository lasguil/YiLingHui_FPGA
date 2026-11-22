// 一条重量化车道。硬件定式（与 tools/int8_reference.py 的 golden 逐位一致）：
//
//     p      = Σ a_signed * w                       （只含 MAC 和，不含偏置）
//     y_code = clamp8( rne( ((p * m18) >> (post-10)) + B_fixed , 10 ) + zp )
//
// 为什么偏置不以整数形式进累加器：layer 50/54 的通道权重 scale 低到 4.7e-9，
// 导致 bias_q 高达 6.9e8（2^29.4），任何合理位宽的累加器都装不下。把偏置预先
// 折算到与乘积同一个已移位定标域（单位 2^-10 个输出码）后，实测 |B_fixed| ≤ 2^27，
// 而净精度损失 < 0.001 个输出码（见 tools/requant_formulation_check.py）。
//
// 两级流水：S1 出乘积，S2 出码值。有效的连续通道可以背靠背。
module gesture_rq_lane #(
    parameter bit USE_DSP = 1'b1,
    parameter int ACC_WIDTH = 32
) (
    input  logic               clk,
    input  logic               reset,
    input  logic               in_valid,
    input  logic signed [31:0] in_acc,
    input  logic        [16:0] in_m18,
    input  logic        [5:0]  in_post,
    input  logic signed [31:0] in_bfix,
    input  logic        [7:0]  in_zp,
    output logic               out_valid,
    output logic        [7:0]  out_code,
    output logic signed [21:0] out_fixed_q10
);
    localparam int PROD_W = 32 + 17;        // 49
    localparam int TOT_W  = PROD_W + 32;    // 81
    localparam int KEEP   = 22;             // 保留 ±2^21，即 ±2048 个输出码

    // ---- S1：乘法 ----
    logic signed [PROD_W-1:0] prod_q;
    logic signed [PROD_W-1:0] prod_stage_q;
    logic        [16:0]       m18_q;
    logic        [5:0]        post_q;
    logic signed [31:0]       bfix_q;
    logic        [7:0]        zp_q;
    logic        [5:0]        post_q2;
    logic signed [31:0]       bfix_q2;
    logic        [7:0]        zp_q2, zp_stage_q;
    logic                     valid_q, valid_q2, valid_q3;
    logic signed [KEEP-1:0]   totc;
    logic signed [KEEP-1:0]   totc_stage_q;

    logic        [18:0] rq_a_lo;
    logic signed [18:0] rq_a_hi;
    logic        [17:0] rq_b;
    logic        [33:0] rq_a_lo_ext_u, rq_b_ext_u;
    logic signed [32:0] rq_a_hi_ext_s, rq_b_ext_s;
    assign rq_a_lo = {3'b000, in_acc[15:0]};
    assign rq_a_hi = {{3{in_acc[31]}}, in_acc[31:16]};
    assign rq_b = {1'b0, in_m18};
    assign rq_a_lo_ext_u = {18'd0, in_acc[15:0]};
    assign rq_b_ext_u = {17'd0, in_m18};
    assign rq_a_hi_ext_s = {{17{in_acc[31]}}, in_acc[31:16]};
    assign rq_b_ext_s = {16'd0, in_m18};

    function automatic logic signed [PROD_W-1:0] mul_fabric(
        input logic signed [31:0] a,
        input logic        [16:0] b);
        logic signed [PROD_W-1:0] a_ext;
        logic signed [PROD_W-1:0] acc;
        begin
            a_ext = {{(PROD_W-32){a[31]}}, a};
            acc = '0;
            for (int bit_idx = 0; bit_idx < 17; bit_idx++)
                if (b[bit_idx]) acc = acc + (a_ext <<< bit_idx);
            mul_fabric = acc;
        end
    endfunction

    function automatic logic signed [24:0] mul8_fabric(
        input logic signed [7:0] a,
        input logic        [16:0] b);
        logic signed [24:0] a_ext;
        logic signed [24:0] acc;
        begin
            a_ext = {{17{a[7]}}, a};
            acc = '0;
            for (int bit_idx = 0; bit_idx < 17; bit_idx++)
                if (b[bit_idx]) acc = acc + (a_ext <<< bit_idx);
            mul8_fabric = acc;
        end
    endfunction

    generate if (USE_DSP && ACC_WIDTH == 8) begin : g_dsp8_mul
`ifdef FAST_SIM
        logic signed [24:0] rq_prod8_sim_q;
        logic signed [24:0] rq_a8_ext, rq_b8_ext;
        always_comb begin
            rq_a8_ext = {{17{in_acc[7]}}, in_acc[7:0]};
            rq_b8_ext = {8'd0, in_m18};
        end
        always_ff @(posedge clk) begin
            if (reset) rq_prod8_sim_q <= '0;
            else rq_prod8_sim_q <= rq_a8_ext * rq_b8_ext;
        end
        always_comb prod_q = {{(PROD_W-25){rq_prod8_sim_q[24]}}, rq_prod8_sim_q};
`else
        logic signed [18:0] rq_a8_dsp;
        logic signed [17:0] rq_b8_dsp;
        logic [47:0] rq_prod8_dsp;
        assign rq_a8_dsp = {{11{in_acc[7]}}, in_acc[7:0]};
        assign rq_b8_dsp = {1'b0, in_m18};
        EFX_DSP48 #(
            .MODE("NORMAL"), .A_REG(0), .B_REG(0), .C_REG(0), .P_REG(1),
            .OP_REG(0), .W_REG(0), .O_REG(0), .SHIFTER(0), .SIGNED(1),
            .P_EXT("ALIGN_RIGHT"), .C_EXT("ALIGN_RIGHT"), .M_SEL("P"),
            .N_SEL("CONST0"), .W_SEL("X"), .CASCOUT_SEL("W")
        ) u_rq_mul8 (
            .A(rq_a8_dsp), .B(rq_b8_dsp), .C(18'd0), .CASCIN(48'd0), .OP(2'b00),
            .SHIFT_ENA(1'b0), .CLK(clk), .CE(1'b1), .RST(reset),
            .O(rq_prod8_dsp), .CASCOUT(), .OVFL()
        );
        always_comb prod_q = {{(PROD_W-25){rq_prod8_dsp[24]}}, rq_prod8_dsp[24:0]};
`endif
    end else if (USE_DSP) begin : g_dsp_mul
`ifdef FAST_SIM
        logic        [33:0] rq_prod_lo_sim_q;
        logic signed [32:0] rq_prod_hi_sim_q;
        always_ff @(posedge clk) begin
            if (reset) begin
                rq_prod_lo_sim_q <= '0;
                rq_prod_hi_sim_q <= '0;
            end else begin
                rq_prod_lo_sim_q <= rq_a_lo_ext_u * rq_b_ext_u;
                rq_prod_hi_sim_q <= rq_a_hi_ext_s * rq_b_ext_s;
            end
        end
        always_comb begin
            prod_q = {{(PROD_W-34){1'b0}}, rq_prod_lo_sim_q}
                   + ({{(PROD_W-33){rq_prod_hi_sim_q[32]}}, rq_prod_hi_sim_q} <<< 16);
        end
`else
        logic [47:0] rq_prod_lo_dsp, rq_prod_hi_dsp;
        EFX_DSP48 #(
            .MODE("NORMAL"), .A_REG(0), .B_REG(0), .C_REG(0), .P_REG(1),
            .OP_REG(0), .W_REG(0), .O_REG(0), .SHIFTER(0), .SIGNED(0),
            .P_EXT("ALIGN_RIGHT"), .C_EXT("ALIGN_RIGHT"), .M_SEL("P"),
            .N_SEL("CONST0"), .W_SEL("X"), .CASCOUT_SEL("W")
        ) u_rq_mul_lo (
            .A(rq_a_lo), .B(rq_b), .C(18'd0), .CASCIN(48'd0), .OP(2'b00),
            .SHIFT_ENA(1'b0), .CLK(clk), .CE(1'b1), .RST(reset),
            .O(rq_prod_lo_dsp), .CASCOUT(), .OVFL()
        );
        EFX_DSP48 #(
            .MODE("NORMAL"), .A_REG(0), .B_REG(0), .C_REG(0), .P_REG(1),
            .OP_REG(0), .W_REG(0), .O_REG(0), .SHIFTER(0), .SIGNED(1),
            .P_EXT("ALIGN_RIGHT"), .C_EXT("ALIGN_RIGHT"), .M_SEL("P"),
            .N_SEL("CONST0"), .W_SEL("X"), .CASCOUT_SEL("W")
        ) u_rq_mul_hi (
            .A(rq_a_hi), .B(rq_b), .C(18'd0), .CASCIN(48'd0), .OP(2'b00),
            .SHIFT_ENA(1'b0), .CLK(clk), .CE(1'b1), .RST(reset),
            .O(rq_prod_hi_dsp), .CASCOUT(), .OVFL()
        );
        always_comb begin
            prod_q = {{(PROD_W-33){1'b0}}, rq_prod_lo_dsp[32:0]}
                   + ({{(PROD_W-33){rq_prod_hi_dsp[32]}}, rq_prod_hi_dsp[32:0]} <<< 16);
        end
`endif
    end else if (ACC_WIDTH == 8) begin : g_fabric8_mul
        logic signed [24:0] rq_prod8_q;
        always_ff @(posedge clk) begin
            if (reset) rq_prod8_q <= '0;
            else rq_prod8_q <= mul8_fabric(in_acc[7:0], in_m18);
        end
        always_comb prod_q = {{(PROD_W-25){rq_prod8_q[24]}}, rq_prod8_q};
    end else begin : g_fabric_mul
        always_ff @(posedge clk) begin
            if (reset) prod_q <= '0;
            else prod_q <= mul_fabric(in_acc, in_m18);
        end
    end endgenerate

    always_ff @(posedge clk) begin
        if (reset) begin
            valid_q <= 1'b0;
            valid_q2 <= 1'b0;
            valid_q3 <= 1'b0;
            prod_stage_q <= '0;
            m18_q   <= '0;
            post_q  <= '0;
            bfix_q  <= '0;
            zp_q    <= '0;
            post_q2 <= '0;
            bfix_q2 <= '0;
            zp_q2 <= '0;
            zp_stage_q <= '0;
            totc_stage_q <= '0;
        end else begin
            valid_q <= in_valid;
            valid_q2 <= valid_q;
            valid_q3 <= valid_q2;
            prod_stage_q <= prod_q;
            m18_q   <= in_m18;
            post_q  <= in_post;
            bfix_q  <= in_bfix;
            zp_q    <= in_zp;
            post_q2 <= post_q;
            bfix_q2 <= bfix_q;
            zp_q2 <= zp_q;
            zp_stage_q <= zp_q2;
            totc_stage_q <= totc;
        end
    end

    // ---- S2：移位 + 加偏置 + 舍入 + 饱和 ----
    // post ∈ [14,51] ⇒ (post-10) ∈ [4,41]，6 位桶形移位器足够。
    logic signed [PROD_W-1:0] shift_stage [0:6];
    logic        [5:0]        sh;

    always_comb begin
        sh = post_q2 - 6'd10;
        shift_stage[0] = prod_stage_q;
        for (int i = 0; i < 6; i++)
            shift_stage[i+1] = sh[i] ? (shift_stage[i] >>> (1 << i)) : shift_stage[i];
    end

    logic signed [TOT_W-1:0] total;
    assign total = {{(TOT_W-PROD_W){shift_stage[6][PROD_W-1]}}, shift_stage[6]} +
                   {{(TOT_W-32){bfix_q2[31]}}, bfix_q2};

    // 先把 total 夹进 22 位窗口：±2048 个输出码远在 [0,255] 之外，
    // 之后再做码值饱和，语义与直接算全宽完全相同。
    logic                  ovf;
    always_comb begin
        ovf  = |(total[TOT_W-1:KEEP] ^ {(TOT_W-KEEP){total[KEEP-1]}});
        totc = ovf ? (total[TOT_W-1] ? {1'b1, {(KEEP-1){1'b0}}} : {1'b0, {(KEEP-1){1'b1}}})
                   : total[KEEP-1:0];
    end

    // rne(·, 10)：算术右移是向下取整，余数天然落在 [0,1024)。
    // 注意：`rounded` 是有符号的，与 zero point 相加时必须显式补符号，
    // 否则无符号操作数会把整个表达式拉成无符号、后面的比较全部失效。
    logic signed [KEEP-1:0] quotient;
    logic        [9:0]      remainder;
    logic                   round_up;
    logic signed [KEEP-1:0] rounded;
    logic signed [KEEP:0]   with_zp;
    logic        [7:0]      next_code;

    localparam signed [KEEP:0] CODE_MAX = 23'sd255;
    localparam signed [KEEP:0] CODE_MIN = 23'sd0;

    always_comb begin
        quotient   = totc_stage_q >>> 10;
        remainder  = totc_stage_q[9:0];
        round_up   = (remainder > 10'd512) | ((remainder == 10'd512) & quotient[0]);
        rounded    = quotient + round_up;
        with_zp    = rounded + $signed({1'b0, zp_stage_q});
        if (with_zp > CODE_MAX)
            next_code = 8'd255;
        else if (with_zp < CODE_MIN)
            next_code = 8'd0;
        else
            next_code = with_zp[7:0];
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            out_valid <= 1'b0;
            out_code  <= 8'd0;
            out_fixed_q10 <= '0;
        end else begin
            out_valid <= valid_q3;
            out_code  <= next_code;
            out_fixed_q10 <= totc_stage_q;
        end
    end

`ifdef SIM_ASSERT
    // m18 必须归一化到 [2^16,2^17)，post 必须落在导出窗口内。
    // 换权重重新标定后若漂出窗口，导出侧就该拒绝该包——直接报错，不要上板碰运气。
    always_ff @(posedge clk) begin
        if (!reset && in_valid) begin
            if (!in_m18[16])
                $fatal(1, "rq_lane: M18 outside the [2^16,2^17) window: %0d", in_m18);
            if (in_post < 6'd14 || in_post > 6'd51)
                $fatal(1, "rq_lane: post_shift %0d outside the [14,51] window", in_post);
        end
    end
`endif
endmodule
