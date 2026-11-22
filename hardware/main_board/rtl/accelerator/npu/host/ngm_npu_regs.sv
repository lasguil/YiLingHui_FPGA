// 协议契约：所有软件寄存器、WSTRB、副作用和响应保持原行为；配置字节用窄CE写入，删除宽掩码与反馈合并。
// 寄存器字节地址：00命令(bit0帧/bit1权重，互斥)，04状态，08事件W1C，0C中断使能低4位。
// 10尺寸{5'b0,height4[10:0],5'b0,width4[10:0]}按高16/低16存放；14/18/1C为输入/输出/X0基址。
// 20/24/28为对应字节行跨度；2C权重包地址；30写bit0清性能计数；40..50五项计数。
// RGB565小端，R[15:11]/G[10:5]/B[4:0]，帧基址及行跨度须16字节对齐；跨度不得小于有效行字节数。
// 支持WSTRB逐字节写配置；新命令挂起时锁相关配置，禁止软件改未被sequencer接受的命令描述符。
// 命令写成功仅表示排队一个窄命令标志，真正frame/model握手由sequencer ready决定。
// 事件低4位依次帧成功/帧中止/模型成功/错误；同拍W1C与新事件必须保留新事件，irq为使能后事件或。
module ngm_npu_regs( // 软核命令与状态寄存器。
    input wire csr_valid,csr_write,
    input wire [11:0] csr_address,
    input wire [31:0] csr_wdata,
    input wire [3:0] csr_wstrb,
    output logic csr_ready,csr_error,
    output wire [31:0] csr_rdata,
    input logic clk,reset, // 原生寄存器接口。
    output logic frame_valid,model_valid, // 挂起命令。
    input logic frame_ready,model_ready, // 帧级控制实际接收。
    output logic [10:0] frame_width4,frame_height4, // 尺寸必须为真实图像除四。
    output logic [31:0] frame_input_base,frame_output_base,frame_x0_base,model_base, // DDR字节首地址。
    output logic [23:0] frame_input_stride,frame_output_stride,frame_x0_stride, // DDR字节行跨度。
    input logic busy,model_loaded,frame_done,frame_aborted,model_done,task_error, // 当前状态与四个终结事件。
    input logic [2:0] error_code, // 帧级错误原因。
    input logic [31:0] busy_cycles,frames,aborts,models,errors, // 性能计数读值。
    output logic perf_clear,irq // 性能清零脉冲与保持的中断电平。
); // 接口结束。
    logic [3:0] events_q,irq_enable_q;
    logic [31:0] read_value;logic read_known,write_bad; // 单份读译码和字节屏蔽。
    wire write_fire=csr_valid && csr_write && !csr_ready;
    wire [3:0] new_events={task_error,model_done,frame_aborted,frame_done}; // 单拍事件转为软件保持位。
    wire [3:0] clear_events=write_fire && csr_address==12'h008 && csr_wstrb[0] ? csr_wdata[3:0] : 4'b0; // W1C只作用低字节。
    assign irq=|(events_q & irq_enable_q); // 电平保持至软件清除。
    assign csr_rdata=read_value;
    always_comb begin // 字节掩码与命令合法性共用窄判断。
        write_bad=csr_address[1:0]!=0; // 原生寄存器接口。
        case(csr_address) // 写访问范围与挂起配置锁。
            12'h000:write_bad=write_bad || (csr_wstrb[0] && (csr_wdata[1:0]==3 || (csr_wdata[0] && frame_valid) || (csr_wdata[1] && model_valid))); // 不丢重复命令。
            12'h008,12'h00c,12'h030:begin end // W1C、中断和计数清零。
            12'h010,12'h014,12'h018,12'h01c,12'h020,12'h024,12'h028:write_bad=write_bad || frame_valid; // 帧配置尚未锁存时禁止改。
            12'h02c:write_bad=write_bad || model_valid; // 权重地址尚未锁存时禁止改。
            default:write_bad=1; // 只读及未知地址不接受写。
        endcase // 写校验结束。
        read_known=csr_address[1:0]==0;read_value=0; // 默认读零并标记错误。
        read_value=            ({32{csr_address==12'h000}} & ({30'b0,model_valid,frame_valid})) |
            ({32{csr_address==12'h004}} & ({24'b0,error_code,1'b0,model_loaded,model_ready,frame_ready,busy})) |
            ({32{csr_address==12'h008}} & ({28'b0,events_q})) |
            ({32{csr_address==12'h00c}} & ({28'b0,irq_enable_q})) |
            ({32{csr_address==12'h010}} & ({5'b0,frame_height4,5'b0,frame_width4})) |
            ({32{csr_address==12'h014}} & (frame_input_base)) |
            ({32{csr_address==12'h018}} & (frame_output_base)) |
            ({32{csr_address==12'h01c}} & (frame_x0_base)) |
            ({32{csr_address==12'h020}} & ({8'b0,frame_input_stride})) |
            ({32{csr_address==12'h024}} & ({8'b0,frame_output_stride})) |
            ({32{csr_address==12'h028}} & ({8'b0,frame_x0_stride})) |
            ({32{csr_address==12'h02c}} & (model_base)) |
            ({32{csr_address==12'h030}} & (0)) |
            ({32{csr_address==12'h040}} & (busy_cycles)) |
            ({32{csr_address==12'h044}} & (frames)) |
            ({32{csr_address==12'h048}} & (aborts)) |
            ({32{csr_address==12'h04c}} & (models)) |
            ({32{csr_address==12'h050}} & (errors));
        read_known=(csr_address==12'h000 || csr_address==12'h004 || csr_address==12'h008 || csr_address==12'h00c || csr_address==12'h010 || csr_address==12'h014 || csr_address==12'h018 || csr_address==12'h01c || csr_address==12'h020 || csr_address==12'h024 || csr_address==12'h028 || csr_address==12'h02c || csr_address==12'h030 || csr_address==12'h040 || csr_address==12'h044 || csr_address==12'h048 || csr_address==12'h04c || csr_address==12'h050); // 读译码结束。
    end // 组合寄存器访问结束。
    always_ff @(posedge clk)begin // 只保留软件配置与握手必需的状态。
        if(reset)begin
            csr_ready<=0;csr_error<=0; // 上电必须显式配置地址和权重。
            frame_valid<=0;model_valid<=0;events_q<=0;irq_enable_q<=0;perf_clear<=0; // 无任务和中断。
            frame_width4<=320;frame_height4<=180;frame_input_base<=0;frame_output_base<=0;frame_x0_base<=0;model_base<=0; // 默认720p尺寸，地址由软件给定。
            frame_input_stride<=2560;frame_output_stride<=2560;frame_x0_stride<=10240; // RGB565与C32行跨度。
        end else begin
            csr_ready<=0;
            if(csr_valid && !csr_ready)begin csr_ready<=1;csr_error<=csr_write ? write_bad : !read_known;end // 事件置位优先于清除。
            perf_clear<=0;events_q<=(events_q & ~clear_events)|new_events; // 不丢同拍新事件。
            if(frame_valid && frame_ready)frame_valid<=0;if(model_valid && model_ready)model_valid<=0; // 命令真正接受才撤回。
            if(write_fire)begin // 一笔写副作用只执行一次。
                if(!write_bad)case(csr_address) // 按字节屏蔽更新。
                    12'h000:if(csr_wstrb[0])begin if(csr_wdata[0])frame_valid<=1;if(csr_wdata[1])model_valid<=1;end // 发起唯一命令。
                    12'h00c:if(csr_wstrb[0])irq_enable_q<=csr_wdata[3:0]; // 中断使能。
                    12'h010:begin // 高低尺寸仍分别支持逐字节写入。
                        if(csr_wstrb[0])frame_width4[7:0]<=csr_wdata[7:0]; // 宽度低字节授权。
                        if(csr_wstrb[1])frame_width4[10:8]<=csr_wdata[10:8]; // 宽度高三位授权。
                        if(csr_wstrb[2])frame_height4[7:0]<=csr_wdata[23:16]; // 高度低字节授权。
                        if(csr_wstrb[3])frame_height4[10:8]<=csr_wdata[26:24]; // 高度高三位授权。
                    end // 未写字节保持原寄存器，不保存合并副本。
                    12'h014:for(int byte_id=0;byte_id<4;byte_id++)if(csr_wstrb[byte_id])frame_input_base[byte_id*8+:8]<=csr_wdata[byte_id*8+:8]; // 字节授权直接控制寄存器CE，不构造回读合并总线。
                    12'h018:for(int byte_id=0;byte_id<4;byte_id++)if(csr_wstrb[byte_id])frame_output_base[byte_id*8+:8]<=csr_wdata[byte_id*8+:8]; // 字节授权直接控制寄存器CE，不构造回读合并总线。
                    12'h01c:for(int byte_id=0;byte_id<4;byte_id++)if(csr_wstrb[byte_id])frame_x0_base[byte_id*8+:8]<=csr_wdata[byte_id*8+:8]; // 字节授权直接控制寄存器CE，不构造回读合并总线。
                    12'h020:for(int byte_id=0;byte_id<3;byte_id++)if(csr_wstrb[byte_id])frame_input_stride[byte_id*8+:8]<=csr_wdata[byte_id*8+:8]; // 字节授权直接控制寄存器CE，不构造回读合并总线。
                    12'h024:for(int byte_id=0;byte_id<3;byte_id++)if(csr_wstrb[byte_id])frame_output_stride[byte_id*8+:8]<=csr_wdata[byte_id*8+:8]; // 字节授权直接控制寄存器CE，不构造回读合并总线。
                    12'h028:for(int byte_id=0;byte_id<3;byte_id++)if(csr_wstrb[byte_id])frame_x0_stride[byte_id*8+:8]<=csr_wdata[byte_id*8+:8]; // 字节授权直接控制寄存器CE，不构造回读合并总线。
                    12'h02c:for(int byte_id=0;byte_id<4;byte_id++)if(csr_wstrb[byte_id])model_base[byte_id*8+:8]<=csr_wdata[byte_id*8+:8]; // 字节授权直接控制寄存器CE，不构造回读合并总线。
                    12'h030:perf_clear<=csr_wstrb[0] && csr_wdata[0]; // 计数清零一拍。
                    default:begin end // 事件清除由上方统一处理。
                endcase // 写副作用结束。
            end // 写事务结束。
        end // 正常寄存器控制结束。
    end // 原生寄存器接口。
endmodule // 软件寄存器结束。
