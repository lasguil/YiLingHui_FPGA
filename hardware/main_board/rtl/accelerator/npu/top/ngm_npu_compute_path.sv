// 协议契约：描述符slots×batches提供实际装载数；窄流元数据与容量ready连接主表和行引擎，不引入宽数据缓存。
// 协议契约：本模块拥有行定序、抽头供数、残差定时、唯一行引擎和A/B/C/D存储。
// frame_ctx.row描述符在本行期间保持；接受沿保存143位范围、局部首列和尺寸，真实首列复用行定序器cfg_x_start。
// 窗口row_clear延后一拍，在行定序器现有SETTLE拍使用已锁存的新描述符，首请求前完成清理。
// transfer经既有存储口写入/读取，返回数据直接供窗口或DMA；DDR事务状态归传输模块。
// 工作复位使用frame_ctx.dispatch.reset_work，由任务控制合入全局复位及安全清工作状态。
module ngm_npu_compute_path ( // 按功能边界组织系统集成。
    input wire clk, // 唯一工作时钟。
    input wire ngm_npu_types::frame_context_t frame_ctx, // 保持的任务描述符及控制。
    input wire ngm_npu_types::weight_write_t weight_write, // 只接收host的主表40位项写流。
    input wire ngm_npu_types::transfer_feedback_t transfer, // DMA状态、请求及数据。
    output wire ngm_npu_types::compute_feedback_t compute // 计算及存储反馈。
); // 功能边界接口结束。
    import ngm_npu_types::*; // 使用具名接口类型。

    typedef struct packed { // 行定序器的配置、issue节拍及结果坐标。
        logic [1:0] stage_read_slot; // 正在执行行槽。
        logic [1:0] stage_write_slot; // 正在执行行槽。
        logic [2:0] cfg_kind; // 运行形状，连接现有行引擎。
        logic [2:0] cfg_point_group; // 运行形状，连接现有行引擎。
        logic [1:0] cfg_slots; // 运行段数和批数。
        logic [1:0] cfg_batches; // 运行段数和批数。
        logic [10:0] cfg_x_start; // 直接让现有走位器使用真实列。
        logic [9:0] cfg_point_count; // 运行组数。
        logic win_req_valid; // 完整窗口逻辑请求。
        logic window_take; // 当拍行引擎真正消费一个窗口。
        logic issue_batch_last; // 当前实际批末issue和批号。
        logic issue_batch; // 当前实际批末issue和批号。
        logic [10:0] issue_x; // 当前issue所属真实组首列。
        logic [10:0] code_x; // 返回真实和AB局部列。
        logic [10:0] code_ab_col; // 返回真实和AB局部列。
    } local_row_t; // 本组位序由字段定义，不使用位置拼接。
    wire local_row_t row; // 当前子模块的内部连接。

    typedef struct packed { // 抽头读请求、装填写使能及窗口完成状态。
        logic win_req_ready; // 三个窄名额。
        logic req_valid; // memory_subsystem原字或整行重放请求。
        logic [10:0] req_row; // 实际源坐标。
        logic [10:0] req_x; // 实际源坐标。
        logic [10:0] req_ab_col; // 实际源坐标。
        logic [1:0] req_slot; // 行槽直通。
        logic req_subread; // Down上下行或Head两个双像素字。
        logic [10:0] replay_lo; // Body-H实际真实列读取范围。
        logic [10:0] replay_hi; // Body-H实际真实列读取范围。
        logic c_rsp_ready; // 返回直接写窗后才释放。
        logic d_rsp_ready; // 返回直接写窗后才释放。
        logic [1:0][1:0] load_group; // 组号。
        logic copy_window,right_reflect,head_padding; // 窗口内部固定复制与裁零授权。
        logic [15:0] load_cell_enable; // 每口八格使能。
        logic [3:0] load_byte_enable; // 每格四字节使能。
        logic window_done; // 完整窗口装好。
    } local_window_t; // 本组位序由字段定义，不使用位置拼接。
    wire local_window_t window; // 当前子模块的内部连接。

    typedef struct packed { // 按实际issue对齐的残差读请求。
        logic skip_req_valid; // 七拍后的C请求或六拍后的D请求。
        logic [10:0] skip_req_row; // 保持的当前结果行。
        logic [10:0] skip_req_x; // 与当前层所需延迟一致的真实列。
    } local_residual_t; // 本组位序由字段定义，不使用位置拼接。
    wire local_residual_t residual; // 当前子模块的内部连接。

    typedef struct packed { // 行引擎的权重提交、窗口消费及计算结果。
        logic row_boundary; // 点末issue和本行末点。
        logic [10:0] code_row; // 这个结果属于哪一行
        logic [10:0] code_x; // 行引擎真实组首列。
        logic residual_x_odd; // 第八拍Encoder残差所需列奇偶。
        logic code_batch; // 非RGB结果有效及批。
        logic [127:0] code_lanes; // 16 条车道的码
        logic [10:0] pixel_x; // RGB真实组首列。
        logic [1:0] pixel_beat; // RGB组内字节拍0/1/2。
    } local_engine_t; // 本组位序由字段定义，不使用位置拼接。
    wire local_engine_t engine; // 当前子模块的内部连接。

    typedef struct packed { // 片上存储的握手、读返回及结果整理接口。
        logic skip_req_ready; // 本拍对应bank读口可用，禁止仅按平均带宽判断。
        logic c_rsp_valid; // C/D原生单字返回。
        logic [10:0] c_rsp_x; // C16原字中的半字选择。
        logic [255:0] c_rsp_word; // RAM原生整字，不复制宽暂存。
        logic [255:0] d_rsp_front_word;logic [10:0] d_rsp_row; // Down固定物理源与返回parity。
        logic [127:0] d_rsp_rgb_word;logic [2:0] d_rsp_v_tags; // D原生装窗数据和窄标签。
        logic [127:0] d_rsp_half; // Decoder-H已经选好的半字。
        logic [1:0] fill_valid; // AB或D窗口返回。
        logic [1:0][1:0] fill_group; // 对应八格组。
        logic [1:0][255:0] fill_word; // 原有两个窗口口。
        logic fill_done; // 当前物理窗口完整。
        logic [127:0] d_skip; // Decoder-V residual 码，由计算侧延迟对齐。
        logic code_ready; // memory_subsystem.code_ready，包含最近邻第二行占用。
        logic [2:0] weight_stream_slot; // 主表返回槽。
        logic [5:0] weight_stream_pair; // 主表返回组。
        logic weight_stream_param,weight_stream_ready; // 参数标记及容量回压。
        logic weight_stream_valid; // 常驻槽的装载流有效
        logic [39:0] weight_stream_data; // 常驻槽的装载流数据（每拍两个字）
    } local_memory_t; // 本组位序由字段定义，不使用位置拼接。
    wire local_memory_t memory; // 当前子模块的内部连接。

    typedef struct packed { // 固定模型的合法层检查与权重地址。
        logic [1:0] slots,batches; // 装载描述符实际段数和批数。
        logic [11:0] weight_base; // 四十位项的两段基址。
        logic [11:0] param_base; // 四十位项的两段基址。
    } local_descriptor_t; // 本组位序由字段定义，不使用位置拼接。
    wire local_descriptor_t descriptor; // 当前子模块的内部连接。

    typedef struct packed { // 行命令或Stem输入DMA接受后的实际存储范围和尺寸。
        logic [10:0] emit_lo,emit_hi,write_center_lo,write_center_hi,read_center_lo,read_center_hi; // 不重复层号、行号、点数和行槽。
        logic [10:0] src_width,src_height,tail_base,bank_rgb_width; // 源尺寸和D布局只在行命令接受沿更新。
        logic [10:0] first_ab_col,read_lo,read_hi; // 局部首列与读取范围不能在运行时经过strip算术。
    } row_ranges_t; // 固定143位控制流水，无激活数据缓存。
    row_ranges_t ranges_q; // 计算进行期间不再经过frame/strip组合译码。
    logic row_clear_q; // 复用行定序器已有SETTLE拍，不增加行内issue间隔。
    always_ff @(posedge clk)begin // 窗口初始化必须晚于描述符锁存沿。
        if(frame_ctx.dispatch.reset_work)row_clear_q<=0; // 安全工作复位不保留旧清窗请求。
        else row_clear_q<=frame_ctx.dispatch.row_cmd_take; // 每个已接受行只清一次。
    end // 一位行边界流水结束。
    always_ff @(posedge clk)if(frame_ctx.dispatch.row_cmd_take || (frame_ctx.input_row.valid && transfer.input_dma.start_ready))begin // Stem输入DMA可早于权重装好，必须在首个段读前保存其尺寸。
        ranges_q.emit_lo<=frame_ctx.row.emit_lo;ranges_q.emit_hi<=frame_ctx.row.emit_hi; // 结果裁剪。
        ranges_q.write_center_lo<=frame_ctx.row.write_center_lo;ranges_q.write_center_hi<=frame_ctx.row.write_center_hi; // C写地址。
        ranges_q.read_center_lo<=frame_ctx.row.read_center_lo;ranges_q.read_center_hi<=frame_ctx.row.read_center_hi; // C读取及重放范围。
        ranges_q.src_width<=frame_ctx.row.read_width;ranges_q.src_height<=frame_ctx.row.read_height; // 逐层reflect的实际张量尺寸。
        ranges_q.tail_base<=frame_ctx.strip.tail_base;ranges_q.bank_rgb_width<=frame_ctx.strip.bank_rgb_width; // D局部地址和RGB保存宽度。
        ranges_q.first_ab_col<=frame_ctx.row.ab_col; // 保存局部首列；真实首列已有行定序器寄存器。
        ranges_q.read_lo<=frame_ctx.row.read_lo;ranges_q.read_hi<=frame_ctx.row.read_hi; // Head/横向窗口的实际保存范围。
    end // 只有真实命令才能更新；valid由已有行生命周期保证，无数据复位。
    logic [4:0] memory_layer_q; // 存储相位提前一拍译码，中止沿保持正在执行的布局。
    always_ff @(posedge clk)begin // 行命令预检查与SETTLE保证首读写前层号已经稳定。
        if(frame_ctx.dispatch.reset_work)memory_layer_q<=0; // 新帧先进入前端布局。
        else if(!frame_ctx.phase.abort_req)memory_layer_q<=frame_ctx.row.layer; // 抢占后冻结层号直到工作复位。
    end // 只增加五位窄控制，不增加数据缓存。
    // ---------- 结果空间授权与残差固定置换 ----------
    wire window_room=!frame_ctx.dispatch.output_stage || transfer.output_dma.window_room; // 发窗口前保留结果流水全部空间。
    wire [127:0] front_skip=p16(engine.residual_x_odd ? memory.c_rsp_word[255:128] : memory.c_rsp_word[127:0]); // Encoder按实际结果列取半字。
    wire [255:0] skip_codes=compute.row.stage_layer_id==2 ? {front_skip,front_skip} : (compute.row.stage_layer_id==5 || compute.row.stage_layer_id==7 || compute.row.stage_layer_id==9 || compute.row.stage_layer_id==11) ? p32(memory.c_rsp_word) : {p16(memory.d_skip),p16(memory.d_skip)}; // 全部通道置换是固定连线。
    function automatic [127:0] p16(input logic [127:0] v); // 残差物理布局转PE布局。
        for(int c=0;c<16;c++)p16[c*8+:8]=v[(c%4*4+c/4)*8+:8]; // 固定展开。
    endfunction // C16置换结束。
    function automatic [255:0] p32(input logic [255:0] v); // C32残差固定置换。
        for(int c=0;c<32;c++)p32[c*8+:8]=v[(c%4*8+c/4)*8+:8]; // 固定展开。
    endfunction // C32置换结束。

    ngm_row_sequencer u_row_sequencer ( // 将行命令转换为窗口与实际issue节拍。
        .clk                   (clk), // 时钟与同步复位。
        .reset                 (frame_ctx.dispatch.reset_work), // 时钟与同步复位。
        .cmd_valid             (frame_ctx.row.valid && !frame_ctx.phase.abort_req && (!frame_ctx.dispatch.output_stage || transfer.output_dma.row_ready)), // 行命令和对应权重已装好。
        .cmd_weights_ready     (frame_ctx.dispatch.weights_ready), // 行命令和对应权重已装好。
        .cmd_ready             (compute.row.cmd_ready), // 接受命令指示。
        .cmd_layer_id          (frame_ctx.row.layer), // 待执行层。
        .cmd_row               (frame_ctx.row.id), // 真实行号。
        .cmd_x_start           (frame_ctx.row.x), // 真实和AB局部行首。
        .cmd_ab_col_start      (frame_ctx.row.ab_col), // 真实和AB局部行首。
        .cmd_point_count       (frame_ctx.row.count), // 调用方已按1/4/5打包的完整组数。
        .cmd_read_slot         (frame_ctx.row.read_slot), // 中心读槽和结果写槽。
        .cmd_write_slot        (frame_ctx.row.write_slot), // 中心读槽和结果写槽。
        .next_desc_valid       (), // 本层不使用该输出，显式留空。
        .next_weight_base      (), // 本层不使用该输出，显式留空。
        .next_param_base       (), // 本层不使用该输出，显式留空。
        .busy                  (compute.row.busy), // 当前行占用与已全部写回脉冲。
        .row_done              (compute.row.row_done), // 当前行占用与已全部写回脉冲。
        .stage_layer_id        (compute.row.stage_layer_id), // 正在执行层，保持至完成。
        .stage_row             (compute.row.stage_row), // 正在执行行。
        .stage_read_slot       (row.stage_read_slot), // 正在执行行槽。
        .stage_write_slot      (row.stage_write_slot), // 正在执行行槽。
        .cfg_kind              (row.cfg_kind), // 运行形状，连接现有行引擎。
        .cfg_point_group       (row.cfg_point_group), // 运行形状，连接现有行引擎。
        .cfg_slots             (row.cfg_slots), // 运行段数和批数。
        .cfg_batches           (row.cfg_batches), // 运行段数和批数。
        .cfg_x_start(row.cfg_x_start), // 已接受行的真实首列。
        .cfg_point_count       (row.cfg_point_count), // 运行组数。
        .engine_row_start_valid(compute.row.engine_row_start_valid), // 首窗口和行配置联合启动请求。
        .engine_row_ready      (compute.engine.row_ready), // 现有行引擎行握手。
        .win_req_valid         (row.win_req_valid), // 完整窗口逻辑请求。
        .win_req_ready         (window.win_req_ready && window_room && !frame_ctx.phase.abort_req), // 窗口供数路径可接收。
        .win_x                 (), // 本层不使用该输出，显式留空。
        .win_ab_col            (), // 本层不使用该输出，显式留空。
        .window_done           (window.window_done), // 完整窗口装好。
        .engine_window_released(compute.engine.window_released), // 点末issue和本行末点。
        .engine_row_boundary   (engine.row_boundary), // 点末issue和本行末点。
        .window_take           (row.window_take), // 当拍行引擎真正消费一个窗口。
        .issue_batch_last      (row.issue_batch_last), // 当前实际批末issue和批号。
        .issue_batch           (row.issue_batch), // 当前实际批末issue和批号。
        .issue_x               (row.issue_x), // 当前issue所属真实组首列。
        .engine_code_valid     (compute.engine.code_valid && !frame_ctx.phase.abort_req), // 非RGB结果有效及批。
        .engine_code_batch     (engine.code_batch), // 非RGB结果有效及批。
        .engine_code_x         (engine.code_x), // 行引擎真实组首列。
        .code_sink_ready       (memory.code_ready), // memory_subsystem.code_ready，包含最近邻第二行占用。
        .code_x                (row.code_x), // 返回真实和AB局部列。
        .code_ab_col           (row.code_ab_col), // 返回真实和AB局部列。
        .engine_pixel_valid    (compute.engine.pixel_valid && !frame_ctx.phase.abort_req), // RGB字节有效和输出队列接收。
        .pixel_sink_ready      (transfer.output_dma.sink_ready), // RGB字节有效和输出队列接收。
        .engine_pixel_beat     (engine.pixel_beat), // RGB组内字节拍0/1/2。
        .engine_pixel_x        (engine.pixel_x), // RGB真实组首列。
        .pixel_x               (), // 本层不使用该输出，显式留空。
        .protocol_error        (compute.row.protocol_error) // 命令或无回压结果错误保持。
    ); // ngm_row_sequencer连接结束。

    ngm_window_source u_window_source ( // RAM返回直接装填既有乒乓窗口。
        .clk                   (clk), // 时钟、工作复位与新行命令。
        .reset                 (frame_ctx.dispatch.reset_work), // 时钟、工作复位与新行命令。
        .row_clear             (row_clear_q), // SETTLE拍清理，使用前一沿已锁存的新行描述符。
        .layer                 (compute.row.stage_layer_id), // 当前固定模型层。
        .row                   (compute.row.stage_row), // 行描述符保持至排空。
        .first_x               (row.cfg_x_start), // 复用行定序器已有真实首列寄存器。
        .first_ab_col          (ranges_q.first_ab_col), // 已接受行的AB局部首列。
        .src_width             (ranges_q.src_width), // 已接受行的源尺寸，不经过strip组合运算。
        .read_lo               (ranges_q.read_lo), // 已接受行的读取起点。
        .read_hi               (ranges_q.read_hi), // 已接受行的读取尾界。
        .point_count           (row.cfg_point_count), // 本行逻辑窗口数。
        .slot                  (row.stage_read_slot), // 当前三行环中心槽。
        .win_req_valid         (row.win_req_valid && window_room && !frame_ctx.phase.abort_req), // 行定序器的逻辑请求。
        .win_req_ready         (window.win_req_ready), // 三个窄名额。
        .window_take           (row.window_take), // 真实点引擎消费一个完整窗口。
        .req_valid             (window.req_valid), // memory_subsystem原字或整行重放请求。
        .req_ready             (compute.memory.req_ready && !transfer.input_pair.req_valid && !frame_ctx.phase.abort_req), // 原字请求接受。
        .req_row               (window.req_row), // 实际源坐标。
        .req_x                 (window.req_x), // 实际源坐标。
        .req_ab_col            (window.req_ab_col), // 实际源坐标。
        .req_slot              (window.req_slot), // 行槽直通。
        .req_subread           (window.req_subread), // Down上下行或Head两个双像素字。
        .replay_lo             (window.replay_lo), // Body-H实际真实列读取范围。
        .replay_hi             (window.replay_hi), // Body-H实际真实列读取范围。
        .c_rsp_valid           (memory.c_rsp_valid), // C/D原生单字返回。
        .d_rsp_valid           (compute.memory.d_rsp_valid && compute.row.stage_layer_id!=0), // C/D原生单字返回。
        .c_rsp_ready           (window.c_rsp_ready), // 返回直接写窗后才释放。
        .d_rsp_ready           (window.d_rsp_ready), // 返回直接写窗后才释放。
        .bank_fill_valid       (memory.fill_valid), // AB或D窗口返回。
        .bank_fill_group       (memory.fill_group), // 对应八格组。
        .bank_fill_done        (memory.fill_done), // 当前物理窗口完整。
        .stem_valid            (transfer.input_pair.pair_valid && !frame_ctx.phase.abort_req), // RGB配对器一个PixelUnshuffle结果。
        .stem_ready            (compute.window.stem_ready), // 直接写窗时接受。
        .load_valid            (compute.window.load_valid), // 现有窗口两写口。
        .load_group            (window.load_group), // 组号。
        .copy_window(window.copy_window),.right_reflect(window.right_reflect),.head_padding(window.head_padding), // 窄路由控制。
        .load_cell_enable      (window.load_cell_enable), // 每口八格使能。
        .load_byte_enable      (window.load_byte_enable), // 每格四字节使能。
        .window_done           (window.window_done), // 与最后一次写入同拍。
        .idle                  (compute.window.idle), // 排空和硬件错误保持。
        .protocol_error        (compute.window.protocol_error) // 排空和硬件错误保持。
    ); // ngm_window_source连接结束。

    ngm_residual_schedule u_residual_schedule ( // 以实际issue延迟发起残差读取。
        .clk                   (clk), // 安全工作复位。
        .reset                 (frame_ctx.dispatch.reset_work || frame_ctx.phase.abort_req), // 安全工作复位。
        .layer_id              (compute.row.stage_layer_id), // 当前保持的实际层。
        .stage_row             (compute.row.stage_row), // 当前结果行，直到排空保持。
        .issue_batch_last      (row.issue_batch_last), // 实际批末issue及低高批。
        .issue_batch           (row.issue_batch), // 实际批末issue及低高批。
        .issue_x               (row.issue_x), // 实际issue的真实像素列。
        .skip_req_valid        (residual.skip_req_valid), // 七拍后的C请求或六拍后的D请求。
        .skip_req_ready        (memory.skip_req_ready), // 本拍对应bank读口可用，禁止仅按平均带宽判断。
        .skip_req_row          (residual.skip_req_row), // 保持的当前结果行。
        .skip_req_x            (residual.skip_req_x), // 与当前层所需延迟一致的真实列。
        .protocol_error        (compute.residual.protocol_error) // 错过请求时隙保持错误到复位。
    ); // ngm_residual_schedule连接结束。

    wire result_in_range; // Carries the accepted point range through the existing tag pipeline.
    ngm_conv_row_engine u_conv_row_engine ( // 唯一PE阵列及结果流水。
        .clk                   (clk), // 时钟
        .reset                 (frame_ctx.dispatch.reset_work), // 同步复位（高有效）
        .row_start_valid       (compute.row.engine_row_start_valid && !frame_ctx.phase.abort_req), // 上一级要开始一行
        .row_ready             (compute.engine.row_ready), // 本模块可以接下一行（够数据 + 窗口空 + 点引擎闲）
        .cfg_kind              (row.cfg_kind), // 通路编号（0=1×1、1=enc/dec、2=body、3=head、4=rgb）
        .cfg_slots             (row.cfg_slots), // 段数（计数：1/2/3）
        .cfg_batches           (row.cfg_batches), // 批数（计数：1/2）
        .cfg_point_group       (row.cfg_point_group), // 每组几个像素（1/4/5：head=4、rgb=5、其余=1）
        .emit_lo(ranges_q.emit_lo),.emit_hi(ranges_q.emit_hi),
        .cfg_x_start(row.cfg_x_start), // 已接受行的真实首列。
        .cfg_point_count       (row.cfg_point_count), // 本行一共几组
        .cfg_row               (compute.row.stage_row), // 本行行号（跟着结果一起走）
        .load_valid            (compute.window.load_valid), // 第 i 个写口这一拍要写
        .load_group            (window.load_group), // 第 i 个写口写进哪一组（一组 8 格）
        .load_layer(compute.row.stage_layer_id),.copy_window(window.copy_window), // 描述符与内部复制。
        .right_reflect(window.right_reflect),.head_padding(window.head_padding), // 边界授权。
        .c_source_word(memory.c_rsp_word),.c_source_odd(memory.c_rsp_x[0]), // 前端与Body原字。
        .d_source_rgb_word(memory.d_rsp_rgb_word),.d_source_v_tags(memory.d_rsp_v_tags),.d_source_front_word(memory.d_rsp_front_word),.d_source_word(compute.memory.d_rsp_word),.d_source_half(memory.d_rsp_half), // D原生读取。
        .stem_source_word(transfer.input_pair.pair_data),.bank_source_word(memory.fill_word), // Stem与纵向抽头。
        .load_cell_enable      (window.load_cell_enable), // 窗口逐格写使能，正常整字装填全一。
        .load_byte_enable      (window.load_byte_enable), // Down分两行写入对应字节，其他层全一。
        .fill_done             (window.window_done), // 一拍脉冲：往窗口里装的那一组已经写完了（不带半区信息）
        .window_released       (compute.engine.window_released), // 本组最后一刀那一拍（上游据此推它自己的账）
        .row_boundary          (engine.row_boundary), // 上面那一拍属于本行最后一组
        .weight_stream_slot(memory.weight_stream_slot),.weight_stream_pair(memory.weight_stream_pair), // 返回位置。
        .weight_stream_param(memory.weight_stream_param),.weight_stream_ready(memory.weight_stream_ready), // 回压。
        .weight_stream_valid   (memory.weight_stream_valid), // 常驻槽的装载流有效
        .weight_stream_data    (memory.weight_stream_data), // 常驻槽的装载流数据（每拍两个字）
        .skip_codes            (skip_codes), // 逐批残差半字在第8拍消费，最终结果第9拍输出
        .code_in_range(result_in_range),
        .code_valid            (compute.engine.code_valid), // 这一拍有一个结果码
        .code_row              (engine.code_row), // 这个结果属于哪一行
        .code_x                (engine.code_x), // 这个结果属于哪一组（本组第一个像素的列号）
        .residual_x_odd(engine.residual_x_odd), // 残差选半字不跟随新增结果拍。
        .code_batch            (engine.code_batch), // 这个结果属于哪一批
        .code_lanes            (engine.code_lanes), // 16 条车道的码
        .pixel_valid           (compute.engine.pixel_valid), // 这一拍有 5 个像素
        .pixel_row             (), // 本层不使用该输出，显式留空。
        .pixel_x               (engine.pixel_x), // 这一拍 5 个字节从哪个像素算起（本组第一个像素）
        .pixel_beat            (engine.pixel_beat), // 这一拍是本组的第几拍（0/1/2，一组三拍）
        .pixel_bytes           (compute.engine.pixel_bytes), // 5 个字节：第 i 个字节 = 本组第 5*beat+i 个字节
        .protocol_error        (compute.engine.protocol_error) // 自查：上面四条里任意一条中了
    ); // ngm_conv_row_engine连接结束。

    ngm_memory_subsystem u_memory_subsystem ( // A/B/C/D、权重主表与结果整理。
        .clk                   (clk), // 时钟与同步复位。
        .reset                 (frame_ctx.dispatch.reset_work), // 时钟与同步复位。
        .io_wr_valid           (transfer.output_dma.io_wr_valid), // C已分配空闲字的输出队列写。
        .io_wr_ready           (compute.memory.io_wr_ready), // C已分配空闲字的输出队列写。
        .io_wr_addr            (transfer.output_dma.io_wr_addr), // 队列物理地址。
        .io_rgb_word           (transfer.output_dma.io_rgb_word), // RGB五字节与三位有效长度，Down整字已经在rf_data上。
        .io_rd_valid           (transfer.output_dma.io_rd_valid), // C输出队列原生读。
        .io_rd_ready           (compute.memory.io_rd_ready), // C输出队列原生读。
        .io_rd_addr            (transfer.output_dma.io_rd_addr), // 队列物理读地址。
        .io_rsp_valid          (compute.memory.io_rsp_valid), // 原生返回保持。
        .io_rsp_ready          (transfer.output_dma.io_rsp_ready), // 原生返回保持。
        .io_rsp_word           (compute.memory.io_rsp_word), // 输出队列原生整字。
        .prefix_write          (transfer.output_dma.prefix_write), // RGB对齐更新整理器既有寄存器。
        .prefix_data           (transfer.output_dma.prefix_data), // RGB对齐更新整理器既有寄存器。
        .prefix_value          (compute.memory.prefix_value), // 对齐器的分时共享寄存器。
        .layer_id              (memory_layer_q), // 当前模型层号。
        .strip_start           (frame_ctx.strip.start), // 新 strip 静止边界。
        .tail_base             (ranges_q.tail_base), // 已接受行的D真实列基址。
        .bank_rgb_width        (ranges_q.bank_rgb_width), // 已接受行的RGB物理保存宽度。
        .req_valid             ((transfer.input_pair.req_valid || window.req_valid) && !frame_ctx.phase.abort_req), // 单字、窗口或整行重放请求。
        .req_ready             (compute.memory.req_ready), // 所有参与客户原子接受。
        .req_row               (transfer.input_pair.req_valid ? (frame_ctx.input_row.row >> 1) : window.req_row), // 请求行与源张量高度。
        .src_height            (ranges_q.src_height), // 已接受行的源张量高度。
        .req_x                 (transfer.input_pair.req_valid ? {6'd0,transfer.input_pair.req_word} : window.req_x), // 请求列与源张量宽度。
        .src_width             (ranges_q.src_width), // 已接受行的源张量宽度。
        .req_ab_col            (transfer.input_pair.req_valid ? 11'd0 : window.req_ab_col), // Body-V 在 AB 行槽内的局部列，前端忽略。
        .req_slot              (transfer.input_pair.req_valid ? 2'd0 : window.req_slot), // 中心三行环槽。
        .req_subread           (!transfer.input_pair.req_valid && window.req_subread), // Down 源行或 Head 组内原字。
        .skip_req_valid        (residual.skip_req_valid && !frame_ctx.phase.abort_req), // Encoder/Body/Decoder-V的独立定时残差读，不随抽头提前读取。
        .skip_req_ready        (memory.skip_req_ready), // 对应C/D残差时隙可接受。
        .skip_req_row          (residual.skip_req_row), // 实际结果所需的真实输入行。
        .skip_req_x            (residual.skip_req_x), // 实际结果所需的中心列，前端可每两像素读一个整字。
        .read_center_lo        (ranges_q.read_center_lo), // C 中心范围与实际重放范围。
        .read_center_hi        (ranges_q.read_center_hi), // C 中心范围与实际重放范围。
        .replay_x_lo           (window.replay_lo), // C 中心范围与实际重放范围。
        .replay_x_hi           (window.replay_hi), // C 中心范围与实际重放范围。
        .replay_busy           (), // 本层不使用该输出，显式留空。
        .replay_done           (), // 本层不使用该输出，显式留空。
        .c_rsp_valid           (memory.c_rsp_valid), // C 单字或重放返回。
        .c_rsp_ready           (window.c_rsp_ready), // C 返回接收。
        .c_rsp_kind            (), // 本层不使用该输出，显式留空。
        .c_rsp_row             (), // 本层不使用该输出，显式留空。
        .c_rsp_x               (memory.c_rsp_x), // C 返回真实列。
        .c_rsp_word            (memory.c_rsp_word), // C 原始整字，前端客户按列选半字。
        .d_rsp_valid           (compute.memory.d_rsp_valid), // D 单字返回。
        .d_rsp_ready           (compute.row.stage_layer_id==0 || transfer.input_dma.busy ? transfer.input_pair.rsp_ready : window.d_rsp_ready), // D 返回接收。
        .d_rsp_kind            (), // 本层不使用该输出，显式留空。
        .d_rsp_row             (memory.d_rsp_row), // 本层不使用该输出，显式留空。
        .d_rsp_x               (), // 本层不使用该输出，显式留空。
        .d_rsp_rgb_word(memory.d_rsp_rgb_word),.d_rsp_v_tags(memory.d_rsp_v_tags),.d_rsp_front_word      (memory.d_rsp_front_word), // Down组0物理数据。
        .d_rsp_input_word      (compute.memory.d_rsp_input_word), // 输入段固定端口。
        .d_rsp_word            (compute.memory.d_rsp_word), // D 原始整字。
        .d_rsp_half            (memory.d_rsp_half), // D 已选 C16 半字。
        .fill_valid            (memory.fill_valid), // 两个窗口写口有效。
        .fill_group            (memory.fill_group), // 每口写入的八格组号。
        .fill_word             (memory.fill_word), // 合并后的窗口数据。
        .fill_done             (memory.fill_done), // 当前窗口装填完成。
        .d_skip_valid          (), // 本层不使用该输出，显式留空。
        .d_skip                (memory.d_skip), // Decoder-V residual 码，由计算侧延迟对齐。
        .code_abort(frame_ctx.phase.abort_req), // 即时禁止落字，地址与数据选择仍由寄存结果决定。
        .code_in_range(result_in_range),
        .code_valid            (compute.engine.code_valid), // 行引擎无回压结果有效。
        .code_ready            (memory.code_ready), // 供调度检查结果接收能力。
        .code_row              (engine.code_row), // 结果真实行。
        .code_x                (row.code_x), // 结果组首列。
        .code_ab_col           (row.code_ab_col), // Body-H 写 AB 的行槽内局部列，其余层忽略。
        .code_batch            (engine.code_batch), // C32 低或高批。
        .code_slot             (row.stage_write_slot), // 目标行环槽。
        .code_lanes            (engine.code_lanes), // 十六条 INT8 车道。
        .emit_lo               (ranges_q.emit_lo), // 保存范围与 C 中心范围。
        .emit_hi               (ranges_q.emit_hi), // 保存范围与 C 中心范围。
        .write_center_lo       (ranges_q.write_center_lo), // 保存范围与 C 中心范围。
        .write_center_hi       (ranges_q.write_center_hi), // 保存范围与 C 中心范围。
        .checkpoint_valid      (compute.memory.checkpoint_valid), // Down 的整帧 X0 写出。
        .checkpoint_ready      (transfer.output_dma.sink_ready), // DDR 写队列接收。
        .checkpoint_row        (), // 本层不使用该输出，显式留空。
        .checkpoint_x          (), // 本层不使用该输出，显式留空。
        .checkpoint_data       (), // 本层不使用该输出，显式留空。
        .checkpoint_begin      (), // 本层不使用该输出，显式留空。
        .checkpoint_last       (), // 本层不使用该输出，显式留空。
        .dma_valid             (transfer.input_dma.busy ? transfer.input_dma.dma_valid : transfer.x0_dma.dma_valid), // DDR 读回 X0 待写入。
        .dma_ready             (compute.memory.dma_ready), // 所需目标全部可收。
        .dma_to_c              (!transfer.input_dma.busy), // 一为同时装 C 的 X0 residual，零为只预取 D。
        .dma_row               (transfer.input_dma.busy ? transfer.input_dma.dma_row : transfer.x0_dma.dma_row), // X0 真实行。
        .dma_x                 (transfer.input_dma.busy ? 11'd0 : transfer.x0_dma.dma_x), // C 使用的真实列。
        .dma_word              (transfer.input_dma.busy ? transfer.input_dma.dma_word : transfer.x0_dma.dma_word), // D 使用的局部字号。
        .dma_data              (transfer.input_dma.busy ? transfer.input_dma.dma_data : transfer.x0_dma.dma_data), // 两片共用的 DMA 数据。
        .dma_begin             (transfer.input_dma.busy ? transfer.input_dma.dma_word==0 : transfer.x0_dma.dma_begin), // X0 行首与行末。
        .dma_last              (transfer.input_dma.busy ? transfer.input_dma.dma_last : transfer.x0_dma.dma_last), // X0 行首与行末。
        .dma_center_lo         (transfer.x0_dma.dma_center_lo), // DMA 的 C 中心范围。
        .dma_center_hi         (transfer.x0_dma.dma_center_hi), // DMA 的 C 中心范围。
        .layer_count(3'(descriptor.slots)*3'(descriptor.batches)), // 只装实际有效上下文。
        .layer_load_start      (frame_ctx.dispatch.layer_load_start), // 本层权重装载请求。
        .layer_load_ready      (compute.memory.layer_load_ready), // 本层权重装载可开始。
        .layer_weight_base     (descriptor.weight_base), // 四十位项的两段基址。
        .layer_param_base      (descriptor.param_base), // 四十位项的两段基址。
        .layer_load_done       (compute.memory.layer_load_done), // 权重装载完成与流有效。
        .weight_stream_slot(memory.weight_stream_slot),.weight_stream_pair(memory.weight_stream_pair), // 返回位置。
        .weight_stream_param(memory.weight_stream_param),.weight_stream_ready(memory.weight_stream_ready), // 回压。
        .weight_stream_valid   (memory.weight_stream_valid), // 权重装载完成与流有效。
        .weight_stream_data    (memory.weight_stream_data), // 每拍两个二十位字。
        .reload_valid          (weight_write.valid), // 主机整表重载。
        .reload_ready          (compute.memory.reload_ready), // 主表可接收重载。
        .reload_addr           (weight_write.addr), // 四十位项地址。
        .reload_data           (weight_write.data), // 四十位项数据。
        .reload_active         (), // 本层不使用该输出，显式留空。
        .protocol_error        (compute.memory.protocol_error) // 子模块与路由错误合并。
    ); // ngm_memory_subsystem连接结束。

    ngm_descriptor_store u_descriptor_store ( // 为下一权重装载查询固定模型描述符。
        .layer_id              (frame_ctx.dispatch.wanted_layer), // 查询层号。
        .desc_valid            (compute.descriptor.desc_valid), // 当前层号有效。
        .kind                  (), // 本层不使用该输出，显式留空。
        .slots                 (descriptor.slots), // 本层不使用该输出，显式留空。
        .batches               (descriptor.batches), // 本层不使用该输出，显式留空。
        .point_group           (), // 本层不使用该输出，显式留空。
        .weight_base           (descriptor.weight_base), // 主表两个起始项地址。
        .param_base            (descriptor.param_base) // 主表两个起始项地址。
    ); // ngm_descriptor_store连接结束。
endmodule // ngm_npu_compute_path结束。
