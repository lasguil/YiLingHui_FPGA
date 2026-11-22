// 协议契约：本模块拥有输入分段、RGB上下行配对、X0读回和结果burst写回。
// 输入与X0独占一个DDR读端；输出命令发起前已有完整burst数据，中止仍送完已接受事务。
// D段暂存、C输出队列及两处共享128位寄存器沿用原位置；本模块不新增RAM或宽寄存器。
// 工作复位使用frame_ctx.dispatch.reset_work，由任务控制合入全局复位及安全清工作状态。
module ngm_npu_transfer_path ( // 按功能边界组织系统集成。
    input wire clk, // 唯一工作时钟。
    input wire ngm_npu_types::frame_context_t frame_ctx, // 保持的任务描述符及控制。
    input wire ngm_npu_types::read_response_t read_response, // DDR读命令握手与返回拍。
    input wire ngm_npu_types::write_response_t write_response, // DDR写命令握手与B完成。
    input wire [127:0] scratch_value, // host既有低拍寄存器直通。
    input wire ngm_npu_types::compute_feedback_t compute, // 计算及存储反馈。
    output wire ngm_npu_types::transfer_feedback_t transfer, // DMA状态、请求及数据。
    output wire ngm_npu_types::activation_request_t activation // DDR激活读写请求。
); // 功能边界接口结束。
    import ngm_npu_types::*; // 使用具名接口类型。

    typedef struct packed { // RGB输入分段DMA的状态及D段暂存写流。
        logic read_valid; // 上/下段字节区间请求。
        logic [31:0] read_address; // 当前段DDR首地址。
        logic [15:0] read_length; // 当前段有效字节数，最大256。
        logic read_data_ready; // 当前消费者可以接收拍。
        logic segment_start; // 上行段已完整提交，下行开始前的单拍提示。
        logic [9:0] segment_x; // 本段Stem首列，等于RGB首列除二。
        logic [6:0] segment_pairs; // 本段上下行两像素配对数1..64。
        logic bottom_valid; // 下行原始DDR拍。
        logic [127:0] bottom_data; // 直接使用AXI后端保持的数据。
        logic [15:0] bottom_keep; // 当前下行拍有效字节。
    } local_input_dma_t; // 本组位序由字段定义，不使用位置拼接。
    wire local_input_dma_t input_dma; // 当前子模块的内部连接。

    typedef struct packed { // 上行段读取和上下行像素配对接口。
        logic bottom_ready; // RGB配对器可消费。
        logic segment_consumed; // 配对器已用完本段且可覆写D暂存。
    } local_input_pair_t; // 本组位序由字段定义，不使用位置拼接。
    wire local_input_pair_t input_pair; // 当前子模块的内部连接。

    typedef struct packed { // X0行读回的状态及原子C/D写流。
        logic read_valid; // 共用读命令。
        logic [31:0] read_address; // 整行范围连续burst。
        logic [15:0] read_length; // 整行范围连续burst。
        logic read_data_ready; // DDR拍握手。
    } local_x0_dma_t; // 本组位序由字段定义，不使用位置拼接。
    wire local_x0_dma_t x0_dma; // 当前子模块的内部连接。

    // ---------- 输入与X0的独占读端复用 ----------
    assign activation.read.valid = transfer.input_dma.busy ? input_dma.read_valid : x0_dma.read_valid; // 输入和X0读阶段互斥。
    assign activation.read.address = transfer.input_dma.busy ? input_dma.read_address : x0_dma.read_address; // 单读地址复用。
    assign activation.read.length = transfer.input_dma.busy ? input_dma.read_length : x0_dma.read_length; // 单读字节数复用。
    assign activation.read.data_ready = transfer.input_dma.busy ? input_dma.read_data_ready : x0_dma.read_data_ready; // 响应保持原归属直到done。

    ngm_input_dma u_input_dma ( // 上下行分段burst输入，使用D既有尾区。
        .clk                   (clk), // NPU时钟、安全复位与抢占。
        .reset                 (frame_ctx.dispatch.reset_work), // NPU时钟、安全复位与抢占。
        .abort                 (frame_ctx.phase.abort_req), // NPU时钟、安全复位与抢占。
        .start_valid           (frame_ctx.input_row.valid), // 一对真实输入行命令。
        .start_ready           (transfer.input_dma.start_ready), // 无旧行且读端空闲。
        .start_top_address     (frame_ctx.addresses.input_address), // 上/下RGB行首字节地址。
        .start_bottom_address  (frame_ctx.addresses.input_address+{8'd0,frame_ctx.layout.input_stride}), // 上/下RGB行首字节地址。
        .start_width           (frame_ctx.input_row.width), // 真实RGB像素宽，4..1920且为四的倍数。
        .start_stem_row        (frame_ctx.input_row.row >> 1), // 本行Stem结果的真实行号。
        .busy                  (transfer.input_dma.busy), // 行占用与互斥终结脉冲。
        .done                  (transfer.input_dma.done), // 行占用与互斥终结脉冲。
        .error                 (transfer.input_dma.error), // 行占用与互斥终结脉冲。
        .read_valid            (input_dma.read_valid), // 上/下段字节区间请求。
        .read_ready            (read_response.ready && !transfer.x0_dma.busy), // 共用AXI读后端接受命令。
        .read_address          (input_dma.read_address), // 当前段DDR首地址。
        .read_length           (input_dma.read_length), // 当前段有效字节数，最大256。
        .read_data_valid       (read_response.data_valid && transfer.input_dma.busy), // DDR读拍有效。
        .read_data_ready       (input_dma.read_data_ready), // 当前消费者可以接收拍。
        .read_data             (read_response.data), // DDR原始RGB字节。
        .read_keep             (read_response.keep), // 末拍有效字节屏蔽。
        .read_last             (read_response.last), // 当前命令末拍、响应终结和错误。
        .read_done             (read_response.done && transfer.input_dma.busy), // 当前命令末拍、响应终结和错误。
        .read_error            (read_response.error), // 当前命令末拍、响应终结和错误。
        .dma_valid             (transfer.input_dma.dma_valid), // 上行拍写D原有空闲尾区。
        .dma_ready             (compute.memory.dma_ready && transfer.input_dma.busy), // 存储子系统接受该拍。
        .dma_row               (transfer.input_dma.dma_row), // D提交输入段时使用Stem行标签。
        .dma_word              (transfer.input_dma.dma_word), // 段内拍号0..23。
        .dma_data              (transfer.input_dma.dma_data), // 低128位有效，高半为零，无新增配对暂存。
        .dma_last              (transfer.input_dma.dma_last), // 上行段末拍真正握手时提交。
        .segment_start         (input_dma.segment_start), // 上行段已完整提交，下行开始前的单拍提示。
        .segment_x             (input_dma.segment_x), // 本段Stem首列，等于RGB首列除二。
        .segment_pairs         (input_dma.segment_pairs), // 本段上下行两像素配对数1..64。
        .segment_consumed      (input_pair.segment_consumed), // 配对器已用完本段且可覆写D暂存。
        .bottom_valid          (input_dma.bottom_valid), // 下行原始DDR拍。
        .bottom_ready          (input_pair.bottom_ready), // RGB配对器可消费。
        .bottom_data           (input_dma.bottom_data), // 直接使用AXI后端保持的数据。
        .bottom_keep           (input_dma.bottom_keep) // 当前下行拍有效字节。
    ); // ngm_input_dma连接结束。

    ngm_rgb_pair_source u_rgb_pair_source ( // D上行返回与DDR下行流组成Stem输入。
        .reflect_480           (frame_ctx.layout.width4==214 && frame_ctx.layout.height4==120),
        .clk                   (clk), // 工作时钟与取消本段。
        .reset                 (frame_ctx.dispatch.reset_work), // 工作时钟与取消本段。
        .abort                 (frame_ctx.phase.abort_req), // 工作时钟与取消本段。
        .segment_start         (input_dma.segment_start), // 上行段已完整装入D。
        .segment_x             (input_dma.segment_x), // 本段Stem首列。
        .segment_pairs         (input_dma.segment_pairs), // 本段Stem点数。
        .req_valid             (transfer.input_pair.req_valid), // 请求D下一原始DDR拍。
        .req_ready             (compute.memory.req_ready && !frame_ctx.phase.abort_req), // D读请求被接受。
        .req_word              (transfer.input_pair.req_word), // 段内拍号，不是像素列。
        .rsp_valid             (compute.memory.d_rsp_valid && (transfer.input_dma.busy || compute.row.stage_layer_id==0)), // D的原生读返回。
        .rsp_ready             (transfer.input_pair.rsp_ready), // 当前整字已使用完或需跨字。
        .rsp_data              (compute.memory.d_rsp_input_word), // D整字的低半字，禁止用按列选择的rsp_half。
        .bottom_valid          (input_dma.bottom_valid), // 下行burst拍有效。
        .bottom_ready          (input_pair.bottom_ready), // 下行拍仅在需要补字节且消费者可接收时取走。
        .bottom_data           (input_dma.bottom_data), // 下行RGB565字节。
        .bottom_keep           (input_dma.bottom_keep), // 连续低位有效字节。
        .pair_valid            (transfer.input_pair.pair_valid), // 一对上下行相邻像素已齐。
        .pair_ready            (compute.window.stem_ready && !frame_ctx.phase.abort_req), // Stem窗口装填可以接受。
        .pair_x                (), // 本层不使用该输出，显式留空。
        .pair_data             (transfer.input_pair.pair_data), // 十二通道与四个补零通道。
        .segment_consumed      (input_pair.segment_consumed) // 最后一点已消费，D尾区可复用。
    ); // ngm_rgb_pair_source连接结束。

    ngm_output_dma u_output_dma ( // 复用C队列，将X0或RGB结果burst写回。
        .clk                   (clk), // 时钟、安全工作复位、抢占和输出行开始。
        .reset                 (frame_ctx.dispatch.reset_work), // 时钟、安全工作复位、抢占和输出行开始。
        .abort                 (frame_ctx.phase.abort_req), // 时钟、安全工作复位、抢占和输出行开始。
        .row_start             (frame_ctx.dispatch.row_cmd_take && frame_ctx.dispatch.output_stage), // 时钟、安全工作复位、抢占和输出行开始。
        .row_rgb               (frame_ctx.row.layer==5'd16), // Down或RGB及已消费X4行槽。
        .row_parity            (frame_ctx.dispatch.tail_parity), // Down或RGB及已消费X4行槽。
        .row_address           (frame_ctx.row.layer==5'd3 ? frame_ctx.addresses.checkpoint_address : frame_ctx.addresses.output_address), // 十六字节对齐DDR行首。
        .row_bytes             (frame_ctx.row.layer==5'd3 ? {frame_ctx.dispatch.output_columns,5'b0} : {4'd0,frame_ctx.dispatch.output_columns,1'b0}), // 本行实际输出字节数。
        .producer_done         (compute.row.row_done), // 真实行引擎所有结果结束。
        .row_ready             (transfer.output_dma.row_ready), // 输出行、响应与预留名额。
        .busy                  (), // 本层不使用该输出，显式留空。
        .done                  (transfer.output_dma.done), // 输出行、响应与预留名额。
        .error                 (transfer.output_dma.error), // 输出行、响应与预留名额。
        .quiescent             (transfer.output_dma.quiescent), // 输出行、响应与预留名额。
        .window_room           (transfer.output_dma.window_room), // 输出行、响应与预留名额。
        .enq_word              (compute.memory.checkpoint_valid && !frame_ctx.phase.abort_req), // Down整字或RGB五字节当前返回。
        .enq_pixel             (compute.engine.pixel_valid && !frame_ctx.phase.abort_req), // Down整字或RGB五字节当前返回。
        .pixel_bytes           (compute.engine.pixel_bytes), // RGB565当前四字节。
        .sink_ready            (transfer.output_dma.sink_ready), // 当前结果能被原有C写口接受。
        .io_wr_valid           (transfer.output_dma.io_wr_valid), // C队列写口，Down数据已在整理器总线上。
        .io_wr_ready           (compute.memory.io_wr_ready), // C队列写口，Down数据已在整理器总线上。
        .io_wr_addr            (transfer.output_dma.io_wr_addr), // 当前空闲队列字。
        .io_rgb_word           (transfer.output_dma.io_rgb_word), // 五字节和有效长度。
        .io_rd_valid           (transfer.output_dma.io_rd_valid), // 原生队列读取。
        .io_rd_ready           (compute.memory.io_rd_ready), // 原生队列读取。
        .io_rd_addr            (transfer.output_dma.io_rd_addr), // 只读取已经入队的字。
        .io_rsp_valid          (compute.memory.io_rsp_valid), // 原生RAM保持返回。
        .io_rsp_ready          (transfer.output_dma.io_rsp_ready), // 原生RAM保持返回。
        .io_rsp_word           (compute.memory.io_rsp_word), // Down整字或RGB载荷。
        .prefix_value          (compute.memory.prefix_value), // 整理器已有寄存器，仅RGB阶段使用。
        .prefix_write          (transfer.output_dma.prefix_write), // 更新共享寄存器，不新增前缀存储。
        .prefix_data           (transfer.output_dma.prefix_data), // 更新共享寄存器，不新增前缀存储。
        .write_valid           (activation.write.valid), // 完整预留后的字节区间命令。
        .write_ready           (write_response.ready), // 完整预留后的字节区间命令。
        .write_address         (activation.write.address), // 至少八拍或行尾。
        .write_length          (activation.write.length), // 至少八拍或行尾。
        .write_data_valid      (activation.write.data_valid), // 当前W数据。
        .write_data_ready      (write_response.data_ready), // 当前W数据。
        .write_data            (activation.write.data), // 实际有效字节。
        .write_keep            (activation.write.keep), // 实际有效字节。
        .write_done            (write_response.done), // 后端B终结。
        .write_error           (write_response.error) // 后端B终结。
    ); // ngm_output_dma连接结束。

    ngm_x0_dma u_x0_dma ( // DDR两拍拼整字，原子提交C/D镜像。
        .clk                   (clk), // 时钟、安全复位、中止和行请求。
        .reset                 (frame_ctx.dispatch.reset_work), // 时钟、安全复位、中止和行请求。
        .abort                 (frame_ctx.phase.abort_req), // 时钟、安全复位、中止和行请求。
        .start_valid           (frame_ctx.x0.valid), // 时钟、安全复位、中止和行请求。
        .start_ready           (transfer.x0_dma.start_ready), // 行接收与终结事件。
        .busy                  (transfer.x0_dma.busy), // 行接收与终结事件。
        .done                  (transfer.x0_dma.done), // 行接收与终结事件。
        .error                 (transfer.x0_dma.error), // 行接收与终结事件。
        .start_address         (frame_ctx.addresses.prefetch_address+{16'd0,frame_ctx.x0.lo,5'b0}), // 已加真实行跨度与lo×32的DDR地址。
        .start_row             (frame_ctx.x0.row), // 调度直到本次完成保持。
        .lo                    (frame_ctx.x0.lo), // 调度直到本次完成保持。
        .hi                    (frame_ctx.x0.hi), // 调度直到本次完成保持。
        .center_lo             (frame_ctx.x0.center_lo), // 调度直到本次完成保持。
        .center_hi             (frame_ctx.x0.center_hi), // 调度直到本次完成保持。
        .read_valid            (x0_dma.read_valid), // 共用读命令。
        .read_ready            (read_response.ready && !transfer.input_dma.busy), // 共用读命令。
        .read_address          (x0_dma.read_address), // 整行范围连续burst。
        .read_length           (x0_dma.read_length), // 整行范围连续burst。
        .read_data_valid       (read_response.data_valid && transfer.x0_dma.busy), // DDR拍握手。
        .read_data_ready       (x0_dma.read_data_ready), // DDR拍握手。
        .read_data             (read_response.data), // 低地址低字节。
        .read_done             (read_response.done && transfer.x0_dma.busy), // 全部R响应结束。
        .read_error            (read_response.error), // 全部R响应结束。
        .scratch_write         (activation.scratch.write), // 共享既有host读拍寄存器。
        .scratch_value         (scratch_value), // 共享既有host读拍寄存器。
        .dma_valid             (transfer.x0_dma.dma_valid), // 完整256位字原子提交。
        .dma_ready             (compute.memory.dma_ready && !transfer.input_dma.busy), // 完整256位字原子提交。
        .dma_row               (transfer.x0_dma.dma_row), // 不复制外部保持描述符。
        .dma_x                 (transfer.x0_dma.dma_x), // 不复制外部保持描述符。
        .dma_center_lo         (transfer.x0_dma.dma_center_lo), // 不复制外部保持描述符。
        .dma_center_hi         (transfer.x0_dma.dma_center_hi), // 不复制外部保持描述符。
        .dma_word              (transfer.x0_dma.dma_word), // D预取的范围内字序号。
        .dma_data              (transfer.x0_dma.dma_data), // 当前整字与提交标记。
        .dma_begin             (transfer.x0_dma.dma_begin), // 当前整字与提交标记。
        .dma_last              (transfer.x0_dma.dma_last) // 当前整字与提交标记。
    ); // ngm_x0_dma连接结束。
endmodule // ngm_npu_transfer_path结束。
