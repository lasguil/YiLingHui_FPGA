// 协议契约：深度8，push/pop为实际握手；clear仅在无在途总线时使用，数据阵列不复位。
module ipx_fifo8 #(parameter int WIDTH=128,INVERT_INPUT=1)( // 宽读窄深度FIFO显式使用SRL8，可直接保存原语补码极性。
    input logic clk,clear,push,pop, // 同步控制，支持同时进出。
    input logic [WIDTH-1:0] data_in, // 每一位独立移入。
    output wire [WIDTH-1:0] data_out, // INVERT_INPUT=1返回原值，=0返回补码；等待时保持。
    output logic [3:0] count // 唯一占用计数，0..8。
); // 接口结束。
`ifdef FAST_SIM // 仅仿真加速，先用厂商模型对照证明相同抽头/时钟行为。
    logic [WIDTH-1:0] storage[0:7]; // 合并位切片，避免逐位事件调度。
    assign data_out=INVERT_INPUT?storage[3'(count)-3'd1]:~storage[3'(count)-3'd1]; // 明确SRL8的反相抽头。
    always @(posedge clk)if(push&&!clear)begin // 只移入真实握手。
        storage[0]<=data_in; // 与SRL8逐位移位等价。
        for(int entry=1;entry<8;entry++)storage[entry]<=storage[entry-1]; // 与SRL8逐位移位等价。
    end // 仿真存储结束。
`else // 正式综合只包含明确的SRL8。
    wire [2:0] address=~(3'(count)-3'd1); // 抽头为count-1，厂商地址取反。
    for(genvar bit_index=0;bit_index<WIDTH;bit_index++)begin:g_bit // 每位一个XLR，不推断宽FF阵列。
        EFX_SRL8 u_srl(.D(INVERT_INPUT?~data_in[bit_index]:data_in[bit_index]),.A(address),.CLK(clk), // 数据极性在8位适配器中消化，避免128位额外反相。
            .CE(push&&!clear),.Q(data_out[bit_index]),.Q7()); // 数据极性在8位适配器中消化，避免128位额外反相。
    end // 存储例化结束。
`endif // 两种原语模型选择结束。
    always_ff @(posedge clk)begin // 只复位占用，不复位数据。
        if(clear)count<=0; // 新任务丢弃旧无效槽。
        else case({push,pop})2'b10:count<=count+1'b1; // 同时进出占用不变。
            2'b01:count<=count-1'b1; // 同时进出占用不变。
            default:count<=count; // 同时进出占用不变。
        endcase // 同时进出占用不变。
    end // FIFO控制结束。
`ifdef SIM_ASSERT // 仿真检查不会改变电路。
    always @(posedge clk)if(!clear)begin // 检查实际握手。
        if(push&&count==8&&!pop)$fatal(1,"IPX FIFO overflow"); // 禁止覆盖队首。
        if(pop&&count==0)$fatal(1,"IPX FIFO underflow"); // 禁止消费无效抽头。
    end // 检查结束。
`endif // 断言结束。
endmodule // FIFO结束。
