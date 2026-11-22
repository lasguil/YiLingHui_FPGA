// 协议契约：start握手锁存权重包16字节对齐DDR首地址，独占AXI读客户端直至done或abort。
// 镜像必须是descriptor_package/weight_table40.bin：2560项，每项五个小端字节，总共12800字节。
// 每个读命令128字节（8拍），分100段读完镜像；每拍拆一个字节，每五拍输出一个40位重载项。
// 慢速拆字节不可占着64拍有序返回通道，让显示读在段间取得服务；不改变帧推理读写burst。
// 重载ready回压时保留第五字节、已拼四字节及项地址，禁止重复消费DDR字节或提前报告完成。
// done仅在2560项全部写入且DDR读响应结束后产生；error同时指示响应错误，错误模型不得启动帧。
// abort丢弃本地未写完项；AXI后端负责排空在途burst，下一start必须等read_ready恢复。
// reset/clear_work只允许在AXI安全静止后使用；此模块无RAM、无DSP，不用可变位移拼40位项。
// 模型装载与帧执行互斥；空闲时scratch_write可用既有beat_q保存X0低128位，数据仍来自同一AXI read_data。
// scratch_value不另存数据；scratch_write不能与模型start/STREAM交错，中止后无需保留未提交X0半字。
module ngm_weight_dma( // 固定40位模型主表装载器。
    input logic clk,reset,abort, // 主时钟、安全复位与抢占。
    input logic scratch_write, // 帧X0低拍实际接受时复用既有读拍寄存器。
    output wire [127:0] scratch_value, // 既有beat_q直通，不增加宽暂存。
    input logic start_valid, // 发起完整模型重载。
    output logic start_ready, // 空闲且读后端可接受。
    input logic [31:0] start_address, // DDR镜像字节首地址。
    output logic done,error,busy, // 完成单拍、结果错误及独占读端状态。
    output logic read_valid, // 当前128字节分段命令。
    input logic read_ready, // AXI后端接收读命令。
    output logic [31:0] read_address, // 保持首地址。
    output logic [15:0] read_length, // 固定包长。
    input logic read_data_valid, // 后端128位有效数据。
    output logic read_data_ready, // 一个拍缓冲腾空后接收下一拍。
    input logic [127:0] read_data, // 字节低地址在低位。
    input logic read_done,read_error, // 全部DDR响应已结束及错误。
    output logic reload_valid, // 第五字节在缓冲中时输出完整项。
    input logic reload_ready, // 权重主表实际写接受。
    output logic [11:0] reload_addr, // 连续主表项地址0..2559。
    output logic [39:0] reload_data // 小端五字节组成一项。
); // 装载器接口结束。
    typedef enum logic [1:0] {IDLE,COMMAND,STREAM,FINISH} state_t; // 读命令和拆字节阶段。
    state_t state_q; // 窄控制状态。
    logic [127:0] beat_q;logic [4:0] bytes_q; // 一个AXI拍暂存与剩余字节数。
    assign scratch_value=beat_q; // 同一总线、不同生命周期共享。
    logic [31:0] partial_q;logic [2:0] part_count_q; // 前四字节，只保存32位而非完整重复项。
    logic bus_done_q; // 最后DDR拍接收早于最后五字节拆完。
    wire byte_take=state_q==STREAM && bytes_q!=0 && !abort && (part_count_q!=4 || reload_ready); // 第五字节与写项握手一致。
    assign busy=state_q!=IDLE;assign start_ready=state_q==IDLE && read_ready && !abort; // 不抢占其他读客户。
    assign read_valid=state_q==COMMAND && !abort;assign read_length=16'd128; // 固定分段长度，镜像总长仍12800。
    assign read_data_ready=state_q==STREAM && bytes_q==0 && !abort; // 不覆盖未拆完的拍。
    assign reload_valid=state_q==STREAM && bytes_q!=0 && part_count_q==4 && !abort; // 保持至主表接受。
    assign reload_data={beat_q[7:0],partial_q}; // 固定接线，无可变移位器。
    always_ff @(posedge clk)begin // 必需的字节、项及响应状态。
        if(reset)begin // 安全全局复位。
            state_q<=IDLE;bytes_q<=0;part_count_q<=0;reload_addr<=0;read_address<=0;bus_done_q<=0;done<=0;error<=0; // 有效位复位即屏蔽数据寄存器。
        end else begin // 数据寄存器只在使用时写，不为无效数据增加复位选择。
            done<=0; // 完成脉冲。
            if(abort)begin state_q<=IDLE;bytes_q<=0;part_count_q<=0;end // 排空总线由后端负责。
            else begin // 正常装载生命周期。
                if(scratch_write && state_q==IDLE)beat_q<=read_data; // 和模型捕获同一数据源，只扩展原有使能。
                if(read_done && busy)begin bus_done_q<=1;error<=error||read_error;end // 保留响应终结，等待最后项写入。
                case(state_q) // 固定布局，无描述符解码。
                    IDLE:if(start_valid && start_ready)begin // 新包从第零项开始。
                        read_address<=start_address;reload_addr<=0;bytes_q<=0;part_count_q<=0;bus_done_q<=0;error<=0;state_q<=COMMAND; // 锁存地址并提出命令。
                    end // 新装载接受结束。
                    COMMAND:if(read_ready)state_q<=STREAM; // 读命令接受后才能消费数据。
                    STREAM:begin // 每个DDR字节恰好消费一次。
                        // Yield the ordered DDR return channel every 8 beats.
                        // Keep partial five-byte entries across command boundaries.
                        if(bus_done_q && bytes_q==0)begin
                            read_address<=read_address+32'd128;
                            bus_done_q<=0;state_q<=COMMAND;
                        end
                        if(read_data_valid && read_data_ready)begin beat_q<=read_data;bytes_q<=16;end // 读取完整128位拍。
                        if(byte_take)begin // 只做固定八位移动。
                            beat_q<={8'b0,beat_q[127:8]};bytes_q<=bytes_q-1'b1; // 固定字节队列。
                            if(part_count_q==4)begin // 第五字节与主表握手同步。
                                part_count_q<=0; // 下一项从零字节开始。
                                if(reload_addr==12'd2559)state_q<=FINISH;else reload_addr<=reload_addr+1'b1; // 仅写规定的2560项。
                            end else begin partial_q<={beat_q[7:0],partial_q[31:8]};part_count_q<=part_count_q+1'b1;end // 四次移入后低字节顺序正确。
                        end // 字节消费结束。
                    end // 拆项流结束。
                    FINISH:if(bus_done_q || read_done)begin done<=1;state_q<=IDLE;end // DDR响应与表写入双重完成。
                    default:state_q<=IDLE; // 状态恢复。
                endcase // 装载状态结束。
            end // 非中止路径结束。
        end // 非复位路径结束。
    end // 装载时序结束。
`ifdef SIM_ASSERT // 非法上游约定只在仿真检查。
    always @(posedge clk)if(!reset)begin // 独占接口检查。
        if(start_valid && start_ready && start_address[3:0]!=0)$fatal(1,"weight DDR base alignment"); // 后端要求对齐。
        if(state_q==FINISH && bytes_q!=0)$fatal(1,"weight package trailing bytes"); // 12800恰为16的倍数。
        if(scratch_write && (busy || start_valid))$fatal(1,"weight scratch ownership"); // 模型与帧半字不得同时使用寄存器。
    end // 仿真检查结束。
`endif // 默认回归使能。
endmodule // 固定模型DMA装载结束。
