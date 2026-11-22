// 协议契约：同步读一拍，read_enable暂停时保持输出；写入不复位数据，禁止同拍同址读写。
module ipx_ram #(parameter int WIDTH=8,DEPTH_BITS=10,SLICE=8)( // 明确指定RAM10的合法纵横比。
    input logic clk,read_enable,write_enable, // 独立读写使能。
    input logic [DEPTH_BITS-1:0] read_address,write_address, // 逻辑字地址。
    input logic [WIDTH-1:0] write_data, // 实际有效位宽。
    output wire [WIDTH-1:0] read_data // 同步读结果。
); // 接口结束。
`ifdef FAST_SIM // 与厂商模型先对照，完整帧使用同延迟的合并位宽模型。
    logic [WIDTH-1:0] storage[0:(1<<DEPTH_BITS)-1]; // 一读一写，无额外端口。
    logic [WIDTH-1:0] returned_q=0; // 厂商模型同步读输出初值为零，存储阵列仍不初始化。
    assign read_data=returned_q; // 保持一拍同步读契约。
    always @(posedge clk)begin // 使能关闭时返回寄存器保持。
        if(read_enable)returned_q<=storage[read_address]; // 禁止同址碰撞。
        if(write_enable)storage[write_address]<=write_data; // 禁止同址碰撞。
    end // 仿真模型结束。
`else // 综合例化合法纵横比。
    localparam int BLOCKS=(WIDTH+SLICE-1)/SLICE; // 形状位宽决定块数。
    wire [BLOCKS*SLICE-1:0] padded_write={{(BLOCKS*SLICE-WIDTH){1'b0}},write_data}; // 最后块补零。
    wire [BLOCKS*SLICE-1:0] padded_read; // 完整原语读口。
    assign read_data=padded_read[WIDTH-1:0]; // 舍弃未使用填充位。
    for(genvar bank=0;bank<BLOCKS;bank++)begin:g_bank // 不创建额外读口。
        EFX_RAM10 #(.READ_WIDTH(SLICE),.WRITE_WIDTH(SLICE),.OUTPUT_REG(0), // 同址必须由调度规避。
            .WRITE_MODE("READ_UNKNOWN"),.RESET_RAM("NONE"),.RESET_OUTREG("NONE")) u_ram( // 同址必须由调度规避。
            .WCLK(clk),.WE({write_enable,write_enable}),.WCLKE(1'b1), // 完整字写。
                .WADDREN(1'b1),.WDATA(padded_write[bank*SLICE+:SLICE]),.WADDR(write_address), // 完整字写。
            .RCLK(clk),.RE(read_enable),.RST(1'b0), // 不复位RAM数据。
                .RADDREN(1'b1),.RDATA(padded_read[bank*SLICE+:SLICE]),.RADDR(read_address)); // 不复位RAM数据。
    end // 原语阵列结束。
`endif // 原语模型选择结束。
`ifdef SIM_ASSERT // 端口碰撞必须证伪。
    always @(posedge clk)if(read_enable&&write_enable&&read_address==write_address)$fatal(1,"IPX RAM collision"); // 不依赖仿真碰撞模式。
`endif // 检查结束。
endmodule // RAM包装结束。
