// 协议契约：RGB行字节数为四的倍数，输入每拍完整四字节；前缀只保存0/4/8/12字节，Down保持原协议。
// 协议契约：RGB每次仅入队低四字节，生产计数、队列消费和AXI前缀均按四字节更新；Down保持32字节。
// 协议契约：row_start在Down或RGB行命令接受时有效；本行地址、有效字节数、模式和X4 parity保持到done。
// 前端队列复用C低480..511、高992..1023共64字；RGB复用已被Reduce消费的X4 parity槽前64字。
// enq_word对应Down整理器整字；enq_pixel对应每拍四字节RGB流；无回压计算必须在窗口入口预留24字余量。
// C的队列写数据已接在既有总线上；本模块只发地址、RGB低43位和窄计数，不保存另一份整字。
// 队列读直接使用C原生保持返回；Down低高128位分两拍，RGB前缀使用result_former已有128位寄存器。
// 每次先积累128字节发八拍burst，行尾可不足；AW前当前命令全部字节已在队列/原生输出/前缀中。
// write_data等待ready时稳定；原生IO字和共享前缀不能在等待期间改写，prefix_write仅在实际消费沿有效。
// done等最后成功B响应且producer_done，不以最后W或队列空代替；下一层必须等本输出行done才改变寄存器归属。
// abort禁止新命令与新入队，但继续供完已接受命令；B结束后丢弃未授权余量及原生返回，quiescent才允许clear_work。
// 无新增RAM、DSP或宽数据寄存器；地址和计数是固定容量，行跨度由顶层做逐行加法。
module ngm_output_dma( // 既有C空闲字队列与128位AXI写流。
    input logic clk,reset,abort,row_start, // 时钟、安全工作复位、抢占和输出行开始。
    input logic row_rgb,row_parity, // Down或RGB及已消费X4行槽。
    input logic [31:0] row_address, // 十六字节对齐DDR行首。
    input logic [15:0] row_bytes, // 本行实际输出字节数。
    input logic producer_done, // 真实行引擎所有结果结束。
    output logic row_ready,busy,done,error,quiescent,window_room, // 输出行、响应与预留名额。
    input logic enq_word,enq_pixel, // Down整字或RGB四字节当前返回。
    input logic [39:0] pixel_bytes, // RGB当前四字节。
    output logic sink_ready, // 当前结果能被原有C写口接受。
    output logic io_wr_valid,input logic io_wr_ready, // C队列写口，Down数据已在整理器总线上。
    output logic [9:0] io_wr_addr, // 当前空闲队列字。
    output logic [42:0] io_rgb_word, // 低40位为四字节，高3位保留为零；有效长度由既有窄计数确定。
    output logic io_rd_valid,input logic io_rd_ready, // 原生队列读取。
    output logic [9:0] io_rd_addr, // 只读取已经入队的字。
    input logic io_rsp_valid,output logic io_rsp_ready, // 原生RAM保持返回。
    input logic [255:0] io_rsp_word, // Down整字或RGB载荷。
    input logic [127:0] prefix_value, // 整理器已有寄存器，仅RGB阶段使用。
    output logic prefix_write,output logic [127:0] prefix_data, // 更新共享寄存器，不新增前缀存储。
    output logic write_valid,input logic write_ready, // 完整预留后的字节区间命令。
    output logic [31:0] write_address,output logic [15:0] write_length, // 至少八拍或行尾。
    output logic write_data_valid,input logic write_data_ready, // 当前W数据。
    output logic [127:0] write_data,output logic [15:0] write_keep, // 实际有效字节。
    input logic write_done,write_error // 后端B终结。
); // 接口结束。
    typedef enum logic [1:0]{IDLE,FILL,SEND,RESPONSE} state_t;state_t state_q; // 单写命令生命周期。
    logic rgb_q,parity_q,producer_done_q,io_pending_q,half_q; // 队列归属与原生返回状态。
    logic [5:0] wr_ptr_q,rd_ptr_q;logic [6:0] occupied_q; // 64个既有C字的环指针和占用。
    logic [11:0] available_q;logic [15:0] produce_left_q,total_left_q; // 已生成未发送字节与本行剩余。
    logic [7:0] burst_left_q,burst_size_q;logic [31:0] address_q; // 128字节命令与地址。
    logic [1:0] prefix_quad_q; // 前缀按四字节计数，仅0/1/2/3组。
    wire [2:0] pixel_len=3'd4; // 模型输出宽为四的倍数，每个结果拍完整四字节。
    wire incoming=rgb_q ? enq_pixel && produce_left_q!=0 : enq_word; // 多算的末车道不占队列。
    wire enq_fire=io_wr_valid && io_wr_ready; // 实际入队。
    wire release_word=io_rsp_valid && io_rsp_ready; // 释放RAM原生字后才复用地址。
    wire rd_fire=io_rd_valid && io_rd_ready; // 原生读发起。
    wire command_fire=write_valid && write_ready; // 当前128字节或尾命令已被后端授权。
    wire w_fire=write_data_valid && write_data_ready; // AXI数据实际送出。
    wire [4:0] sent_bytes=burst_left_q>=16 ? 5'd16 : {1'b0,burst_left_q[3:0]}; // 部分行尾。
    function automatic [9:0] queue_addr(input logic rgb,parity,input logic [5:0] ptr); // 固定合法区域，无宽乘法。
        if(rgb)queue_addr=(parity ? 10'd892 : 10'd384)+10'(ptr); // 已消费X4的前64字。
        else queue_addr=(ptr[5] ? 10'd992 : 10'd480)+10'({1'b0,ptr[4:0]}); // 前端两处32字空闲尾区。
    endfunction // 物理地址结束。
    function automatic [127:0] append(input logic [127:0] old,input logic [31:0] fresh,input logic [1:0] count); // 四字节对齐的四种固定接线。
        case(count) // 明确删除其它十二种非法字节位置。
            0:append={96'd0,fresh}; // 前缀零组。
            1:append={64'd0,fresh,old[31:0]}; // 前缀一组。
            2:append={32'd0,fresh,old[63:0]}; // 前缀两组。
            3:append={fresh,old[95:0]}; // 前缀三组，合成完整AXI拍。
        endcase // 固定四选一结束。
    endfunction // 对齐拼接结束。
    assign busy=state_q!=IDLE;assign row_ready=state_q==IDLE && !abort; // 一条输出行保持归属到B。
    assign quiescent=state_q==IDLE && !io_pending_q; // 中止排空完成。
    assign window_room=occupied_q<40 && !abort; // 保留至少24字，包含窗口与计算结果流水。
    assign sink_ready=occupied_q<64 && io_wr_ready && !abort; // 计算结果无回压，预留应保证此处总为一。
    assign io_wr_valid=busy && incoming && occupied_q<64 && !abort; // 入队数据只有一份，直接写既有C。
    assign io_wr_addr=queue_addr(rgb_q,parity_q,wr_ptr_q);assign io_rgb_word={3'd0,pixel_bytes}; // 数据和窄地址直通。
    assign write_valid=state_q==FILL && !abort && (available_q>=128 || producer_done_q && available_q!=0); // 先预留，行尾可不足128。
    assign write_address=address_q;assign write_length=available_q>=128 ? 16'd128 : {4'd0,available_q}; // 上限八拍，地址由B后推进。
    assign io_rd_valid=state_q==SEND && occupied_q>(io_pending_q ? 7'd1 : 7'd0) && (!io_pending_q || release_word); // 原字消费沿可连续读下一字。
    assign io_rd_addr=queue_addr(rgb_q,parity_q,rd_ptr_q+(io_pending_q ? 6'd1 : 6'd0)); // 当前原字占一个位置。
    always_comb begin // W等待期间保持原字与前缀，只有消费沿更新。
        write_data_valid=0;write_data=0;write_keep=16'hffff;io_rsp_ready=0;prefix_write=0;prefix_data=prefix_value; // 默认不消费。
        if(state_q==SEND)begin // 后端已授权当前字节区间。
            // READY may advertise availability early; release_word remains VALID-qualified.
            if(!rgb_q)begin // X0整字直接分两拍，不需要前缀。
                write_data_valid=io_rsp_valid;write_data=half_q ? io_rsp_word[255:128] : io_rsp_word[127:0];io_rsp_ready=write_data_ready && half_q; // 第二拍才释放原字。
            end else if(io_rsp_valid)begin // RGB四字节和共享前缀组合。
                // This branch hardwires write_data_valid=1, so READY is the actual W grant.
                if(prefix_quad_q==2'd3)begin // 足够组成完整W拍，等待AXI消费。
                    write_data_valid=1;write_data=append(prefix_value,io_rsp_word[31:0],prefix_quad_q);io_rsp_ready=write_data_ready;prefix_write=write_data_ready;prefix_data=0; // 没有额外W寄存器。
                end else begin // 尚不足一拍，仅把当前四字节放入已有前缀。
                    io_rsp_ready=1;prefix_write=1;prefix_data=append(prefix_value,io_rsp_word[31:0],prefix_quad_q); // 下一字可在本沿连续读取。
                end // RGB原字处理结束。
            end else if(producer_done_q && occupied_q==0 && prefix_quad_q!=0)begin // 行尾最后一个部分W拍。
                write_data_valid=1;write_data=prefix_value; // 高位无效字节由WSTRB屏蔽。
                case(prefix_quad_q) // 行宽为四的倍数，RGB尾只可能四、八、十二字节。
                    1:write_keep=16'h000f;2:write_keep=16'h00ff;3:write_keep=16'h0fff;default:write_keep=0; // 非法尾由仿真检查拒绝。
                endcase // 尾字节使能结束。
            end // 尾W拍处理结束。
        end // SEND结束。
        if(abort && state_q!=SEND)io_rsp_ready=1; // 已授权W之外的原生余量在中止时丢弃。
    end // 组合数据通路结束。
    always_ff @(posedge clk)begin // 所有寄存器均为窄控制，宽数据在既有RAM及整理器中。
        if(reset)begin // 只在AXI安全静止后清工作状态。
            state_q<=IDLE;rgb_q<=0;parity_q<=0;producer_done_q<=0;io_pending_q<=0;half_q<=0; // 空队列。
            wr_ptr_q<=0;rd_ptr_q<=0;occupied_q<=0;available_q<=0;produce_left_q<=0;total_left_q<=0;address_q<=0;burst_left_q<=0;burst_size_q<=0;prefix_quad_q<=0; // 窄计数。
            done<=0;error<=0; // 清终结脉冲。
        end else begin // 正常同一行。
            done<=0;error<=0; // 单拍事件。
            if(row_start && row_ready)begin // 新行开始，上一行B已经成功结束。
                state_q<=FILL;rgb_q<=row_rgb;parity_q<=row_parity;producer_done_q<=0;wr_ptr_q<=0;rd_ptr_q<=0;occupied_q<=0;available_q<=0;prefix_quad_q<=0;half_q<=0; // 归属与指针。
                address_q<=row_address;produce_left_q<=row_bytes;total_left_q<=row_bytes; // 地址和真实字节长度。
            end // 行接受结束。
            if(producer_done && busy)producer_done_q<=1; // 结果和总线完成不要求同拍。
            if(enq_fire)begin wr_ptr_q<=wr_ptr_q+1'b1;produce_left_q<=produce_left_q-(rgb_q ? 16'(pixel_len) : 16'd32);end // 写入的字节才算已生成。
            if(release_word)rd_ptr_q<=rd_ptr_q+1'b1; // 原生返回实际消费后释放字。
            if(enq_fire || release_word)occupied_q<=occupied_q+7'(enq_fire)-7'(release_word); // 同拍入队出队抵消。
            if(enq_fire || w_fire)available_q<=available_q+(enq_fire ? (rgb_q ? 12'(pixel_len) : 12'd32) : 12'd0)-(w_fire ? 12'(sent_bytes) : 12'd0); // 包含当前前缀和原生输出。
            if(rd_fire)io_pending_q<=1;else if(release_word)io_pending_q<=0; // 连续替换返回仍为一个原生槽。
            if(command_fire)begin state_q<=SEND;burst_left_q<=8'(write_length);burst_size_q<=8'(write_length);end // 当前burst已全部预留。
            if(prefix_write)prefix_quad_q<=prefix_quad_q+1'b1; // 每次消费一个完整四字节，四组自动回绕，不保留溢出。
            if(w_fire)begin // 与后端实际W握手同步。
                burst_left_q<=burst_left_q-8'(sent_bytes);total_left_q<=total_left_q-16'(sent_bytes); // 实际有效字节。
                if(!rgb_q)half_q<=!half_q;else if(!io_rsp_valid)prefix_quad_q<=0; // Down两半或RGB部分尾清空。
                if(burst_left_q<=16)state_q<=RESPONSE; // 等B，不提前宣称写完。
            end // W推进结束。
            if(state_q==RESPONSE && write_done)begin // 成功响应才推进地址或报告整行完成。
                address_q<=address_q+32'(burst_size_q); // 常量最大128字节，无乘法。
                if(write_error)begin state_q<=IDLE;error<=1;end // 失败不得报告done。
                else if(total_left_q==0 && producer_done_q)begin state_q<=IDLE;done<=1;end // 最后B和真实结果均结束。
                else state_q<=FILL; // 等下一批完整预留。
            end // B处理结束。
            if(state_q==FILL && producer_done_q && total_left_q==0)begin state_q<=IDLE;done<=1;end // 最后B早于producer_done时在此合流。
            if(abort && state_q!=SEND && state_q!=RESPONSE)begin state_q<=IDLE;occupied_q<=0;available_q<=0;prefix_quad_q<=0;producer_done_q<=0;end // 未授权余量可丢弃。
            if(abort && state_q==RESPONSE && write_done)begin state_q<=IDLE;occupied_q<=0;available_q<=0;prefix_quad_q<=0;done<=0;end // 已授权数据和B已排空，不能报帧成功。
            if(abort && state_q==SEND && write_done)begin state_q<=IDLE;occupied_q<=0;available_q<=0;prefix_quad_q<=0;done<=0;end // 跨4KiB命令中止可只完成当前子burst，不再等待已取消的后续W。
        end // 正常状态结束。
    end // 窄寄存器结束。
`ifdef SIM_ASSERT // 不为非法输入增加额外硬件缓存。
    always @(posedge clk)if(!reset)begin // 预留和共享寄存器所有权检查。
        if(busy && incoming && !abort && !sink_ready)$fatal(1,"OUTPUT unreserved result"); // 计算路径不能丢数。
        if(command_fire && write_length>available_q)$fatal(1,"OUTPUT unreserved burst"); // 禁止AW后依赖未来计算。
        if(write_data_valid && rgb_q && !io_rsp_valid && prefix_quad_q==0)$fatal(1,"OUTPUT invalid RGB tail"); // RGB888四像素对齐契约。
        if(row_start && row_ready && row_rgb && row_bytes[1:0]!=0)$fatal(1,"OUTPUT unaligned RGB row"); // 固定模型整行四字节对齐。
        if(row_start && !row_ready)$fatal(1,"OUTPUT row ownership"); // 新行不能覆盖未完成输出。
    end // 仿真断言结束。
`endif // 仿真限定结束。
endmodule // 输出队列及burst适配结束。
