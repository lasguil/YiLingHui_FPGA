// 协议契约：start接受一条X0真实行的[lo,hi)字范围，外部行、范围、地址保持直到done；最多132个C32字。
// X0在DDR每像素32字节自然通道序；低128位拍先保存到host已存在的weight_dma.beat_q，高拍直接拼接写C/D。
// 模型重载与帧执行互斥；scratch_write仅在低拍真正接受时有效，同一DDR数据源不增128位选择或寄存器。
// 每个高拍与两片bank原子握手，C/D镜像提交完整行后才done；最后R响应也必须结束。
// 没有另设FIFO、RAM、DSP或宽暂存；回压直接保持AXI高拍和host低拍。
// abort丢弃未提交半字并禁止新请求；AXI后端负责已发burst排空；下一start等read_ready恢复。
module ngm_x0_dma( // 全帧checkpoint的逐行burst预取。
    input logic clk,reset,abort,start_valid, // 时钟、安全复位、中止和行请求。
    output logic start_ready,busy,done,error, // 行接收与终结事件。
    input logic [31:0] start_address, // 已加真实行跨度与lo×32的DDR地址。
    input logic [10:0] start_row,lo,hi,center_lo,center_hi, // 范围与字数在start沿锁存；start_row和地址继续由调度保持。
    output logic read_valid,input logic read_ready, // 共用读命令。
    output wire [31:0] read_address,output wire [15:0] read_length, // 整行范围连续burst。
    input logic read_data_valid,output logic read_data_ready, // DDR拍握手。
    input logic [127:0] read_data, // 低地址低字节。
    input logic read_done,read_error, // 全部R响应结束。
    output logic scratch_write,input logic [127:0] scratch_value, // 共享既有host读拍寄存器。
    output logic dma_valid,input logic dma_ready, // 完整256位字原子提交。
    output wire [10:0] dma_row,dma_x,dma_center_lo,dma_center_hi, // 范围来自已接受请求的窄寄存器；行号由外部保持。
    output logic [7:0] dma_word, // D预取的范围内字序号。
    output wire [255:0] dma_data,output wire dma_begin,dma_last // 当前整字与提交标记。
); // 接口结束。
    typedef enum logic [1:0]{IDLE,COMMAND,STREAM,FINISH} state_t;state_t state_q; // 窄行状态。
    logic [7:0] count_q;logic [10:0] x_q,center_lo_q,center_hi_q; // 当前真实列取代不变lo寄存器；寄存器位数不增加。
    logic high_q,bus_done_q; // 下一拍是低拍还是高拍、R完成保持。
    wire [10:0] count=hi-lo; // 固定132字以内，无乘法。
    assign busy=state_q!=IDLE;assign start_ready=state_q==IDLE && read_ready && !abort; // 共用读端空闲才接收。
    assign read_valid=state_q==COMMAND && !abort;assign read_address=start_address;assign read_length={3'd0,count_q,5'b0}; // 32字节一像素，仅接线。
    assign read_data_ready=state_q==STREAM && !abort && (!high_q || dma_ready); // 高拍不能覆盖未提交完整字。
    assign scratch_write=state_q==STREAM && read_data_valid && read_data_ready && !high_q; // 仅低拍捕获，同一总线。
    assign dma_valid=state_q==STREAM && high_q && read_data_valid && !abort; // 当前高拍和已保存低拍。
    assign dma_data={read_data,scratch_value};assign dma_row=start_row;assign dma_x=x_q; // 真正高拍提交才推进真实列，避免再加lo后进C地址减法。
    assign dma_center_lo=center_lo_q;assign dma_center_hi=center_hi_q; // C标签范围保持。
    assign dma_begin=dma_word==0;assign dma_last=dma_word==count_q-1'b1; // 真正高拍提交时有效。
    always_ff @(posedge clk)begin // 只有窄控制。
        if(reset)begin state_q<=IDLE;high_q<=0;bus_done_q<=0;dma_word<=0;done<=0;error<=0;end // 无宽数据复位。
        else begin // 一条已接受行。
            done<=0;error<=0; // 单拍事件。
            if(abort)begin state_q<=IDLE;high_q<=0;end // 未提交低拍可以丢弃。
            else begin // 正常范围读取。
                if(read_done && busy)bus_done_q<=1; // 最后R可能先于状态进入FINISH。
                case(state_q) // burst由共用AXI后端拆分。
                    IDLE:if(start_valid && start_ready)begin state_q<=COMMAND;high_q<=0;dma_word<=0;bus_done_q<=0;count_q<=8'(count);x_q<=lo;center_lo_q<=center_lo;center_hi_q<=center_hi;end // 接受时预译码字数与范围；无有效事务时这些寄存值不使用。
                    COMMAND:if(read_ready)state_q<=STREAM; // 命令接受。
                    STREAM:if(read_data_valid && read_data_ready)begin // 每个128位拍只接受一次。
                        high_q<=!high_q; // 低高交替。
                        if(high_q)begin if(dma_last)state_q<=FINISH;else begin dma_word<=dma_word+1'b1;x_q<=x_q+1'b1;end end // 低拍和回压均保持；末字后坐标与旧实现相同。
                    end // 拍流结束。
                    FINISH:if(bus_done_q || read_done)begin state_q<=IDLE;done<=1;error<=read_error;end // 行提交与总线响应均结束。
                    default:state_q<=IDLE; // 安全恢复。
                endcase // 生命周期结束。
            end // 非中止路径结束。
        end // 非复位路径结束。
    end // 窄寄存器结束。
`ifdef SIM_ASSERT // 不为非法描述符保留宽检查电路。
    logic [10:0] accepted_lo_q;
    always_ff @(posedge clk)if(!reset && start_valid && start_ready)accepted_lo_q<=lo;
    always @(posedge clk)if(!reset && busy && dma_x!==accepted_lo_q+11'(dma_word))
        $fatal(1,"X0 registered coordinate differs from original lo+word");
    always @(posedge clk)if(!reset && start_valid && start_ready && (count==0 || count>132 || start_address[3:0]!=0))$fatal(1,"X0 range contract"); // 固定物理预取容量。
`endif // 仿真契约结束。
endmodule // X0无额外宽暂存预取结束。
