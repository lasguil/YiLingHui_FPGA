/* OPTIMIZATION_NOTE_20261005
 * 压缩存储集成约束（2026-10-05）：A/B/C特征域为0..127，D/原始RGB/有符号Head保留8位。
 * C的io_rgb_mode由固定layer16语义产生，必须随真正读接受锁存，返回不能重新按当前层解释。
 * 固定17层及角色分配是压缩前提；改层号/码域须一起审查bank、tap_window和operand_former。
 * 逻辑128/256位总线、40bit权重包及DDR格式保持原合同；片内压缩不等于片外带宽压缩。
 * SIM_ASSERT仅在仿真启用，不能依赖它在硬件拒绝不兼容模型。
 * 详见 docs/OPTIMIZATION_CONSTRAINTS.md。
 */
// 协议契约：fill_word只携带A/B数据，D窗口客户直接使用物理出口；窄valid/group仍统一交供数器握手。
// 协议契约：D的half出口固定Decoder-H组1 A口；其他D客户只使用各自物理整字或input出口，源字段无valid时不解释。
// 协议契约：D返回按物理客户静态分流，不先选公共256位字；新增输出只是现有原生连线。
// 协议契约：read_center/replay范围由上游行配置保持到idle，不允许在挂起请求期间改变；这里不重复保存稳定行字段。
// 协议契约：Encoder-V口0保存外侧物理组0/1，口1低128位是中行，高字节是外侧槽标签；窗口端不得按上下顺序解释。
// 协议契约：A/B前端逻辑128位、Body逻辑256位；D保留完整8位，A/B/C特征按7位存储，逻辑布局不变。
// 协议契约：主表按实际槽数装载，返回槽/组/类型随valid保持，ready由常驻槽决定；激活RAM布局和读写协议不变。
// 协议契约：当前层保持到请求、结果与写口全部排空；切前端相位后至少空一拍。
// code_abort当拍禁止所有计算落字及checkpoint输出；原始code_valid继续选择结果地址/数据，DDR排空读写独立进行。
// 请求在 req_valid && req_ready 接受，描述符缓存一级；内部等待期间字段保持，前端稳态可每拍接受。
// C单字与重放互斥；Encoder/Body-V的抽头请求仅访问AB，C残差由独立skip_req按实际issue延迟发起。
// skip_req在V层独占C单字口，字段保持至ready；C原生返回不新增宽缓存，下一次读前可直接复用整字两批/半字。
// 非V层仍由req控制C单字或重放；C offer不依赖自身ready，避免握手组合环。
// Body的req_ab_col/code_ab_col是局部列；req_x/code_x与C中心范围是真实列，调度按行计数转换。
// C计算与C/D镜像DMA按整行仲裁；只写D的DMA可并行。DMA等待时保持行字段与当前字。
// X0预取的完整范围写D；dma_to_c为一时仅将[dma_center_lo,dma_center_hi)写C，halo不得进入C中心槽。
// C的DMA行首/末由中心首/末列生成，D仍使用完整预取范围的dma_begin/dma_last；整段DMA保持原行归属。
// 计算流水不能回压，调度必须预留写时隙；code_ready暴露冲突。fill无回压，valid时当拍消费。
// tail_base是本strip Body3保存首列；尾部真实列进入D后换算局部地址，bank_rgb_width给RGB保存区宽度。
// Reduce/Head只写一条物理源行；Decoder-H只算扩展偶行，V结果固定写D槽1供Head读取。
// C/D单字返回按valid/ready消费；RAM的rd_valid驱动物理RE，暂停读期间独立写不改变已有返回。
// strip_start只能在所有请求、写行、重放和返回排空后发出；reset清有效位，无效数据不可消费。
// Stem帧输入、最终RGB sigmoid/帧输出与横向窗口公共列组织由顶层和行调度完成。
// Stem(layer0)的req_x为输入上行段DDR拍号0..23；dma_to_c=0将低128位原始RGB拍写D前端空闲尾区。
// 上行段最后拍提交后才能读；不得把行引擎逻辑win_x直接接Stem的原字读取请求。
// 输出队列复用C前端空闲64字或Reduce已消费的X4槽64字；IO地址生命周期由帧适配层保证。
// IO写数据共用C既有总线：Down取rf_data，RGB只替换低43位；IO写与C镜像DMA互斥。
// IO读复用C原生输出及保持，C读客户阶段开始前必须排空；RGB前缀分时复用整理器128位暂存。
module ngm_memory_subsystem #( // 只有标签位宽参数化，数据宽度固定。
    parameter int unsigned ROW_W=11, // 行号位宽。
    parameter int unsigned COL_W=11 // 列号位宽。
)( // 子系统接口。
    input logic clk,reset, // 时钟与同步复位。
    input logic io_wr_valid,output logic io_wr_ready, // C已分配空闲字的输出队列写。
    input logic [9:0] io_wr_addr, // 队列物理地址。
    input logic [42:0] io_rgb_word, // RGB五字节与三位有效长度，Down整字已经在rf_data上。
    input logic io_rd_valid,output logic io_rd_ready, // C输出队列原生读。
    input logic [9:0] io_rd_addr, // 队列物理读地址。
    output logic io_rsp_valid,input logic io_rsp_ready, // 原生返回保持。
    output logic [255:0] io_rsp_word, // 输出队列原生整字。
    input logic prefix_write,input logic [127:0] prefix_data, // RGB对齐更新整理器既有寄存器。
    output wire [127:0] prefix_value, // 对齐器的分时共享寄存器。
    input logic [4:0] layer_id, // 当前模型层号。
    input logic strip_start, // 新 strip 静止边界。
    input logic [COL_W-1:0] tail_base, // 本strip Body3保存首列，整个strip保持。
    input logic [COL_W-1:0] bank_rgb_width, // RGB本strip保存宽度，整幅src_width仍用于逻辑坐标契约。
    input logic req_valid, // 单字、窗口或整行重放请求。
    output logic req_ready, // 所有参与客户原子接受。
    input logic [ROW_W-1:0] req_row,src_height, // 请求行与源张量高度。
    input logic [COL_W-1:0] req_x,src_width, // 请求列与源张量宽度。
    input logic [COL_W-1:0] req_ab_col, // Body-V 在 AB 行槽内的局部列，前端忽略。
    input logic [1:0] req_slot, // 中心三行环槽。
    input logic req_subread, // Down 源行或 Head 组内原字。
    input logic skip_req_valid, // Encoder/Body/Decoder-V的独立定时残差读，不随抽头提前读取。
    output logic skip_req_ready, // 对应C/D残差时隙可接受。
    input logic [ROW_W-1:0] skip_req_row, // 实际结果所需的真实输入行。
    input logic [COL_W-1:0] skip_req_x, // 实际结果所需的中心列，前端可每两像素读一个整字。
    input logic [COL_W-1:0] read_center_lo,read_center_hi,replay_x_lo,replay_x_hi, // C 中心范围与实际重放范围。
    output logic replay_busy,replay_done, // 自动重放状态。
    output logic c_rsp_valid, // C 单字或重放返回。
    input logic c_rsp_ready, // C 返回接收。
    output logic [1:0] c_rsp_kind, // C residual、Tail、前端或重放类型。
    output logic [ROW_W-1:0] c_rsp_row, // C 返回真实行。
    output logic [COL_W-1:0] c_rsp_x, // C 返回真实列。
    output logic [255:0] c_rsp_word, // C 原始整字，前端客户按列选半字。
    output logic d_rsp_valid, // D 单字返回。
    input logic d_rsp_ready, // D 返回接收。
    output logic [2:0] d_rsp_kind, // D 单字客户类型。
    output logic [ROW_W-1:0] d_rsp_row, // D 返回行。
    output logic [COL_W-1:0] d_rsp_x, // D 返回列。
    output wire [255:0] d_rsp_front_word, // Down的组0物理源。
    output wire [127:0] d_rsp_rgb_word, // D原生RGB源字，不经过A/B客户汇合。
    output wire [2:0] d_rsp_v_tags, // D原生V窄标签。
    output wire [127:0] d_rsp_input_word, // Stem输入段固定端口。
    output logic [255:0] d_rsp_word, // D 原始整字。
    output logic [127:0] d_rsp_half, // D 已选 C16 半字。
    output logic [1:0] fill_valid, // 两个窗口写口有效。
    output logic [1:0][1:0] fill_group, // 每口写入的八格组号。
    output logic [1:0][255:0] fill_word, // 合并后的窗口数据。
    output logic fill_done, // 当前窗口装填完成。
    output logic d_skip_valid, // Decoder-V residual 返回有效。
    output logic [127:0] d_skip, // Decoder-V residual 码，由计算侧延迟对齐。
    input logic code_abort, // 抢占只抑制模型落字，不参与写数据及地址来源选择；IO继续排空。
    input logic code_in_range, // Precomputed point range, aligned with code_valid.
    input logic code_valid, // 行引擎无回压结果有效。
    output logic code_ready, // 供调度检查结果接收能力。
    input logic [ROW_W-1:0] code_row, // 结果真实行。
    input logic [COL_W-1:0] code_x, // 结果组首列。
    input logic [COL_W-1:0] code_ab_col, // Body-H 写 AB 的行槽内局部列，其余层忽略。
    input logic code_batch, // C32 低或高批。
    input logic [1:0] code_slot, // 目标行环槽。
    input logic [127:0] code_lanes, // 十六条 INT8 车道。
    input logic [COL_W-1:0] emit_lo,emit_hi,write_center_lo,write_center_hi, // 保存范围与 C 中心范围。
    output logic checkpoint_valid, // Down 的整帧 X0 写出。
    input logic checkpoint_ready, // DDR 写队列接收。
    output logic [ROW_W-1:0] checkpoint_row, // checkpoint 真实行。
    output logic [COL_W-1:0] checkpoint_x, // checkpoint 真实列。
    output logic [255:0] checkpoint_data, // C32 整字。
    output logic checkpoint_begin,checkpoint_last, // checkpoint 行首与行末。
    input logic dma_valid, // DDR 读回 X0 待写入。
    output logic dma_ready, // 所需目标全部可收。
    input logic dma_to_c, // 一为将中心字同时装C残差，halo只写D；零为全部只写D。
    input logic [ROW_W-1:0] dma_row, // X0 真实行。
    input logic [COL_W-1:0] dma_x, // C 使用的真实列。
    input logic [7:0] dma_word, // D 使用的局部字号。
    input logic [255:0] dma_data, // 两片共用的 DMA 数据。
    input logic dma_begin,dma_last, // X0 行首与行末。
    input logic [COL_W-1:0] dma_center_lo,dma_center_hi, // DMA 的 C 中心范围。
    input logic [2:0] layer_count, // 装载任务有效槽数。
    input logic weight_stream_ready, // 接收方回压。
    output wire [2:0] weight_stream_slot, // 主表返回槽。
    output wire [5:0] weight_stream_pair, // 主表返回组。
    output wire weight_stream_param, // 参数标记。
    input logic layer_load_start, // 本层权重装载请求。
    output logic layer_load_ready, // 本层权重装载可开始。
    input logic [11:0] layer_weight_base,layer_param_base, // 四十位项的两段基址。
    output logic layer_load_done,weight_stream_valid, // 权重装载完成与流有效。
    output logic [39:0] weight_stream_data, // 每拍两个二十位字。
    input logic reload_valid, // 主机整表重载。
    output logic reload_ready, // 主表可接收重载。
    input logic [11:0] reload_addr, // 四十位项地址。
    input logic [39:0] reload_data, // 四十位项数据。
    output logic reload_active, // 整表重载状态。
    output logic protocol_error // 子模块与路由错误合并。
); // 接口结束。
    wire front=layer_id<=5'd3; // 前端四层的 bank 相位。
    wire ring=layer_id==5'd6 || layer_id==5'd7 || layer_id==5'd10 || layer_id==5'd11; // H 写与 V 读使用同一个 Body 环。
    logic [1:0] map_ab_valid;logic map_ab_last; // AB 映射控制。
    logic [ROW_W-1:0] map_d_row;wire [ROW_W-1:0] map_ab_row=map_d_row,map_c_row=map_d_row; // 映射后的读行。
    logic [COL_W-1:0] map_d_x,map_d_width;logic [COL_W-1:0] map_ab_x;wire [COL_W-1:0] map_c_x=map_d_x; // 映射后的读列。
    logic map_c_valid,map_c_replay,map_d_valid; // 映射客户有效。
    logic [1:0] map_c_kind,map_c_body;logic [2:0] map_d_kind; // 固定客户类型。
    logic [2:0][ROW_W-1:0] map_d_tap_row;logic [2:0][1:0] map_d_tap_slot; // 逐层反射的三行。
    logic [1:0] in_ab_valid;logic in_ab_last; // 原始 AB 映射。
    logic [ROW_W-1:0] in_ab_row,in_c_row,in_d_row; // 原始映射行。
    logic [COL_W-1:0] in_ab_x,in_c_x,in_d_x,in_d_width; // 原始映射列。
    logic in_c_valid,in_c_replay,in_d_valid,in_error; // 原始映射客户。
    logic [1:0] in_c_kind,in_c_body,in_replay_body;logic [2:0] in_d_kind; // 原始客户类型。
    logic [2:0][ROW_W-1:0] in_d_tap_row;logic [2:0][1:0] in_d_tap_slot; // 原始反射行槽。
    logic request_pending,dispatch_ready; // 请求槽切开反射计算到 RAM 的路径。
    wire [1:0] held_slot=map_d_tap_slot[1]; // AB 行槽和前端标签。
    wire [COL_W-1:0] held_center_lo=read_center_lo,held_center_hi=read_center_hi,held_replay_lo=replay_x_lo,held_replay_hi=replay_x_hi; // 保存 C 请求范围。
    logic [1:0] ab_ready,ab_wr_ready,ab_fw_ready,ab_done,ab_error; // 两片 AB 握手。
    logic [1:0][1:0] ab_valid;logic [1:0][1:0][1:0] ab_group; // 两片各自的装填元数据。
    logic [1:0][2:0] ab_front_slots; // 两片的逐层reflect物理组标签。
    logic [1:0][1:0][255:0] ab_word; // 两片各两路原始返回。
    logic c_rd_ready,c_replay_ready,c_wr_ready,c_fw_ready,c_error; // C 握手。
    logic d_rd_ready,d_wr_ready,d_word_ready,d_dma_ready,d_error; // D 握手。
    logic d_skip_ready; // D独立RES读时隙。
    logic [1:0] d_fill_valid;logic [1:0][1:0] d_fill_group; // D 窗口元数据。
    logic d_fill_done; // D 窗口数据。
    logic rf_code_ready,rf_valid,rf_front,rf_word_kind,rf_preserve,rf_begin,rf_last,rf_error,sink_ready; // 结果整理器写控制。
    logic [2:0] rf_bank;logic [1:0] rf_d_kind,rf_body,rf_slot; // 写目标。
    logic [ROW_W-1:0] rf_row;logic [COL_W-1:0] rf_x,rf_center_lo,rf_center_hi; // 写行列与 C 范围。
    logic [255:0] rf_data; // 唯一计算写数据总线。
    wire run=!reset && !strip_start; // 边界沿不接收事务。
    wire c_peer_ready=(!map_ab_valid[0] || ab_ready[0]) && (!map_ab_valid[1] || ab_ready[1]); // C 的请求只检查 AB 同伴 ready，不绕回 C 自己的 ready；全局握手仍原子完成。
    wire req_fire=request_pending && dispatch_ready && run; // 所有读客户原子接受。
    wire c_hold=c_rsp_valid && !c_rsp_ready; // C 保持读地址时暂停所有 C 写，不新增宽缓存。
    wire c_compute=rf_valid && rf_bank==3'd2; // C 计算结果的**当拍**写：与镜像写同拍互斥，也是 C 写描述符与数据的选择位。
    logic c_row_compute;
