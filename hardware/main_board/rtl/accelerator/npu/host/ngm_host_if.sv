// 协议契约：原生寄存器命令与128位AXI4 burst后端共用clk/reset；本模块只连接寄存器、计数器与总线引擎。
// frame/model命令保持至帧控制器ready；完成事件产生保持中断，软件通过08寄存器W1C清除。
// 数据流由DMA适配层提供；写命令前须预留当前burst全部W数据，中止也必须继续供完已接受burst。
// abort禁止新DDR命令并排空当前burst；idle为AXI安全静止，不能用clear_work复位本接口。
// RGB565小端，R[15:11]/G[10:5]/B[4:0]，基址及行跨度16字节对齐；换权重地址采用相同字节地址约定。
// load命令优先于新的激活读命令，并独占读端到2560项写完；软件model命令须由帧控制器安全中止后转成load。
module ngm_host_if #( // 总线与软件控制接口。
    parameter int unsigned ADDR_W=32,ID_W=4,MAX_BURST=64,MAX_READ_BURST=MAX_BURST // 写突发与DMA预留长度保持一致。
)( // 外部协议开始。
    input wire csr_valid,csr_write,
    input wire [11:0] csr_address,
    input wire [31:0] csr_wdata,
    input wire [3:0] csr_wstrb,
    output logic csr_ready,csr_error,
    output wire [31:0] csr_rdata,
    input logic clk,reset, // 处理时钟域与同步复位。
    output logic frame_valid,model_valid, // 挂起命令。
    input logic frame_ready,model_ready, // 帧级控制实际接收。
    output logic [10:0] frame_width4,frame_height4, // 尺寸必须为真实图像除四。
    output logic [31:0] frame_input_base,frame_output_base,frame_x0_base,model_base, // DDR字节首地址。
    output logic [23:0] frame_input_stride,frame_output_stride,frame_x0_stride, // DDR字节行跨度。
    input logic busy,model_loaded,frame_done,frame_aborted,model_done,task_error, // 当前状态与四个终结事件。
    input logic [2:0] error_code, // 帧级错误原因。
    output logic irq, // 寄存器保持中断，接软核中断控制器。
    input logic scratch_write,output wire [127:0] scratch_value, // 帧X0低拍复用模型装载器既有128位寄存器。
    input logic read_valid, // 读字节区间命令。
    output logic read_ready, // 单读命令可以接受。
    input logic [ADDR_W-1:0] read_address, // 十六字节对齐首地址。
    input logic [15:0] read_length, // 有效字节数1..65535。
    output logic read_data_valid, // 当前R拍供适配器消费。
    input logic read_data_ready, // 适配器可接收整拍。
    output logic [127:0] read_data, // AXI低字节对应低DDR地址。
    output logic [15:0] read_keep, // 有效字节位，只有命令最后一拍可能非全一。
    output logic read_last,read_done,read_error, // 命令末拍、响应结束及错误。
    input logic write_valid, // 写字节区间命令。
    output logic write_ready, // 单写命令可以接受。
    input logic [ADDR_W-1:0] write_address, // 十六字节对齐首地址。
    input logic [15:0] write_length, // 有效字节数1..65535。
    input logic write_data_valid, // 已预留的burst数据流。
    output logic write_data_ready, // 当前W拍可接受。
    input logic [127:0] write_data, // 十六字节数据，等待时保持。
    input logic [15:0] write_keep, // 部分末拍字节选择。
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
    output logic m_axi_bready, // 等待响应时可收。
    input logic load_valid, // 帧控制器授权开始装载，不直接使用软件挂起命令。
    output logic load_ready, // DDR读端空闲，允许开始装载。
    input logic [31:0] load_address, // 已锁存的权重镜像地址。
    output logic load_done,load_error, // 成功或失败互斥单拍，均等待主表写入与DDR响应结束。
    output logic reload_valid, // 主表40位项写请求。
    input logic reload_ready, // 主表接受该项。
    output logic [11:0] reload_addr, // 主表项地址。
    output logic [39:0] reload_data, // 连续五字节小端项。
    input logic abort // 中止当前DDR命令，仅取消未发起的后续burst。
); // 主机接口结束。
    logic perf_clear;logic [31:0] busy_cycles,frames,aborts,models,errors; // 计数读值只在本模块内部连线，不重复保存。
    logic weight_busy,weight_read_valid,axi_read_ready,axi_data_valid,weight_data_ready,axi_read_done; // 只在命令边界仲裁，不增加数据缓冲。
    logic weight_done,weight_error; // 装载器终结脉冲与保持的错误状态。
    logic [31:0] weight_address;logic [15:0] weight_length; // 固定包地址和包长。
    assign read_ready=axi_read_ready && !weight_busy && !load_valid; // 模型请求优先于新激活读命令。
    assign read_data_valid=axi_data_valid && !weight_busy;assign read_done=axi_read_done && !weight_busy; // 响应归属于独占客户。
    assign load_done=weight_done && !weight_error;assign load_error=weight_done && weight_error; // 转成帧控制契约的互斥终结事件。
    ngm_weight_dma u_weight_dma( // 主表装载独占现有DDR读后端。
        .scratch_write(scratch_write),.scratch_value(scratch_value), // 同一AXI read_data，空闲阶段只增加捕获使能。
        .clk(clk),.reset(reset),.abort(abort),.start_valid(load_valid),.start_ready(load_ready),.start_address(load_address), // 帧控制授权。
        .done(weight_done),.error(weight_error),.busy(weight_busy),.read_valid(weight_read_valid),.read_ready(axi_read_ready), // 错误只在终结沿通知帧控制。
        .read_address(weight_address),.read_length(weight_length),.read_data_valid(axi_data_valid && weight_busy), // 读命令及数据。
        .read_data_ready(weight_data_ready),.read_data(read_data),.read_done(axi_read_done),.read_error(read_error), // 后端响应直接拆字节。
        .reload_valid(reload_valid),.reload_ready(reload_ready),.reload_addr(reload_addr),.reload_data(reload_data) // 写入正式40位主表。
    ); // 主表装载例化结束。
    ngm_npu_regs u_regs( // 软件配置和中断。
        .clk(clk), // 寄存器接口直连。
        .reset(reset), // 寄存器接口直连。
        .csr_valid(csr_valid), .csr_write(csr_write), .csr_address(csr_address), .csr_wdata(csr_wdata), .csr_wstrb(csr_wstrb), .csr_ready(csr_ready), .csr_error(csr_error), .csr_rdata(csr_rdata), // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
         // 寄存器接口直连。
        .frame_valid(frame_valid), // 寄存器接口直连。
        .model_valid(model_valid), // 寄存器接口直连。
        .frame_ready(frame_ready), // 寄存器接口直连。
        .model_ready(model_ready), // 寄存器接口直连。
        .frame_width4(frame_width4), // 寄存器接口直连。
        .frame_height4(frame_height4), // 寄存器接口直连。
        .frame_input_base(frame_input_base), // 寄存器接口直连。
        .frame_output_base(frame_output_base), // 寄存器接口直连。
        .frame_x0_base(frame_x0_base), // 寄存器接口直连。
        .model_base(model_base), // 寄存器接口直连。
        .frame_input_stride(frame_input_stride), // 寄存器接口直连。
        .frame_output_stride(frame_output_stride), // 寄存器接口直连。
        .frame_x0_stride(frame_x0_stride), // 寄存器接口直连。
        .busy(busy), // 寄存器接口直连。
        .model_loaded(model_loaded), // 寄存器接口直连。
        .frame_done(frame_done), // 寄存器接口直连。
        .frame_aborted(frame_aborted), // 寄存器接口直连。
        .model_done(model_done), // 寄存器接口直连。
        .task_error(task_error), // 寄存器接口直连。
        .error_code(error_code), // 寄存器接口直连。
        .busy_cycles(busy_cycles), // 寄存器接口直连。
        .frames(frames), // 寄存器接口直连。
        .aborts(aborts), // 寄存器接口直连。
        .models(models), // 寄存器接口直连。
        .errors(errors), // 寄存器接口直连。
        .perf_clear(perf_clear), // 寄存器接口直连。
        .irq(irq) // 寄存器接口直连。
    ); // 寄存器例化结束。
    ngm_axi_master #(.ADDR_W(ADDR_W),.ID_W(ID_W),.MAX_BURST(MAX_BURST),.MAX_READ_BURST(MAX_READ_BURST)) u_axi_master( // 双通道burst后端。
        .clk(clk), // AXI或DMA流直连。
        .reset(reset), // AXI或DMA流直连。
        .abort(abort), // AXI或DMA流直连。
        .read_valid(weight_busy ? weight_read_valid : (read_valid && !load_valid)), // 新装载优先，命令接受后保持独占。
        .read_ready(axi_read_ready), // 两客户共用单读命令后端。
        .read_address(weight_busy ? ADDR_W'(weight_address) : read_address), // 只切换窄地址。
        .read_length(weight_busy ? weight_length : read_length), // 固定模型包长或激活区间。
        .read_data_valid(axi_data_valid), // 响应送独占客户。
        .read_data_ready(weight_busy ? weight_data_ready : read_data_ready), // 后端本身在中止时自动排空。
        .read_data(read_data), // AXI或DMA流直连。
        .read_keep(read_keep), // AXI或DMA流直连。
        .read_last(read_last), // AXI或DMA流直连。
        .read_done(axi_read_done), // 激活与模型完成分别交付。
        .read_error(read_error), // AXI或DMA流直连。
        .write_valid(write_valid), // AXI或DMA流直连。
        .write_ready(write_ready), // AXI或DMA流直连。
        .write_address(write_address), // AXI或DMA流直连。
        .write_length(write_length), // AXI或DMA流直连。
        .write_data_valid(write_data_valid), // AXI或DMA流直连。
        .write_data_ready(write_data_ready), // AXI或DMA流直连。
        .write_data(write_data), // AXI或DMA流直连。
        .write_keep(write_keep), // AXI或DMA流直连。
        .write_done(write_done), // AXI或DMA流直连。
        .write_error(write_error), // AXI或DMA流直连。
        .idle(idle), // AXI或DMA流直连。
        .m_axi_arid(m_axi_arid), // AXI或DMA流直连。
        .m_axi_araddr(m_axi_araddr), // AXI或DMA流直连。
        .m_axi_arlen(m_axi_arlen), // AXI或DMA流直连。
        .m_axi_arsize(m_axi_arsize), // AXI或DMA流直连。
        .m_axi_arburst(m_axi_arburst), // AXI或DMA流直连。
        .m_axi_arvalid(m_axi_arvalid), // AXI或DMA流直连。
        .m_axi_arready(m_axi_arready), // AXI或DMA流直连。
        .m_axi_rid(m_axi_rid), // AXI或DMA流直连。
        .m_axi_rdata(m_axi_rdata), // AXI或DMA流直连。
        .m_axi_rresp(m_axi_rresp), // AXI或DMA流直连。
        .m_axi_rlast(m_axi_rlast), // AXI或DMA流直连。
        .m_axi_rvalid(m_axi_rvalid), // AXI或DMA流直连。
        .m_axi_rready(m_axi_rready), // AXI或DMA流直连。
        .m_axi_awid(m_axi_awid), // AXI或DMA流直连。
        .m_axi_awaddr(m_axi_awaddr), // AXI或DMA流直连。
        .m_axi_awlen(m_axi_awlen), // AXI或DMA流直连。
        .m_axi_awsize(m_axi_awsize), // AXI或DMA流直连。
        .m_axi_awburst(m_axi_awburst), // AXI或DMA流直连。
        .m_axi_awvalid(m_axi_awvalid), // AXI或DMA流直连。
        .m_axi_awready(m_axi_awready), // AXI或DMA流直连。
        .m_axi_wdata(m_axi_wdata), // AXI或DMA流直连。
        .m_axi_wstrb(m_axi_wstrb), // AXI或DMA流直连。
        .m_axi_wlast(m_axi_wlast), // AXI或DMA流直连。
        .m_axi_wvalid(m_axi_wvalid), // AXI或DMA流直连。
        .m_axi_wready(m_axi_wready), // AXI或DMA流直连。
        .m_axi_bid(m_axi_bid), // AXI或DMA流直连。
        .m_axi_bresp(m_axi_bresp), // AXI或DMA流直连。
        .m_axi_bvalid(m_axi_bvalid), // AXI或DMA流直连。
        .m_axi_bready(m_axi_bready) // AXI或DMA流直连。
    ); // AXI后端例化结束。
    ngm_perf_counters u_perf_counters( // 不介入计算与DMA握手。
        .clk(clk),.reset(reset),.clear(perf_clear),.busy(busy),.frame_done(frame_done),.frame_aborted(frame_aborted), // 统计占用和帧事件。
        .model_done(model_done),.task_error(task_error),.busy_cycles(busy_cycles),.frames(frames),.aborts(aborts),.models(models),.errors(errors) // 成功重载与错误统计。
    ); // 性能计数例化结束。
endmodule // 主机总线控制结束。
