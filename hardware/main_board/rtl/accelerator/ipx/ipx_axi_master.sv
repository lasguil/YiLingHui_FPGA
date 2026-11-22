// 协议契约：128位AXI4读写各最多一个burst在途，允许读写并行；命令字节地址须16字节对齐。
// 命令length为有效字节数，读末拍以read_keep裁掉补齐字节；写末拍由write_keep控制WSTRB。
// 仅接受1..128字节的单burst命令，DMA负责行、8拍和4KiB边界拆分，禁止重复通用拆分硬件。
// 写侧必须在发命令前预留当前burst全部数据，AW接受后即使abort也须继续提供该burst的全部W拍。
// AXI的AR/AW/W VALID一经置位，在READY前不得因abort撤销；中止仅取消后续尚未发起的burst。
// 读中止时内部接收并丢弃当前burst剩余R拍；写中止等当前burst的B响应；idle才允许工作控制复位。
// read_done/write_done含中止后的安全结束；成功判据须同时检查abort及对应error，不可当作完整帧完成。
// BRESP/RRESP非OKAY保持相应error至下一命令，abort期间也记录响应错误；reset仅可在总线静止时使用。
// 单拍完成不可与新命令同拍返回，默认回归包含回压、4KiB拆分、错误和AR/AW/W等待时抢占。
module ipx_axi_master #( // 两路专用burst引擎，读写各最多一笔，不提供通用长命令解释。
    parameter int unsigned ADDR_W=32,ID_W=4 // 本模块每命令仅1..8拍burst，拆分只由DMA负责。
)( // 接口开始。
    input logic clk,reset,abort, // AXI时钟、同步复位和停止后续burst。
    input logic read_valid, // 读字节区间命令。
    output logic read_ready, // 单读命令可以接受。
    input logic [ADDR_W-1:0] read_address, // 十六字节对齐首地址。
    input logic [7:0] read_length, // 有效字节数1..128。
    output logic read_data_valid, // 当前R拍供适配器消费。
    input logic read_data_ready, // 适配器可接收整拍。
    output logic [127:0] read_data, // AXI低字节对应低DDR地址。
    output wire [4:0] read_bytes, // 连续低地址有效字节数1..16，FIFO不储存冗余16位掩码。
    output logic read_last,read_done,read_error, // 命令末拍、响应结束及错误。
    input logic write_valid, // 写字节区间命令。
    output logic write_ready, // 单写命令可以接受。
    input logic [ADDR_W-1:0] write_address, // 十六字节对齐首地址。
    input logic [7:0] write_length, // 有效字节数1..128。
    input logic write_data_valid, // 已预留的burst数据流。
    output logic write_data_ready, // 当前W拍可接受。
    input logic [127:0] write_data, // 十六字节数据，等待时保持。
    input logic [3:0] write_last_byte, // 最后有效字节编号0..15，末拍掩码在出口展开。
    output logic write_done,write_error,idle, // B响应结束、错误及总线静止。
    output logic [ID_W-1:0] m_axi_arid, // 单读ID零。
    output logic [ADDR_W-1:0] m_axi_araddr, // 读burst首地址。
    output logic [7:0] m_axi_arlen, // 拍数减一。
    output logic [2:0] m_axi_arsize, // 一拍16字节。
    output logic [1:0] m_axi_arburst, // INCR。
    output logic m_axi_arvalid, // AR请求，不可提前撤销。
    input logic m_axi_arready, // DDR接受AR。
    input logic [ID_W-1:0] m_axi_rid, // DDR读返回ID。
    input logic [127:0] m_axi_rdata, // DDR读数据。
    input logic [1:0] m_axi_rresp, // DDR读响应。
    input logic m_axi_rlast,m_axi_rvalid, // burst末拍及数据有效。
    output logic m_axi_rready, // 正常下游回压，中止自动排空。
    output logic [ID_W-1:0] m_axi_awid, // 单写ID一。
    output logic [ADDR_W-1:0] m_axi_awaddr, // 写burst首地址。
    output logic [7:0] m_axi_awlen, // 拍数减一。
    output logic [2:0] m_axi_awsize, // 一拍16字节。
    output logic [1:0] m_axi_awburst, // INCR。
    output logic m_axi_awvalid, // AW请求，不可提前撤销。
    input logic m_axi_awready, // DDR接受AW。
    output logic [127:0] m_axi_wdata, // 写数据直通，FIFO在DMA适配层。
    output logic [15:0] m_axi_wstrb, // 有效写字节。
    output logic m_axi_wlast,m_axi_wvalid, // 当前burst末拍和数据有效。
    input logic m_axi_wready, // DDR接受W。
    input logic [ID_W-1:0] m_axi_bid, // DDR写返回ID。
    input logic [1:0] m_axi_bresp, // DDR写响应。
    input logic m_axi_bvalid, // B响应有效。
    output logic m_axi_bready // 等待响应时可收。
); // 接口结束。
    typedef enum logic [1:0] {R_IDLE,R_ADDR,R_DATA} read_t; // 独立读生命周期。
    typedef enum logic [1:0] {W_IDLE,W_ADDR,W_DATA,W_RESP} write_t; // 独立写生命周期。
    read_t r_state_q; // 两个窄状态机。
    write_t w_state_q; // 两个窄状态机。
    logic [3:0] r_burst_q,w_burst_q,r_count_q,w_count_q; // 只需1..8拍，AR/AW保持字段与数据计数分离。
    logic [3:0] r_tail_q; // 读末字节数与读中止记忆；写本来就必须完成整笔。
    logic r_abort_q; // 读末字节数与读中止记忆；写本来就必须完成整笔。
    assign read_ready=r_state_q==R_IDLE && !abort; // 不接收中止期间新命令。
    assign write_ready=w_state_q==W_IDLE && !abort; // 不接收中止期间新命令。
    assign idle=r_state_q==R_IDLE && w_state_q==W_IDLE; // 不把数据发送结束误作B响应结束。
    assign m_axi_arid='0; // 不增设ID重排缓冲。
    assign m_axi_awid=ID_W'(1); // 不增设ID重排缓冲。
    assign m_axi_arsize=3'd4; // 固定INCR配置。
    assign m_axi_awsize=3'd4; // 固定INCR配置。
    assign m_axi_arburst=2'd1; // 固定INCR配置。
    assign m_axi_awburst=2'd1; // 固定INCR配置。
    assign m_axi_arlen={4'b0,r_burst_q-4'd1}; // 4位减法后补零，长度保持至地址接受。
    assign m_axi_awlen={4'b0,w_burst_q-4'd1}; // 明确4位算术，不隐式扩成8位减法。
    assign m_axi_arvalid=r_state_q==R_ADDR; // 已提出地址不受abort撤销。
    assign m_axi_awvalid=w_state_q==W_ADDR; // 已提出地址不受abort撤销。
    assign read_data_valid=r_state_q==R_DATA && m_axi_rvalid && !abort && !r_abort_q; // 中止返回只丢弃。
    assign m_axi_rready=r_state_q==R_DATA && (read_data_ready || abort || r_abort_q); // 安全排空已发R。
    assign read_data=m_axi_rdata; // 直接消费AXI保持的数据，不加128位暂存。
    assign read_last=r_count_q==1; // 直接消费AXI保持的数据，不加128位暂存。
    assign read_bytes=read_last&&r_tail_q!=0?{1'b0,r_tail_q}:5'd16; // 只保留有效低地址字节。
    assign m_axi_wdata=write_data; // FIFO只携带4位末字节号。
    assign m_axi_wstrb=16'hffff>>(4'd15-write_last_byte); // FIFO只携带4位末字节号。
    assign m_axi_wvalid=w_state_q==W_DATA && write_data_valid; // 中止也完成已接受AW。
    assign write_data_ready=w_state_q==W_DATA && m_axi_wready; // 中止也完成已接受AW。
    assign m_axi_wlast=w_count_q==1; // 末W后仍等待B。
    assign m_axi_bready=w_state_q==W_RESP; // 末W后仍等待B。
    always_ff @(posedge clk)begin // 双通道控制，不保存激活数据。
        if(reset)begin // 外部必须保证没有在途AXI。
            r_state_q<=R_IDLE; // 清状态。
            w_state_q<=W_IDLE; // 清状态。
            read_done<=0; // 清状态。
            write_done<=0; // 清状态。
            read_error<=0; // 清状态。
            write_error<=0; // 清状态。
            r_burst_q<=0; // 清窄计数。
            w_burst_q<=0; // 清窄计数。
            r_count_q<=0; // 清窄计数。
            w_count_q<=0; // 清窄计数。
            r_tail_q<=0; // 清窄计数。
            r_abort_q<=0; // 清窄计数。
            m_axi_araddr<=0; // 初始地址。
            m_axi_awaddr<=0; // 初始地址。
        end else begin // 每个完成通知仅一拍。
            read_done<=0; // 清完成脉冲。
            write_done<=0; // 清完成脉冲。
            if(abort && r_state_q!=R_IDLE)r_abort_q<=1; // 即使abort先撤回也必须丢弃旧读数据。
            case(r_state_q) // 读命令。
                R_IDLE:if(read_valid && read_ready)begin // 锁存命令并提出首burst。
                    r_tail_q<=read_length[3:0]; // 仅最后一拍需要字节尾长度。
                    r_burst_q<=read_length[7:4]+{3'b0,|read_length[3:0]}; // 当前唯一burst拍数ceil(length/16)。
                    m_axi_araddr<=read_address; // 请求直到ready。
                    r_abort_q<=0; // 请求直到ready。
                    read_error<=0; // 请求直到ready。
                    r_state_q<=R_ADDR; // 请求直到ready。
                end // 读命令锁存结束。
                R_ADDR:if(m_axi_arready)begin r_count_q<=r_burst_q; // 已接受AR必须读取整burst。
                    r_state_q<=R_DATA; // 已接受AR必须读取整burst。
                end // 已接受AR必须读取整burst。
                R_DATA:if(m_axi_rvalid && m_axi_rready)begin // 一拍实际响应，中止也排空本burst。
                    if(m_axi_rresp!=0)read_error<=1; // 错误保持到下一命令。
                    r_count_q<=r_count_q-1'b1; // 不保存长命令剩余计数。
                    if(r_count_q==1)begin r_state_q<=R_IDLE; // 全部R返回，本命令结束。
                        read_done<=1; // 全部R返回，本命令结束。
                    end // 全部R返回，本命令结束。
                end // 当前读burst结束。
                default:begin end // 保持。
            endcase // 读通道结束。
            case(w_state_q) // 写命令。
                W_IDLE:if(write_valid && write_ready)begin // 写队列先准备当前burst数据。
                    w_burst_q<=write_length[7:4]+{3'b0,|write_length[3:0]}; // 唯一burst拍数1..8。
                    m_axi_awaddr<=write_address; // AW字段保持。
                    write_error<=0; // AW字段保持。
                    w_state_q<=W_ADDR; // AW字段保持。
                end // 写命令锁存结束。
                W_ADDR:if(m_axi_awready)begin w_count_q<=w_burst_q; // AW接受后提供全部W。
                    w_state_q<=W_DATA; // AW接受后提供全部W。
                end // AW接受后提供全部W。
                W_DATA:if(m_axi_wvalid && m_axi_wready)begin // 实际W拍。
                    w_count_q<=w_count_q-1'b1; // 只按实际W握手减计数。
                    if(w_count_q==1)w_state_q<=W_RESP; // 等B，不能早报done。
                end // W拍结束。
                W_RESP:if(m_axi_bvalid)begin // 当前burst最后B是唯一完成边界。
                    if(m_axi_bresp!=0)write_error<=1; // 错误保持到下一命令。
                    w_state_q<=W_IDLE; // 下一行/页地址由DMA更新，不重复做拆分。
                    write_done<=1; // 下一行/页地址由DMA更新，不重复做拆分。
                end // B响应结束。
                default:begin end // 保持。
            endcase // 写通道结束。
        end // 正常控制结束。
    end // 双通道寄存器结束。
`ifdef SIM_ASSERT // 外部协议错误仿真证伪，不为非法输入增加宽检查。
    always @(posedge clk)if(!reset)begin // 字节区间与AXI响应检查。
        if(read_valid&&read_ready&&(read_address[3:0]!=0||read_length==0||read_length>128||({1'b0,read_address[11:0]}+13'(read_length)>4096)))$fatal(1,"AXI invalid read command"); // 1..8拍且不跨4KiB。
        if(write_valid&&write_ready&&(write_address[3:0]!=0||write_length==0||write_length>128||({1'b0,write_address[11:0]}+13'(write_length)>4096)))$fatal(1,"AXI invalid write command"); // 拆分由DMA保证。
        if(m_axi_rvalid && m_axi_rready && (m_axi_rid!=0 || m_axi_rlast!=(r_count_q==1)))$fatal(1,"AXI read response framing"); // 验证ID和末拍。
        if(m_axi_bvalid && m_axi_bready && m_axi_bid!=ID_W'(1))$fatal(1,"AXI write response ID"); // 单写ID。
    end // 仿真协议检查结束。
`endif // 默认回归启用。
endmodule // AXI burst引擎结束。
