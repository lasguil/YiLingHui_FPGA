// 协议契约：单套768×8曲线/配色表，p0/p1/p2读RGB，p1/p2/p3接收；仅IDLE装载。
module ipx_curve( // RGB曲线、灰度配色、灰度/彩色有序网点使用同一RAM。
    input logic clk,clear,step, // clear不清表内容。
    input logic [1:0] phase, // 三次读和一拍拼装。
    input wire ipx_types::config_t cfg, // 固定寻址模式。
    input logic table_write, // 已由控制面检查完整装载。
    input logic [9:0] table_address, // 0..767。
    input logic [5:0] table_data, // 一个曲线元素。
    input logic in_valid, // 颜色token有效。
    input logic [17:0] in_data, // 先饱和度再查表。
    input wire ipx_types::meta_t in_meta, // 坐标阈值与原始值。
    output logic out_valid, // 当前表结果。
    output logic [17:0] out_data, // 串行查表拼成RGB。
    output ipx_types::meta_t out_meta // 元数据同步推进。
); // 接口结束。
    import ipx_types::*; // 灰度/通道函数。
    logic [11:0] partial_q; // R/G回读工作寄存。
    logic [7:0] index; // 当前寻址值与同步返回。
    wire [5:0] returned; // 当前寻址值与同步返回。
    wire [5:0] threshold={in_meta.pattern,2'b10}; // 16T+8。
    wire [9:0] address={phase,index}; // channel*256+index。
    always_comb begin // 模式互斥，共用三个读时隙。
        case(cfg.color) // 0=RGB，1=灰度配色，2=双色网点，3=彩色网点。
            0:index=u6_to_u8(component(in_data,phase)); // 精确曲线或灰度。
            1:index=u6_to_u8(gray(in_data)); // 精确曲线或灰度。
            2:index=gray(in_data)>=threshold?8'hff:8'h00; // 有序双色阈值。
            default:index=component(in_data,phase)>=threshold?8'hff:8'h00; // 同图案三通道。
        endcase // 寻址选择结束。
    end // 组合结束。
    ipx_ram #(.WIDTH(6),.DEPTH_BITS(10),.SLICE(10)) u_table(.clk(clk), // 一块RAM10。
        .read_enable(step&&phase<3&&in_valid),.write_enable(table_write),.read_address(address), // 一块RAM10。
        .write_address(table_address),.write_data(table_data),.read_data(returned)); // 一块RAM10。
    always_ff @(posedge clk)begin // RAM一拍延迟与通道对齐。
        if(clear)out_valid<=0; // 表仍由独立TABLE_VALID保护。
        else if(step)begin // 停顿时读口和结果一起保持。
            if(phase==1)partial_q[5:0]<=returned; // p1收R，固定位置写使能。
            if(phase==2)partial_q[11:6]<=returned; // p2收G，不使用可变位选择写口。
            if(phase==3)begin out_data<={returned,partial_q}; // 完整RGB一次发布。
                out_valid<=in_valid; // 完整RGB一次发布。
                out_meta<=in_meta; // 完整RGB一次发布。
            end // 完整RGB一次发布。
        end // 推进结束。
    end // 曲线寄存器结束。
endmodule // 曲线/配色结束。
