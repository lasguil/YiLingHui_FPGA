// 协议契约：19位有符号值乘非负10位系数，P寄存一拍；CE冻结乘积，无valid隐藏等待。
module ipx_mult( // 饱和度和混合均可使用同一原语包装，实例各自独立。
    input logic clk,enable, // 公共流水推进。
    input logic signed [18:0] value, // 显式扩展的有符号值。
    input logic [9:0] coefficient, // 0..512，补零后按有符号解释。
    output wire signed [28:0] product // 足够保存完整乘积。
); // 接口结束。
`ifdef FAST_SIM // 经厂商原语对照的一拍有符号乘法模型，仅加速长帧仿真。
    logic signed [28:0] product_q=0; // 与厂商仿真模型的P寄存器初始值一致，正式综合分支没有此初始化。
    assign product=product_q; // 输出寄存行为与P_REG=1相同。
    always @(posedge clk)if(enable)product_q<=value*$signed({1'b0,coefficient}); // CE关闭时保持。
`else // 正式综合必须使用DSP48。
    wire [47:0] result; // 厂商DSP输出。
    EFX_DSP48 #(.MODE("NORMAL"),.A_REG(0),.B_REG(0), // 不增加MAC反馈依赖。
        .P_REG(1),.O_REG(0),.SIGNED(1), // 不增加MAC反馈依赖。
        .M_SEL("P"),.N_SEL("CONST0"),.W_SEL("X")) u_dsp( // 不增加MAC反馈依赖。
        .A(value),.B({8'b0,coefficient}),.C(18'b0), // 只复位valid，不复位算术数据。
            .CASCIN(48'b0),.OP(2'b00),.SHIFT_ENA(1'b0), // 只复位valid，不复位算术数据。
            .CLK(clk),.CE(enable),.RST(1'b0), // 只复位valid，不复位算术数据。
            .O(result),.CASCOUT(),.OVFL()); // 只复位valid，不复位算术数据。
    assign product=$signed(result[28:0]); // 不截断有效符号位。
`endif // 原语模型选择结束。
endmodule // DSP包装结束。