`ifdef SIM_ASSERT // 镜像行标记只服务协议断言，不生成硬件。
    logic c_row_dma; // 不参与真实仲裁。
`endif // 影子行标记声明结束。 // c_row_compute=计算 C 写行归属（首字到末字）；c_row_dma=镜像行是否已开始（只给仿真断言用，综合时剪掉）。
    wire d_word_mode=layer_id==5'd12 || layer_id==5'd15; // Reduce 和 Head 走 D 放大整字口。
    wire c_skip_stage=layer_id==5'd2 || layer_id==5'd5 || layer_id==5'd7 || layer_id==5'd9 || layer_id==5'd11; // 只有C保存的六类块输入中的五类由本口读取。
    wire c_read_reserved=request_pending && (map_c_valid || map_c_replay) || skip_req_valid && c_skip_stage; // C读客户先占时隙，不把地址检查串到DMA提交。
    // 镜像 DMA 的 C 写时隙。三条不变量与 ngm_bank_ctrl_c 的镜像写段落配套，改动前务必一起读：
    //   1) 保留 !c_row_compute：镜像行的**开始**必须等计算 C 写行结束。原因：镜像首字会把 body0 的行
    //      有效标签置无效，若此刻 Body0.V 还在读 body0 残差，那些读会被 rd_tag_ok 拒掉，该行永远完不成。
    //   2) 新增 !c_compute：镜像写与计算写在**同拍互斥**。同一拍只允许一个写描述符进写口，
    //      否则 wr_body/wr_row/wr_x 与写数据总线的选择会打架（旧实现靠整行独占隐式保证，现在必须显式）。
    //   3) 去掉旧的 (c_row_dma || !c_write_slot) 与 c_input_hold：镜像行不再整行独占写口，计算结果也
    //      不再被暂停——这是解开 720p 死锁与"结果无回压契约"违约的关键，不要再改回整行独占。
    wire c_dma_slot=!front && !c_row_compute && !c_compute && !c_hold && !replay_busy && !c_read_reserved && !io_wr_valid; // 计算写优先；镜像只在计算不写、无重放/读预约、无IO占写沿时落字。
    wire c_dma_center=dma_x>=dma_center_lo && dma_x<dma_center_hi; // 只判断已有真实列，不新增数据暂存。
    wire c_dma_first=dma_x==dma_center_lo,c_dma_last=dma_x==dma_center_hi-1'b1; // C首末字独立于D的halo范围。
    wire c_dma_offer=dma_valid && dma_to_c && c_dma_center && c_dma_slot && d_dma_ready && run; // 中心字两片同时提交，halo不发C写入。
    wire c_dma_ok=!dma_to_c || c_dma_slot; // 非镜像输入不经过C；镜像只检查窄占用控制。
    wire d_dma_offer=dma_valid && c_dma_ok && run; // C 可收时才允许 D 提交。
    logic local_error,front_half_q,front_outer_a_q; // 只新增两位必要的前端返回标签。
    logic [127:0] front_top,front_mid,front_bottom; // 前端跨片三个 C16 抽头。
    wire body_bank=layer_id>=5'd8; // Body0/1 用 A，Body2/3 用 B。
    wire [1:0] skip_body=layer_id==5'd5 ? 2'd0 : layer_id==5'd7 ? 2'd1 : layer_id==5'd9 ? 2'd2 : 2'd3; // 固定层译码，禁止宽减法。
    assign skip_req_ready=run && (c_skip_stage ? c_rd_ready : layer_id==5'd14 && d_skip_ready); // C/D客户分层复用同一窄接口。
    ngm_weight_ram u_weight_ram( // 权重与参数主表只有一份。
        .clk(clk),.reset(reset),.layer_load_start(layer_load_start),.layer_load_ready(layer_load_ready), // 装载握手。
        .layer_weight_base(layer_weight_base),.layer_param_base(layer_param_base),.layer_load_done(layer_load_done), // 两段基址。
        .layer_count(layer_count),.stream_ready(weight_stream_ready),.stream_slot(weight_stream_slot),.stream_pair(weight_stream_pair),.stream_param(weight_stream_param), // 新流协议。
        .stream_valid(weight_stream_valid),.stream_data(weight_stream_data), // 四十位流直通常驻槽。
        .reload_valid(reload_valid),.reload_ready(reload_ready),.reload_addr(reload_addr),.reload_data(reload_data),.reload_active(reload_active)); // 主机重载。
    ngm_addr_map #(.ROW_W(ROW_W),.COL_W(COL_W)) u_addr_map( // 模型读客户只在此译码。
        .req_valid(req_valid),.layer_id(layer_id),.req_row(req_row),.req_x(req_x),.req_slot(req_slot), // 逻辑坐标。
        .src_height(src_height),.src_width(src_width),.req_subread(req_subread), // 源形状与子读。
        .ab_valid(in_ab_valid),.ab_front(),.ab_ring(),.ab_row(in_ab_row),.ab_x(in_ab_x),.ab_last_row(in_ab_last), // AB 请求。
        .c_valid(in_c_valid),.c_kind(in_c_kind),.c_body(in_c_body),.c_row(in_c_row),.c_x(in_c_x), // C 单字请求。
        .c_replay(in_c_replay),.c_replay_body(in_replay_body), // C 自动整行重放。
        .d_valid(in_d_valid),.d_kind(in_d_kind),.d_row(in_d_row),.d_x(in_d_x),.d_width(in_d_width), // D 请求。
        .d_tap_row(in_d_tap_row),.d_tap_slot(in_d_tap_slot),.map_error(in_error)); // 竖向反射。
    ngm_result_former #(.ROW_W(ROW_W),.COL_W(COL_W)) u_result_former( // 所有结果共用已有配对暂存。
        .prefix_write(prefix_write),.prefix_data(prefix_data),.prefix_value(prefix_value), // RGB阶段复用128位寄存器，不增加前缀缓存。
        .clk(clk),.reset(reset),.layer_id(layer_id),.code_in_range(code_in_range),.code_valid(code_valid && run),.code_ready(rf_code_ready), // 无回压码流：不再被镜像行暂停（旧 c_input_hold 已删除）
        .code_row(code_row),.code_x(code_x),.code_batch(code_batch),.code_slot(code_slot),.code_lanes(code_lanes), // 原始结果。
        .emit_lo(emit_lo),.emit_hi(emit_hi),.center_lo(write_center_lo),.center_hi(write_center_hi),.sink_ready(sink_ready), // 保存范围。
        .wr_valid(rf_valid),.wr_bank(rf_bank),.wr_full(),.wr_front(rf_front),.wr_d_half_kind(rf_d_kind),.wr_d_word_kind(rf_word_kind), // 目标译码。
        .wr_c_body(rf_body),.wr_c_preserve(rf_preserve),.wr_row(rf_row),.wr_x(rf_x),.wr_slot(rf_slot),.wr_data(rf_data), // 共用数据。
        .wr_begin(rf_begin),.wr_last(rf_last),.wr_center_lo(rf_center_lo),.wr_center_hi(rf_center_hi),.protocol_error(rf_error)); // 行提交。
    for(genvar b=0;b<2;b++) begin:g_ab // A 与 B 编译期分开，不增加动态 bank 译码。
        ngm_bank_ctrl_ab #(.BANK_SEL(b),.ROW_W(ROW_W),.COL_W(COL_W)) u_bank_ctrl( // 每片自含唯一 RAM。
            .clk(clk),.reset(reset),.cfg_front(front),.cfg_ring(ring),.wr_slot_in(rf_slot),.req_slot_in(held_slot), // 行环直接传入。
            .wr_valid(rf_valid && rf_bank==b && !rf_front && run && !code_abort),.wr_col(code_ab_col),.wr_data({code_lanes,prefix_value}),.wr_ready(ab_wr_ready[b]), // Body C32 写。
            .fw_valid(rf_valid && rf_bank==b && rf_front && run && !code_abort),.fw_row(rf_row),.fw_col(rf_x),.fw_data({128'b0,code_lanes}),.fw_ready(ab_fw_ready[b]), // 前端整字写。
            .req_valid(map_ab_valid[b] && req_fire),.req_row(map_ab_row),.req_col(front ? map_c_x : map_ab_x),.req_last_row(map_ab_last),.req_ready(ab_ready[b]), // 原子接受。
            .front_slots(ab_front_slots[b]),.fill_valid(ab_valid[b]),.fill_group(ab_group[b]),.fill_word(ab_word[b]),.fill_done(ab_done[b]),.protocol_error(ab_error[b])); // 原始窗口返回。
    end // AB 两片结束。
    wire [255:0] c_write_bus=c_compute ? rf_data : dma_data; // 原有计算和镜像DMA数据选择。
    logic c_io_wr_ready,c_io_rd_ready; // C原生IO握手。
    wire [255:0] c_queue_write_bus={c_write_bus[255:43],layer_id==5'd16 ? io_rgb_word : c_write_bus[42:0]}; // 低43位只按静态格式选择，不把瞬时valid串入宽数据路径。
`ifdef SIM_ASSERT
    wire [255:0] c_queue_write_bus_legacy={c_write_bus[255:43],io_wr_valid && layer_id==5'd16 ? io_rgb_word : c_write_bus[42:0]}; // 合法真实写的旧选择影子。
    integer rgb_shadow_bits_compared=0,feature_shadow_bits_compared=0;
    logic [16:0] rgb_test_layer_mask=0;
    always @(posedge clk) if(!reset && io_wr_valid && c_io_wr_ready && run) begin
        if(layer_id==5'd16) begin
            if(c_queue_write_bus[42:0] !== c_queue_write_bus_legacy[42:0]) $fatal(1,"MEM RGB queue write differs from legacy defined bits");
            rgb_shadow_bits_compared=rgb_shadow_bits_compared+43;
        end else begin
            if(c_queue_write_bus !== c_queue_write_bus_legacy) $fatal(1,"MEM feature queue write differs from legacy word");
            feature_shadow_bits_compared=feature_shadow_bits_compared+256;
        end
    end
    always @(posedge clk) if(reset) rgb_test_layer_mask<=0; else if(run) rgb_test_layer_mask[layer_id]<=1'b1;
    always @(posedge clk) if(!reset && layer_id==5'd16) begin
        if((((c_compute && !rf_front && !c_hold && run && !code_abort) || c_dma_offer) && c_wr_ready) ||
           (c_compute && rf_front && !c_hold && run && !code_abort && c_fw_ready))
            $fatal(1,"MEM layer16 non-IO C write accepted");
    end
    final $display("MEM RGB_STATIC_COMPARE rgb_defined_bits=%0d feature_bits=%0d layer_mask=%05h",rgb_shadow_bits_compared,feature_shadow_bits_compared,rgb_test_layer_mask);
`endif
    assign io_wr_ready=c_io_wr_ready && run;assign io_rd_ready=c_io_rd_ready && run; // 静止边界不报告IO接受。
    ngm_bank_ctrl_c #(.ROW_W(ROW_W),.COL_W(COL_W)) u_bank_ctrl_c(
        .io_rgb_mode(layer_id==5'd16), // residual、重放和输出队列共用原有端口。
        .io_wr_valid(io_wr_valid && run),.io_wr_ready(c_io_wr_ready),.io_wr_addr(io_wr_addr), // 输出队列写复用既有数据总线。
        .io_rd_valid(io_rd_valid && run),.io_rd_ready(c_io_rd_ready),.io_rd_addr(io_rd_addr),.io_rsp_valid(io_rsp_valid),.io_rsp_ready(io_rsp_ready),.io_rsp_word(io_rsp_word), // 原生IO返回。
        .clk(clk),.reset(reset),.cfg_front(front),.strip_start(strip_start), // strip 静止边界。
        .wr_valid((c_compute && !rf_front && !c_hold && run && !code_abort) || c_dma_offer),.wr_ready(c_wr_ready), // 计算写优先；镜像只在 c_dma_slot 允许的拍落字（同拍互斥由 c_dma_slot 的 !c_compute 保证）。
        // 仲裁和宽数据按当拍 c_compute 选择，镜像行不独占写口。
        // 窄描述符使用已有计算行归属，实际写入时与当拍选择一致（下方断言）。
        // Only narrow Body descriptors use the existing row ownership FF.
        // A compute Body row owns C before its first complete word; DMA is
        // prohibited while that ownership is set. Front writes use fw_*.
        // Actual write arbitration and the 256-bit data mux remain c_compute.
        .wr_body(c_row_compute ? rf_body : 2'd0),.wr_row(c_row_compute ? rf_row : dma_row),.wr_x(c_row_compute ? rf_x : dma_x),
        .wr_center_lo(c_row_compute ? rf_center_lo : dma_center_lo),.wr_center_hi(c_row_compute ? rf_center_hi : dma_center_hi),
        .wr_data(c_queue_write_bus),.wr_begin(c_row_compute ? rf_begin : c_dma_first),
        .wr_complete(c_row_compute ? rf_last : c_dma_last),.wr_preserve(c_row_compute && rf_preserve),
        .fw_valid(c_compute && rf_front && !c_hold && run && !code_abort),.fw_ready(c_fw_ready),.fw_row(rf_row),.fw_col(rf_x),.fw_data(rf_data),.fw_begin(rf_begin),.fw_complete(rf_last), // 前端整字。
        .rd_valid((c_skip_stage ? skip_req_valid : (map_c_valid && request_pending && c_peer_ready)) && run),.rd_ready(c_rd_ready), // V残差独立请求，其他客户沿用请求槽。
        .rd_kind(c_skip_stage ? (front ? 2'd2 : 2'd0) : map_c_kind),.rd_body(c_skip_stage ? skip_body : map_c_body), // C原有客户译码。
        .rd_row(c_skip_stage ? skip_req_row : map_c_row),.rd_x(c_skip_stage ? skip_req_x : map_c_x), // 结果对齐读地址不跟随未来窗口坐标。
        .rd_center_lo(c_skip_stage ? read_center_lo : held_center_lo),.rd_center_hi(c_skip_stage ? read_center_hi : held_center_hi), // 同一V行的范围保持不变。
        .rsp_valid(c_rsp_valid),.rsp_ready(c_rsp_ready),.rsp_kind(c_rsp_kind),.rsp_row(c_rsp_row),.rsp_x(c_rsp_x),.rsp_word(c_rsp_word), // 返回不另存数据。
        .replay_start(map_c_replay && request_pending && run),.replay_start_ready(c_replay_ready),.replay_body(map_c_body),.replay_row(map_c_row), // 行首一次命令。
        .replay_center_lo(held_center_lo),.replay_center_hi(held_center_hi),.replay_x_lo(held_replay_lo),.replay_x_hi(held_replay_hi), // 中心与边缘范围。
        .replay_busy(replay_busy),.replay_done(replay_done),.protocol_error(c_error)); // 自动重放状态。
    ngm_bank_ctrl_d #(.ROW_W(ROW_W),.COL_W(COL_W)) u_bank_ctrl_d( // D 使用刚验证的正式实现。
        .tail_base(tail_base), // 真实尾部列转换所需的strip基址。
        .clk(clk),.reset(reset),.cfg_front(front), // 前端与 Tail 相位。
        .wr_valid(rf_valid && rf_bank==3'd3 && !d_word_mode && run && !code_abort),.wr_ready(d_wr_ready),.wr_kind(rf_d_kind), // 已配对 C16 写。
        .wr_row(rf_row),.wr_x(rf_x),.wr_slot(rf_slot),.wr_data(rf_data),.wr_last(rf_last),.wr_begin(rf_begin), // 首字直接废弃旧标签，末字提交。
        .word_valid(rf_valid && rf_bank==3'd3 && d_word_mode && run && !code_abort),.word_ready(d_word_ready),.word_kind(rf_word_kind), // 最近邻整字写。
        .word_row(rf_row),.word_x(rf_x),.word_slot(rf_slot),.word_data(rf_data),.word_last(rf_last), // 放大后目标。
        .dma_valid(d_dma_offer),.dma_ready(d_dma_ready),.dma_row(dma_row),.dma_x(dma_x),.dma_word(dma_word),.dma_data(dma_data),.dma_last(dma_last), // X0 预取。
        .req_valid(map_d_valid && request_pending && run),.req_ready(d_rd_ready),.req_kind(map_d_kind),.req_row(map_d_row),.req_x(map_d_x), // D 独占此请求，直接交其自身 ready 判定，避免全局 ready 再绕回。
        .req_width(layer_id==16 ? bank_rgb_width : map_d_width),.req_tap_slot(map_d_tap_slot),.req_tap_row(map_d_tap_row), // D内部RGB局部保存宽度与真实行反射。
        .skip_req_valid(skip_req_valid && layer_id==5'd14 && run),.skip_req_ready(d_skip_ready),.skip_req_row(skip_req_row),.skip_req_x(skip_req_x), // D结果附近RES读优先于未来H窗口。
        .rsp_valid(d_rsp_valid),.rsp_ready(d_rsp_ready),.rsp_kind(d_rsp_kind),.rsp_row(d_rsp_row),.rsp_x(d_rsp_x), // 单字原有返回。
        .rsp_word(d_rsp_word),.rsp_front_word(d_rsp_front_word),.rsp_input_word(d_rsp_input_word),.rsp_half(d_rsp_half), // 已有回压保持机制。
        .rsp_rgb_word(d_rsp_rgb_word),.rsp_v_tags(d_rsp_v_tags),.fill_valid(d_fill_valid),.fill_group(d_fill_group),.fill_done(d_fill_done),.fill_row(),.fill_x(), // 已有窗口布局。
        .v_skip_valid(d_skip_valid),.v_skip(d_skip),.protocol_error(d_error)); // Decoder残差返回。
    always_comb begin // 原子读握手和唯一计算写目标。
        dispatch_ready=run; // Stem 外部输入不接 RAM 请求。
        if(map_ab_valid[0]) dispatch_ready=dispatch_ready && ab_ready[0]; // A 参与时检查。
        if(map_ab_valid[1]) dispatch_ready=dispatch_ready && ab_ready[1]; // B 参与时检查。
        if(map_c_valid) dispatch_ready=dispatch_ready && c_rd_ready; // residual 与窗口一起收。
        if(map_c_replay) dispatch_ready=dispatch_ready && c_replay_ready; // 重放只收一次行命令。
        if(map_d_valid) dispatch_ready=dispatch_ready && d_rd_ready; // D 固定流水能力。
        req_ready=run && !in_error && (!request_pending || dispatch_ready); // Stem原字读取及其他层均可同拍消费旧请求并接收新请求。
        case(rf_bank) // 不重复模型译码，直接使用整理器的目标。
            3'd0:sink_ready=rf_front ? ab_fw_ready[0] : ab_wr_ready[0]; // A 写口。
            3'd1:sink_ready=rf_front ? ab_fw_ready[1] : ab_wr_ready[1]; // B 写口。
            3'd2:sink_ready=!c_hold && (rf_front ? c_fw_ready : c_wr_ready); // C 写口：镜像行不再暂停计算结果（旧 c_input_hold 已删除）
            3'd3:sink_ready=d_word_mode ? d_word_ready : d_wr_ready; // D 写口。
            default:sink_ready=checkpoint_ready; // Down整帧检查点写口。
        endcase // 目标握手结束。
        sink_ready=sink_ready && run; // 边界不消费写结果。
    end // 原子握手结束。
    always_ff @(posedge clk) begin // 只寄存请求描述符，不保存任何激活数据。
        if(reset || strip_start) request_pending<=0; // 边界清空有效位，描述符无需复位。
        else if(!request_pending || req_fire) begin // 消费后可以无气泡接替。
            request_pending<=req_valid && req_ready; // 保存真实握手结果。
            if(req_valid && req_ready) begin // 所有请求字段必须在接受沿保存。
                map_ab_valid<=in_ab_valid;map_ab_last<=in_ab_last;map_ab_x<=req_ab_col; // AB 请求。
                map_c_valid<=in_c_valid;map_c_replay<=in_c_replay;map_c_kind<=in_c_kind;map_c_body<=in_c_replay ? in_replay_body : in_c_body; // C 单字客户。
                // C 单字和重放互斥，区域编号共用同一寄存器。
                map_d_valid<=in_d_valid;map_d_kind<=in_d_kind;map_d_row<=in_d_valid ? in_d_row : in_c_row;map_d_x<=in_d_valid ? in_d_x : in_c_x;map_d_width<=in_d_width; // D 客户。
                map_d_tap_row<=in_d_tap_row;map_d_tap_slot<=in_d_tap_slot; // 反射计算在请求槽之前完成。
                // AB 与 C 共用真实行号；C/D 互斥而共用真实列号，AB 独立保存局部列。
            end // 描述符更新结束。
        end // 请求槽更新结束。
    end // 请求流水结束。
    always_ff @(posedge clk) begin // C 写上下文不能在一行中途更换来源。
        if(reset || strip_start) begin c_row_compute<=0;end // 静止边界清归属。
        else begin // 计算从首半字开始占行，DMA 从实际写开始占行。
            if(code_valid && code_ready && rf_bank==3'd2 && !front && code_x==emit_lo && !code_batch) c_row_compute<=1; // 只在保存范围的首低批占行，裁掉的 halo 不产生归属。
            if(c_compute && rf_last && sink_ready) c_row_compute<=0; // 完整结果行提交才释放。
        end // 写行归属更新结束。
    end // 仅两位状态，不新增激活暂存。
    assign code_ready=rf_code_ready && run; // 边界和复位不能报告接受计算结果；镜像行不再暂停计算结果（无回压契约见 row_sequencer 的 result_fault）。
    assign dma_ready=d_dma_ready && c_dma_ok && run; // 全部目标同时可收。
    assign checkpoint_valid=rf_valid && rf_bank==3'd4 && run && !code_abort; // 唯一 DDR 写出口。
    assign checkpoint_row=rf_row;assign checkpoint_x=rf_x;assign checkpoint_data=rf_data; // 元数据和宽数据直通。
    assign checkpoint_begin=rf_begin;assign checkpoint_last=rf_last; // 行提交标记直通。
    always_ff @(posedge clk) begin // 前端流水仅保存选半和抽头归属标签。
        if(reset) begin front_half_q<=0;front_outer_a_q<=0;local_error<=0;end // 只有三位小寄存器。
        else begin // 正常运行。
            if(req_fire && layer_id==5'd2) begin front_half_q<=map_d_x[0];front_outer_a_q<=map_d_row[0];end // 返回不得看下一请求坐标。
            if(req_valid && in_error) local_error<=1; // 暴露非法来源，Stem输入段现有正式存储归属。
        if(strip_start && (code_valid || dma_valid || req_valid || skip_req_valid)) local_error<=1; // 静止边界不得吞数据。
        end // 控制更新结束。
    end // 返回标签时序结束。
    always_comb begin // 前端只选所请求的半字并做固定跨片拼接。
        front_top=ab_word[front_outer_a_q ? 0 : 1][0][127:0]; // 原生128位像素不再选择半字。
        front_mid=ab_word[front_outer_a_q ? 0 : 1][1][127:0]; // 原生128位像素不再选择半字。
        front_bottom=ab_word[front_outer_a_q ? 1 : 0][ab_front_slots[0][1]][127:0]; // 原生128位像素不再选择半字。
        fill_valid=d_fill_valid;fill_group=d_fill_group;fill_word='0;fill_done=d_fill_done; // D 直接使用原有布局。
        if(front) begin // 三份 C16 固定合成两个整字，不保存宽数据。
            fill_valid={2{ab_done[0] && ab_done[1]}};fill_group={2'd1,2'd0}; // 三抽头共十二格。
            fill_word[0]={front_mid,front_top};fill_word[1]={125'b0,ab_front_slots[0],front_bottom}; // top、mid、bottom 顺序。
            fill_done=ab_done[0] && ab_done[1]; // 两片同拍返回即完成。
        end else if(layer_id==5'd5 || layer_id==5'd7 || layer_id==5'd9 || layer_id==5'd11) begin // Body-V 只转发所需一片。
            fill_valid={1'b0,ab_valid[body_bank][0]};fill_group[0]=ab_group[body_bank][0];fill_word[0]=ab_word[body_bank][0]; // Body 每拍只发一个整字。
            fill_group[1]=0;fill_word[1]=0;fill_done=ab_done[body_bank]; // 第二口没有 Body 客户，直接置零，不为无效数据做宽选择。
        end // 其他单字客户由 C/D 返回装填横向窗口。
    end // 窗口路由结束。
    assign protocol_error=local_error || rf_error || (|ab_error) || c_error || d_error; // 合并已有错误位。
`ifdef SIM_ASSERT // 默认测试开启，不为非法输入增加宽硬件检查。
    logic [43:0] range_shadow_q; // 接受时仅在仿真保存范围。
    always_ff @(posedge clk)begin // 影子状态不参与任何硬件事务。
        if(reset || strip_start)c_row_dma<=0; // 边界清镜像影子。
        else if(dma_valid && dma_ready && dma_to_c)c_row_dma<=!dma_last; // 跟踪真实接受。
        if(req_valid && req_ready)range_shadow_q<={read_center_lo,read_center_hi,replay_x_lo,replay_x_hi}; // 对比原请求槽契约。
        if(!reset && request_pending && range_shadow_q!=={read_center_lo,read_center_hi,replay_x_lo,replay_x_hi})$fatal(1,"MEM changed row range while pending"); // 上游不得改行配置。
    end // 范围保持断言结束。
    always @(posedge clk) if(!reset) begin // 原子接受与静止边界检查。
        if(req_fire && layer_id==5'd2 && map_ab_valid!=2'b11) $fatal(1,"MEM incomplete frontend route"); // V 必须两片同读。
        if(dma_valid && dma_ready && dma_to_c && !(d_dma_offer && (!c_dma_center || c_dma_offer))) $fatal(1,"MEM split DMA commit"); // 中心字必须原子写两片，halo只写D。
        if(skip_req_valid && !(c_skip_stage || layer_id==5'd14))$fatal(1,"MEM skip outside residual stage"); // 外部只能在对应V行使用独立残差读。
        if(c_compute && !front && !c_row_compute)$fatal(1,"MEM C result without row ownership"); // 主体首低批必须先于整字结果取得行归属。
        if(run && ((c_compute && !rf_front && !c_hold && !code_abort) || c_dma_offer) && c_row_compute!==c_compute)
            $fatal(1,"MEM C owned descriptor selection differs on a Body write"); // Every real Body write selects exactly the old descriptor.
        if(strip_start && (code_valid || dma_valid || req_valid || skip_req_valid || request_pending || c_row_compute || c_row_dma || replay_busy || c_rsp_valid || d_rsp_valid || (|fill_valid) || io_wr_valid || io_rd_valid || io_rsp_valid)) $fatal(1,"MEM active strip boundary"); // 所有IO也必须排空。
    end // 仿真检查结束。
`endif // 仅仿真逻辑结束。
endmodule // 存储子系统结束。












