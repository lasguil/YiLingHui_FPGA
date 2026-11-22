// 协议契约：本模块拥有帧/strip调度、权重准备标签、行完成记账和DDR行地址推进。
// 行完成等待计算结束及成功B；换模型先中止、排空、clear_work，再装新权重。
// frame_ctx描述符从行接受保持到行完成；工作复位不复位host；本模块不保存激活数据。
// 工作错误按协议、输入DDR、输出DDR优先级寄存一拍后中止；换模型命令仍在接受当拍禁止新工作。
// 输出列数在行命令预检查拍形成；输出行接受时须等于本行emit_hi-emit_lo，无额外启动拍。
module ngm_npu_task_control ( // 按功能边界组织系统集成。
    input wire clk, // 唯一工作时钟。
    input wire reset, // 全局同步复位。
    input wire ngm_npu_types::command_t command, // 软件挂起命令。
    input wire ngm_npu_types::model_response_t model_response, // 主表装载接受及成功或失败事件。
    input wire transport_idle, // host已排空接受的DDR事务。
    input wire ngm_npu_types::compute_feedback_t compute, // 计算及存储反馈。
    input wire ngm_npu_types::transfer_feedback_t transfer, // DMA状态、请求及数据。
    output wire ngm_npu_types::status_t status, // 软件可见状态与事件。
    output wire ngm_npu_types::model_request_t model_request, // 安全排空后授权模型装载。
    output wire ngm_npu_types::frame_context_t frame_ctx // 保持的任务描述符及控制。
); // 功能边界接口结束。
    import ngm_npu_types::*; // 使用具名接口类型。

    logic loaded_valid_q; // 非活动权重层锚点已装载完成。
    logic loading_q; // 当前有主表向常驻槽装载的任务。
    logic await_commit_q; // 行命令已接受，等待PE真正切换权重层锚点。
    logic [4:0] loaded_layer_q; // 准备上下文对应的模型层号。
    logic [4:0] loading_layer_q; // 正在装载的模型层号。
    logic computed_q; // 当前行的计算结果已全部产生。
    logic committed_q; // 当前输出行的最后成功B已返回。
    logic reported_q; // 当前行完成事件已向帧控制报告。
    logic checkpoint_committed_q; // 前端整帧X0已写回DDR。
    logic output_committed_q; // 最后strip最后RGB行已写回DDR。
    logic tail_parity_q; // Reduce已完整消费的X4行槽。
    logic [31:0] input_address_q; // 下一对RGB输入行首地址。
    logic [31:0] checkpoint_address_q; // 下一X0输出行首地址。
    logic [31:0] prefetch_address_q; // 当前strip下一X0读回行首地址。
    logic [31:0] output_address_q; // 当前strip下一RGB输出行首地址。
    logic [3:0] quiet_q; // 最后一次窗口操作到RGB结果排空的十四拍保守界限。

    // ---------- 行授权、边界与错误汇总 ----------
    wire frame_row_ready; // 行定序器和输出队列均能接收新行。
    wire engine_commit; // PE实际接受row_start并切换权重层锚点。
    wire frame_row_done; // 只向帧控制报告一次行完成。
    wire abort_quiescent; // 抢占时DDR及结果流水均已排空。
    wire boundary_ready; // 正常相位边界没有未完成工作。
    wire [2:0] work_error_next; // 按既有优先级汇总工作模块错误。
    logic [10:0] output_columns_q; // 输出列数提前一拍形成，后续乘三/乘32不再串接strip范围算术。
    always_ff @(posedge clk)output_columns_q<=frame_ctx.row.emit_hi-frame_ctx.row.emit_lo; // 行预检查拍保证接受前已稳定，无需独立valid或宽缓存。
    logic [2:0] work_error; // 汇总错误寄存一拍，避免跨模块错误链直接驱动RAM写控制。
    always_ff @(posedge clk) begin // 错误来源均保持到工作复位，允许一拍汇总延迟。
        if(frame_ctx.dispatch.reset_work)work_error<=0; // 新任务清除前一帧错误。
        else work_error<=work_error_next; // 协议错误后一拍停止工作；换模型命令仍当拍中止。
    end // 错误汇总流水结束。

    assign frame_ctx.dispatch.reset_work = reset || frame_ctx.phase.clear_work; // 只清工作电路，不能复位在途AXI。
    // output_stage comes from the FSM before selecting the row layer bus.
    // This is identical for every state, including idle/abort and strip layers. // 只有Down与RGB占用DDR输出队列。
    assign frame_ctx.dispatch.output_columns = output_columns_q; // 预译码的真实输出列数，行接受时用于输出DMA锁存字节数。
    assign frame_ctx.dispatch.weights_ready = // 当前层准备槽已提交。
        loaded_valid_q && loaded_layer_q==frame_ctx.row.layer; // 层号与有效位必须同时匹配。
    assign frame_row_ready = compute.row.cmd_ready && // 行定序器空闲。
        (!frame_ctx.dispatch.output_stage || transfer.output_dma.row_ready) && // 输出行须同时预留队列。
        !frame_ctx.phase.abort_req; // 抢占期间不接受新行。
    assign frame_ctx.dispatch.row_cmd_take = frame_ctx.row.valid && frame_row_ready; // 所有参与者同沿锁存。
    assign frame_ctx.dispatch.wanted_layer = // 当前命令优先于下一层提示。
        frame_ctx.row.valid && !frame_ctx.dispatch.weights_ready ? // 当前行是否缺少准备权重。
        frame_ctx.row.layer : frame_ctx.weight_hint.layer; // 选择本次装载层号。
    assign frame_ctx.dispatch.layer_load_start = // 不覆盖尚未被PE切走的准备上下文。
        !frame_ctx.phase.abort_req && !loading_q && !await_commit_q && // 排除抢占、在途装载和待提交层锚点。
        compute.memory.layer_load_ready && // 主表装载器可以接受新任务。
        ((frame_ctx.row.valid && !frame_ctx.dispatch.weights_ready) || // 当前行缺权重。
         (frame_ctx.weight_hint.valid && !loaded_valid_q)); // 或可提前准备下一层。
    assign engine_commit = compute.row.engine_row_start_valid && // 行定序器发起真实启动。
        compute.engine.row_ready && !frame_ctx.phase.abort_req; // PE实际接受，抢占不得提交层锚点。
    assign frame_row_done = !reported_q && // 同一行只报告一次。
        (frame_ctx.dispatch.output_stage ? // Down/RGB需要DDR提交。
         (computed_q || compute.row.row_done) && // 计算可以早于最后B结束。
         (committed_q || transfer.output_dma.done) : // 当前输出行最后成功B。
         compute.row.row_done) && !frame_ctx.phase.abort_req; // 普通行只等计算，抢占不报成功。
    assign abort_quiescent = transport_idle && // host已排空接受的DDR事务。
        transfer.output_dma.quiescent && quiet_q==0 && // 输出队列及已发流水排空。
        !compute.engine.code_valid && !compute.engine.pixel_valid; // 没有当拍结果待处理。
    assign boundary_ready = !compute.row.busy && compute.window.idle && // 行与抽头供数空闲。
        transfer.output_dma.quiescent && !transfer.input_dma.busy && // 输出与输入DMA空闲。
        !transfer.x0_dma.busy && transport_idle && // X0与DDR后端空闲。
        !loading_q && quiet_q==0; // 权重及结果流水也已排空。
    assign work_error_next = // 沿用既有错误优先级。
        (compute.memory.protocol_error || compute.row.protocol_error || // 存储或行协议错误。
         compute.window.protocol_error || compute.engine.protocol_error || // 窗口或引擎协议错误。
         compute.residual.protocol_error) ? 3'd1 : // 残差协议错误也归工作协议错误。
        (transfer.input_dma.error || transfer.x0_dma.error) ? 3'd2 : // DDR输入或X0读回错误。
        transfer.output_dma.error ? 3'd3 : 3'd0; // DDR写回错误或无错误。
    assign frame_ctx.addresses.input_address = input_address_q; // 只引出既有行地址寄存器，不重复保存。
    assign frame_ctx.addresses.checkpoint_address = checkpoint_address_q; // 只引出既有行地址寄存器，不重复保存。
    assign frame_ctx.addresses.prefetch_address = prefetch_address_q; // 只引出既有行地址寄存器，不重复保存。
    assign frame_ctx.addresses.output_address = output_address_q; // 只引出既有行地址寄存器，不重复保存。
    assign frame_ctx.dispatch.tail_parity = tail_parity_q; // 只引出已消费X4行槽标签。

    ngm_frame_sequencer u_frame_sequencer ( // 整帧、strip及各行的任务调度。
        .clk                   (clk), // 同步控制时钟与复位。
        .reset                 (reset), // 同步控制时钟与复位。
        .frame_valid           (command.frame_valid), // 软核一帧命令。
        .frame_ready           (status.frame_ready), // 可以锁存新帧配置。
        .frame_width4          (command.frame_width4), // 原始图像宽度除四。
        .frame_height4         (command.frame_height4), // 原始图像高度除四。
        .frame_input_base      (command.frame_input_base), // 三块DDR区域基址。
        .frame_output_base     (command.frame_output_base), // 三块DDR区域基址。
        .frame_x0_base         (command.frame_x0_base), // 三块DDR区域基址。
        .frame_input_stride    (command.frame_input_stride), // 字节行跨度。
        .frame_output_stride   (command.frame_output_stride), // 字节行跨度。
        .frame_x0_stride       (command.frame_x0_stride), // 字节行跨度。
        .model_valid           (command.model_valid), // 可抢占当前帧的换权重命令。
        .model_ready           (status.model_ready), // 无待处理换权重命令。
        .model_base            (command.model_base), // 新权重包DDR首地址。
        .model_loaded          (status.model_loaded), // 权重可用、占用与终结事件。
        .busy                  (status.busy), // 权重可用、占用与终结事件。
        .frame_done            (status.frame_done), // 权重可用、占用与终结事件。
        .frame_aborted         (status.frame_aborted), // 权重可用、占用与终结事件。
        .model_done            (status.model_done), // 权重可用、占用与终结事件。
        .task_error            (status.task_error), // 权重可用、占用与终结事件。
        .error_code            (status.error_code), // 最近失败的外部错误原因，成功新命令清零。
        .input_base            (frame_ctx.layout.input_base), // 锁存配置，不随软核改寄存器变化。
        .output_base           (frame_ctx.layout.output_base), // 锁存配置，不随软核改寄存器变化。
        .x0_base               (frame_ctx.layout.x0_base), // 锁存配置，不随软核改寄存器变化。
        .load_base             (model_request.address), // 锁存配置，不随软核改寄存器变化。
        .input_stride          (frame_ctx.layout.input_stride), // 锁存DMA行跨度。
        .output_stride         (frame_ctx.layout.output_stride), // 锁存DMA行跨度。
        .x0_stride             (frame_ctx.layout.x0_stride), // 锁存DMA行跨度。
        .width4                (frame_ctx.layout.width4), // 当前帧四分之一宽。
        .height4               (frame_ctx.layout.height4), // 当前帧四分之一高。
        .load_valid            (model_request.valid), // 整个主表与参数包重载请求。
        .load_ready            (model_response.ready), // 请求接受、成功提交或失败；done/error不可同拍。
        .load_done             (model_response.done), // 请求接受、成功提交或失败；done/error不可同拍。
        .load_error            (model_response.error), // 请求接受、成功提交或失败；done/error不可同拍。
        .abort_req             (frame_ctx.phase.abort_req), // 丢帧停止新工作与安全工作状态清除。
        .clear_work            (frame_ctx.phase.clear_work), // 丢帧停止新工作与安全工作状态清除。
        .abort_quiescent       (abort_quiescent), // 抢占排空和正常阶段静止。
        .boundary_ready        (boundary_ready), // 抢占排空和正常阶段静止。
        .work_error            (work_error), // 当前帧DMA/引擎/协议错误，非零触发安全终止。
        .checkpoint_committed  (checkpoint_committed_q), // 两个整帧写响应完成条件。
        .output_committed      (output_committed_q), // 两个整帧写响应完成条件。
        .cfg_front             (), // 本层不使用该输出，显式留空。
        .strip_start           (frame_ctx.strip.start), // 存储相位及主体新strip标签清除。
        .input_valid           (frame_ctx.input_row.valid), // Stem所需两条RGB输入行的流式DMA命令。
        .input_ready           (transfer.input_dma.start_ready), // 命令接受与数据消费/读响应结束。
        .input_done            (transfer.input_dma.done), // 命令接受与数据消费/读响应结束。
        .input_row             (frame_ctx.input_row.row), // 第一条真实RGB行，第二条为加一。
        .input_width           (frame_ctx.input_row.width), // 两行各自真实像素宽度。
        .dma_valid             (frame_ctx.x0.valid), // 主体X0行预取命令，末字同时提交C/D。
        .dma_ready             (transfer.x0_dma.start_ready), // X0命令接受与末字提交。
        .dma_done              (transfer.x0_dma.done), // X0命令接受与末字提交。
        .dma_row               (frame_ctx.x0.row), // X0真实行号。
        .dma_lo                (frame_ctx.x0.lo), // X0范围与C中心。
        .dma_hi                (frame_ctx.x0.hi), // X0范围与C中心。
        .dma_center_lo         (frame_ctx.x0.center_lo), // X0范围与C中心。
        .dma_center_hi         (frame_ctx.x0.center_hi), // X0范围与C中心。
        .strip_s               (frame_ctx.strip.s), // strip中心、D基址与RGB局部保存宽。
        .strip_e               (frame_ctx.strip.e), // strip中心、D基址与RGB局部保存宽。
        .tail_base             (frame_ctx.strip.tail_base), // strip中心、D基址与RGB局部保存宽。
        .bank_rgb_width        (frame_ctx.strip.bank_rgb_width), // strip中心、D基址与RGB局部保存宽。
        .row_output_stage      (frame_ctx.dispatch.output_stage),
        .row_valid             (frame_ctx.row.valid), // 前端或主体整行计算命令。
        .row_ready             (frame_row_ready), // 行接受与实际结果排空。
        .row_done              (frame_row_done), // 行接受与实际结果排空。
        .row_layer             (frame_ctx.row.layer), // 当前层0..16。
        .row_id                (frame_ctx.row.id), // 输出行与输入真实高度。
        .read_height           (frame_ctx.row.read_height), // 输出行与输入真实高度。
        .row_x                 (frame_ctx.row.x), // 真实组首列、AB局部首列和输入宽度。
        .row_ab_col            (frame_ctx.row.ab_col), // 真实组首列、AB局部首列和输入宽度。
        .read_width            (frame_ctx.row.read_width), // 真实组首列、AB局部首列和输入宽度。
        .row_count             (frame_ctx.row.count), // 实际空间组数。
        .read_slot             (frame_ctx.row.read_slot), // 三行环输入与输出槽。
        .write_slot            (frame_ctx.row.write_slot), // 三行环输入与输出槽。
        .read_lo               (frame_ctx.row.read_lo), // 输入保存范围与有效输出范围。
        .read_hi               (frame_ctx.row.read_hi), // 输入保存范围与有效输出范围。
        .emit_lo               (frame_ctx.row.emit_lo), // 输入保存范围与有效输出范围。
        .emit_hi               (frame_ctx.row.emit_hi), // 输入保存范围与有效输出范围。
        .read_center_lo        (frame_ctx.row.read_center_lo), // 主体C中心描述符。
        .read_center_hi        (frame_ctx.row.read_center_hi), // 主体C中心描述符。
        .write_center_lo       (frame_ctx.row.write_center_lo), // 主体C中心描述符。
        .write_center_hi       (frame_ctx.row.write_center_hi), // 主体C中心描述符。
        .prefetch_valid        (frame_ctx.weight_hint.valid), // 当前行期间下一实际层提示。
        .prefetch_layer        (frame_ctx.weight_hint.layer) // 提示层号。
    ); // ngm_frame_sequencer连接结束。

    // ---------- 标签、完成、地址与安全排空 ----------
    always_ff @(posedge clk) begin // 权重标签只在正式提交沿更新。
        if (frame_ctx.dispatch.reset_work) begin // 清当前帧的权重工作标签。
            loaded_valid_q <= 0; // 准备上下文失效。
            loading_q <= 0; // 无在途装载。
            await_commit_q <= 0; // 无等待提交层锚点的行命令。
            loaded_layer_q <= 0; // 清准备层号。
            loading_layer_q <= 0; // 清装载层号。
        end // 权重工作标签复位结束。
        else begin // 同一层相邻行也要装入准备槽。
            if (frame_ctx.dispatch.layer_load_start) begin // 开始实际有效权重与两批参数装载。
                loading_q <= 1; // 记录装载在途。
                loading_layer_q <= frame_ctx.dispatch.wanted_layer; // 锁定装载层号。
                loaded_valid_q <= 0; // 准备槽尚不能供新行使用。
            end // 装载启动处理结束。
            if (compute.memory.layer_load_done) begin // 主表读与SRL写均完成。
                loading_q <= 0; // 装载任务结束。
                loaded_valid_q <= 1; // 准备上下文可供匹配层使用。
                loaded_layer_q <= loading_layer_q; // 提交完成层号。
            end // 装载完成处理结束。
            if (frame_ctx.dispatch.row_cmd_take) await_commit_q <= 1; // 命令接受尚未提交层锚点。
            if (engine_commit) begin // PE接受row_start后才可重用原活动bank。
                await_commit_q <= 0; // 不再等待提交层锚点。
                loaded_valid_q <= 0; // 准备上下文已成为活动bank。
            end // PE权重提交处理结束。
        end // 权重标签更新结束。
    end // 权重控制结束。
    always_ff @(posedge clk) begin // 计算与DDR提交并行，单行完成必须同时满足。
        if (frame_ctx.dispatch.reset_work) begin // 新帧清单行与整帧完成状态。
            computed_q <= 0; // 清计算完成。
            committed_q <= 0; // 清当前行DDR提交。
            reported_q <= 0; // 清已报告标记。
            checkpoint_committed_q <= 0; // 清整帧X0提交。
            output_committed_q <= 0; // 清整帧RGB提交。
            tail_parity_q <= 0; // 清已消费的尾部行槽。
        end // 完成状态复位结束。
        else begin // 描述符归属到真正完成。
            if (frame_ctx.dispatch.row_cmd_take) begin // 新行重新记账。
                computed_q <= 0; // 新行尚未计算完成。
                committed_q <= 0; // 新行尚未DDR提交。
                reported_q <= 0; // 新行尚未报告完成。
            end // 行接受处理结束。
            if (compute.row.row_done) computed_q <= 1; // 所有结果已进入目标bank或输出队列。
            if (transfer.output_dma.done) committed_q <= 1; // 最后成功B已到达。
            if (frame_row_done) reported_q <= 1; // 当前行只报告一次完成。
            if (compute.row.row_done && compute.row.stage_layer_id == 12) // Reduce完整消费X4行。
                tail_parity_q <= compute.row.stage_row[0]; // 此行槽可复用为RGB队列。
            if (transfer.output_dma.done && frame_ctx.row.layer == 3 && // Down最后成功B。
                compute.row.stage_row == frame_ctx.layout.height4-1'b1) // 前端最后一行。
                checkpoint_committed_q <= 1; // 整帧X0已提交。
            if (transfer.output_dma.done && frame_ctx.row.layer == 16 && // RGB最后成功B。
                compute.row.stage_row == (frame_ctx.layout.height4<<2)-1'b1 && // 原图最后一行。
                frame_ctx.strip.e == frame_ctx.layout.width4) // 最后一条strip。
                output_committed_q <= 1; // 整帧RGB已提交。
        end // 完成状态更新结束。
    end // 完成控制结束。
    always_ff @(posedge clk) begin // 地址只存每条顺序流的下一行首。
        if (reset) begin // 全局地址初值。
            input_address_q <= 0; // 清输入地址。
            checkpoint_address_q <= 0; // 清X0写地址。
            prefetch_address_q <= 0; // 清X0读地址。
            output_address_q <= 0; // 清RGB输出地址。
        end // 全局地址复位结束。
        else if (frame_ctx.phase.clear_work) begin // 配置已锁存，建立新帧地址。
            input_address_q <= frame_ctx.layout.input_base; // RGB输入帧首。
            checkpoint_address_q <= frame_ctx.layout.x0_base; // X0检查点帧首。
            prefetch_address_q <= frame_ctx.layout.x0_base; // 主体X0读回帧首。
            output_address_q <= frame_ctx.layout.output_base; // RGB输出帧首。
        end // 新帧地址建立结束。
        else begin // 所有跨度为字节。
            if (transfer.input_dma.done) // 当前输入上下两行消费完成。
                input_address_q <= input_address_q+{7'd0,frame_ctx.layout.input_stride,1'b0}; // 前进两行。
            if (transfer.output_dma.done && frame_ctx.row.layer == 3) // 当前Down行DDR提交。
                checkpoint_address_q <= checkpoint_address_q+{8'd0,frame_ctx.layout.x0_stride}; // 前进一个X0行。
            if (frame_ctx.strip.start) begin // 新strip从第一条X0行开始。
                prefetch_address_q <= frame_ctx.layout.x0_base; // 重置X0读回地址。
                output_address_q <= frame_ctx.layout.output_base+ // RGB流从左侧halo起点开始，地址保持在分流区间内。
                                    {18'd0,frame_ctx.strip.tail_base,3'b0}; // 四个RGB565像素，合计八字节。
            end // strip地址建立结束。
            else begin // 每strip从第一行重读X0并逐行输出。
                if (transfer.x0_dma.done) // 当前X0行已原子提交C/D。
                    prefetch_address_q <= prefetch_address_q+{8'd0,frame_ctx.layout.x0_stride}; // 下一X0行。
                if (transfer.output_dma.done && frame_ctx.row.layer == 16) // 当前RGB行DDR提交。
                    output_address_q <= output_address_q+{8'd0,frame_ctx.layout.output_stride}; // 下一RGB行。
            end // strip地址更新结束。
        end // 地址更新结束。
    end // 地址计数结束。
    always_ff @(posedge clk)begin // 不为排空额外保存任何数据。
        if(frame_ctx.dispatch.reset_work)quiet_q<=0; // 安全复位。
        else if(frame_ctx.dispatch.row_cmd_take || compute.engine.window_released || |compute.window.load_valid)quiet_q<=14; // 包含点计算九拍与RGB分拍。
        else if(quiet_q!=0)quiet_q<=quiet_q-1'b1; // 已发流水自主前进。
    end // 排空计数结束。
`ifdef SIM_ASSERT // 非法系统调度只在模拟检查。
    always @(posedge clk)if(!frame_ctx.dispatch.reset_work)begin // 不增加硬件防非法输入队列。
        if(transfer.input_dma.busy && transfer.x0_dma.busy)$fatal(1,"TOP simultaneous input/X0 readers"); // 单DDR读流必须互斥。
        if(frame_ctx.dispatch.layer_load_start && !compute.descriptor.desc_valid)$fatal(1,"TOP invalid layer load"); // 固定17层。
        if(frame_ctx.phase.clear_work && !transport_idle)$fatal(1,"TOP clear while AXI active"); // 不能复位在途AXI。
        if(frame_ctx.dispatch.row_cmd_take && frame_ctx.dispatch.output_stage && output_columns_q!=frame_ctx.row.emit_hi-frame_ctx.row.emit_lo)$fatal(1,"TOP output length predecode mismatch"); // 行预检查必须为新描述符提供完整一拍。
        if(compute.engine.pixel_valid && !frame_ctx.phase.abort_req && !transfer.output_dma.sink_ready)$fatal(1,"TOP lost RGB output"); // 预留名额须覆盖全部在途结果。
    end // 模拟检查结束。
`endif // 模拟检查边界。
endmodule // ngm_npu_task_control结束。
