// 协议契约：一条frame命令自主完成RGB565输入、整帧X0、T=120主体及RGB565写回，完成等待最后成功B。
// DDR接口固定128位INCR burst；基址与跨度十六字节对齐，单时钟同步复位，软件不得在busy时重用DDR工作区域。
// model命令立即丢帧；已接受AXI事务必须排空，随后clear_work清工作状态，host只接受全局reset。
// 只使用既有114块RAM10；输出队列复用C空闲64字，RGB前缀复用整理器，X0低拍复用模型装载寄存器。
// 行描述符保持到计算和本行B响应共同完成；残差按实际issue晚读，窗口直接装填既有乒乓存储。
// 权重每行装入非活动bank，真正row_start接受后才准许下一次预取；不以命令接受代替PE bank切换。
module ngm_npu_top #( // 外部AXI边界和功能模块例化。
    parameter int unsigned ID_W = 4 // 与系统AXI互连的ID位宽一致。
) ( // 单时钟同步复位的NPU边界。
    input wire csr_valid,csr_write,
    input wire [11:0] csr_address,
    input wire [31:0] csr_wdata,
    input wire [3:0] csr_wstrb,
    output logic csr_ready,csr_error,
    output wire [31:0] csr_rdata,

    // ---------- 时钟和全局复位 ----------
    input  wire              clk,reset, // 处理时钟域与同步复位。


    // ---------- 软核完成事件中断 ----------
    output wire              irq, // 寄存器保持中断，接软核中断控制器。

    // ---------- DDR AXI读地址通道 ----------
    output wire [ID_W-1:0]   m_axi_arid, // 单读ID零。
    output wire [31:0]       m_axi_araddr, // 读burst首地址。
    output wire [7:0]        m_axi_arlen, // 拍数减一。
    output wire [2:0]        m_axi_arsize, // 一拍16字节。
    output wire [1:0]        m_axi_arburst, // 固定为递增地址burst。
    output wire              m_axi_arvalid, // AR请求，不可提前撤销。
    input  wire              m_axi_arready, // DDR接受AR。

    // ---------- DDR AXI读数据通道 ----------
    input  wire [ID_W-1:0]   m_axi_rid, // DDR读返回ID。
    input  wire [127:0]      m_axi_rdata, // DDR读数据。
    input  wire [1:0]        m_axi_rresp, // DDR读响应。
    input  wire              m_axi_rlast, // burst末拍及数据有效。
    input  wire              m_axi_rvalid, // burst末拍及数据有效。
    output wire              m_axi_rready, // 正常下游回压，中止自动排空。

    // ---------- DDR AXI写地址通道 ----------
    output wire [ID_W-1:0]   m_axi_awid, // 单写ID一。
    output wire [31:0]       m_axi_awaddr, // 写burst首地址。
    output wire [7:0]        m_axi_awlen, // 拍数减一。
    output wire [2:0]        m_axi_awsize, // 一拍16字节。
    output wire [1:0]        m_axi_awburst, // 固定为递增地址burst。
    output wire              m_axi_awvalid, // AW请求，不可提前撤销。
    input  wire              m_axi_awready, // DDR接受AW。

    // ---------- DDR AXI写数据通道 ----------
    output wire [127:0]      m_axi_wdata, // 写数据直通，FIFO在DMA适配层。
    output wire [15:0]       m_axi_wstrb, // 有效写字节。
    output wire              m_axi_wlast, // 当前burst末拍和数据有效。
    output wire              m_axi_wvalid, // 当前burst末拍和数据有效。
    input  wire              m_axi_wready, // DDR接受W。

    // ---------- DDR AXI写响应通道 ----------
    input  wire [ID_W-1:0]   m_axi_bid, // DDR写返回ID。
    input  wire [1:0]        m_axi_bresp, // DDR写响应。
    input  wire              m_axi_bvalid, // B响应有效。
    output wire              m_axi_bready, //  等待响应时可收。
    output wire task_busy // 已有状态的组合导出，锁定整帧路由配置。
); // 外部接口结束。
    import ngm_npu_types::*; // 模块间连线按协议分组，不含状态或存储。

    // ---------- 四个功能模块之间的具名协议 ----------
    wire command_t command; // host发布的软件命令及帧布局。
    wire status_t status; // 任务控制返回的软件状态与事件。
    assign task_busy=status.busy||command.frame_valid||command.model_valid; // 不增加状态或存储。
    wire host_transport_t transport; // DDR返回、主表装载流与总线空闲。
    wire model_request_t model_request; // 任务控制授权的新模型DDR装载。
    wire activation_request_t activation; // 传输路径发布的激活DDR请求。
    wire frame_context_t frame_ctx; // 任务控制保持的当前行及阶段授权。
    wire compute_feedback_t compute; // 计算和片上存储反馈。
    wire transfer_feedback_t transfer; // 数据传输反馈及既有存储口请求。

    // 缩短推理读事务，减少显示读被在途响应阻塞；写端仍保留64拍。
    ngm_host_if #(.ID_W(ID_W),.MAX_READ_BURST(64)) u_host_if ( // AXI控制寄存器及唯一DDR总线后端。
        .clk                   (clk), // 处理时钟域与同步复位。
        .reset                 (reset), // 处理时钟域与同步复位。
        .csr_valid(csr_valid),
        .csr_write(csr_write),
        .csr_address(csr_address),
        .csr_wdata(csr_wdata),
        .csr_wstrb(csr_wstrb),
        .csr_ready(csr_ready),
        .csr_error(csr_error),
        .csr_rdata(csr_rdata),
        .frame_valid           (command.frame_valid), // 挂起命令。
        .model_valid           (command.model_valid), // 挂起命令。
        .frame_ready           (status.frame_ready), // 帧级控制实际接收。
        .model_ready           (status.model_ready), // 帧级控制实际接收。
        .frame_width4          (command.frame_width4), // 尺寸必须为真实图像除四。
        .frame_height4         (command.frame_height4), // 尺寸必须为真实图像除四。
        .frame_input_base      (command.frame_input_base), // DDR字节首地址。
        .frame_output_base     (command.frame_output_base), // DDR字节首地址。
        .frame_x0_base         (command.frame_x0_base), // DDR字节首地址。
        .model_base            (command.model_base), // DDR字节首地址。
        .frame_input_stride    (command.frame_input_stride), // DDR字节行跨度。
        .frame_output_stride   (command.frame_output_stride), // DDR字节行跨度。
        .frame_x0_stride       (command.frame_x0_stride), // DDR字节行跨度。
        .busy                  (status.busy), // 当前状态与四个终结事件。
        .model_loaded          (status.model_loaded), // 当前状态与四个终结事件。
        .frame_done            (status.frame_done), // 当前状态与四个终结事件。
        .frame_aborted         (status.frame_aborted), // 当前状态与四个终结事件。
        .model_done            (status.model_done), // 当前状态与四个终结事件。
        .task_error            (status.task_error), // 当前状态与四个终结事件。
        .error_code            (status.error_code), // 帧级错误原因。
        .irq                   (irq), // 寄存器保持中断，接软核中断控制器。
        .scratch_write         (activation.scratch.write), // 帧X0低拍复用模型装载器既有128位寄存器。
        .scratch_value         (transport.aux.scratch_value), // 帧X0低拍复用模型装载器既有128位寄存器。
        .read_valid            (activation.read.valid), // 读字节区间命令。
        .read_ready            (transport.read.ready), // 单读命令可以接受。
        .read_address          (activation.read.address), // 十六字节对齐首地址。
        .read_length           (activation.read.length), // 有效字节数1..65535。
        .read_data_valid       (transport.read.data_valid), // 当前R拍供适配器消费。
        .read_data_ready       (activation.read.data_ready), // 适配器可接收整拍。
        .read_data             (transport.read.data), // AXI低字节对应低DDR地址。
        .read_keep             (transport.read.keep), // 有效字节位，只有命令最后一拍可能非全一。
        .read_last             (transport.read.last), // 命令末拍、响应结束及错误。
        .read_done             (transport.read.done), // 命令末拍、响应结束及错误。
        .read_error            (transport.read.error), // 命令末拍、响应结束及错误。
        .write_valid           (activation.write.valid), // 写字节区间命令。
        .write_ready           (transport.write.ready), // 单写命令可以接受。
        .write_address         (activation.write.address), // 十六字节对齐首地址。
        .write_length          (activation.write.length), // 有效字节数1..65535。
        .write_data_valid      (activation.write.data_valid), // 已预留的burst数据流。
        .write_data_ready      (transport.write.data_ready), // 当前W拍可接受。
        .write_data            (activation.write.data), // 十六字节数据，等待时保持。
        .write_keep            (activation.write.keep), // 部分末拍字节选择。
        .write_done            (transport.write.done), // B响应结束、错误及总线静止。
        .write_error           (transport.write.error), // B响应结束、错误及总线静止。
        .idle                  (transport.aux.idle), // B响应结束、错误及总线静止。
        .m_axi_arid            (m_axi_arid), // 单读ID零。
        .m_axi_araddr          (m_axi_araddr), // 读burst首地址。
        .m_axi_arlen           (m_axi_arlen), // 拍数减一。
        .m_axi_arsize          (m_axi_arsize), // 一拍16字节。
        .m_axi_arburst         (m_axi_arburst), // 固定为递增地址burst。
        .m_axi_arvalid         (m_axi_arvalid), // AR请求，不可提前撤销。
        .m_axi_arready         (m_axi_arready), // DDR接受AR。
        .m_axi_rid             (m_axi_rid), // DDR读返回ID。
        .m_axi_rdata           (m_axi_rdata), // DDR读数据。
        .m_axi_rresp           (m_axi_rresp), // DDR读响应。
        .m_axi_rlast           (m_axi_rlast), // burst末拍及数据有效。
        .m_axi_rvalid          (m_axi_rvalid), // burst末拍及数据有效。
        .m_axi_rready          (m_axi_rready), // 正常下游回压，中止自动排空。
        .m_axi_awid            (m_axi_awid), // 单写ID一。
        .m_axi_awaddr          (m_axi_awaddr), // 写burst首地址。
        .m_axi_awlen           (m_axi_awlen), // 拍数减一。
        .m_axi_awsize          (m_axi_awsize), // 一拍16字节。
        .m_axi_awburst         (m_axi_awburst), // 固定为递增地址burst。
        .m_axi_awvalid         (m_axi_awvalid), // AW请求，不可提前撤销。
        .m_axi_awready         (m_axi_awready), // DDR接受AW。
        .m_axi_wdata           (m_axi_wdata), // 写数据直通，FIFO在DMA适配层。
        .m_axi_wstrb           (m_axi_wstrb), // 有效写字节。
        .m_axi_wlast           (m_axi_wlast), // 当前burst末拍和数据有效。
        .m_axi_wvalid          (m_axi_wvalid), // 当前burst末拍和数据有效。
        .m_axi_wready          (m_axi_wready), // DDR接受W。
        .m_axi_bid             (m_axi_bid), // DDR写返回ID。
        .m_axi_bresp           (m_axi_bresp), // DDR写响应。
        .m_axi_bvalid          (m_axi_bvalid), // B响应有效。
        .m_axi_bready          (m_axi_bready), // 等待响应时可收。
        .load_valid            (model_request.valid), // 帧控制器授权开始装载，不直接使用软件挂起命令。
        .load_ready            (transport.model.ready), // DDR读端空闲，允许开始装载。
        .load_address          (model_request.address), // 已锁存的权重镜像地址。
        .load_done             (transport.model.done), // 成功或失败互斥单拍，均等待主表写入与DDR响应结束。
        .load_error            (transport.model.error), // 成功或失败互斥单拍，均等待主表写入与DDR响应结束。
        .reload_valid          (transport.weights.valid), // 主表40位项写请求。
        .reload_ready          (compute.memory.reload_ready), // 主表接受该项。
        .reload_addr           (transport.weights.addr), // 主表项地址。
        .reload_data           (transport.weights.data), // 连续五字节小端项。
        .abort                 (frame_ctx.phase.abort_req) // 中止当前DDR命令，仅取消未发起的后续burst。
    ); // ngm_host_if连接结束。

    ngm_npu_task_control u_task_control ( // 本模块拥有帧/strip调度、权重准备标签、行完成记账和DDR行地址推进。
        .clk            (clk), // 唯一工作时钟。
        .reset          (reset), // 全局同步复位。
        .command        (command), // 本功能边界的具名协议。
        .model_response (transport.model), // 主表装载完成交任务控制。
        .transport_idle (transport.aux.idle), // 安全边界必须等host空闲。
        .compute        (compute), // 本功能边界的具名协议。
        .transfer       (transfer), // 本功能边界的具名协议。
        .status         (status), // 本功能边界的具名协议。
        .model_request  (model_request), // 本功能边界的具名协议。
        .frame_ctx      (frame_ctx) // 本功能边界的具名协议。
    ); // 功能模块连接结束。

    ngm_npu_compute_path u_compute ( // 本模块拥有行定序、抽头供数、残差定时、唯一行引擎和A/B/C/D存储。
        .clk            (clk), // 唯一工作时钟。
        .frame_ctx      (frame_ctx), // 本功能边界的具名协议。
        .weight_write   (transport.weights), // 主表装载流只接到存储路径。
        .transfer       (transfer), // 本功能边界的具名协议。
        .compute        (compute) // 本功能边界的具名协议。
    ); // 功能模块连接结束。

    ngm_npu_transfer_path u_transfer ( // 本模块拥有输入分段、RGB上下行配对、X0读回和结果burst写回。
        .clk            (clk), // 唯一工作时钟。
        .frame_ctx      (frame_ctx), // 本功能边界的具名协议。
        .read_response  (transport.read), // DDR读返回交当前输入或X0客户。
        .write_response (transport.write), // DDR写响应交输出DMA。
        .scratch_value  (transport.aux.scratch_value), // X0低拍复用host寄存器。
        .compute        (compute), // 本功能边界的具名协议。
        .transfer       (transfer), // 本功能边界的具名协议。
        .activation     (activation) // 本功能边界的具名协议。
    ); // 功能模块连接结束。
endmodule // 根顶层只负责外部接口和模块例化。
