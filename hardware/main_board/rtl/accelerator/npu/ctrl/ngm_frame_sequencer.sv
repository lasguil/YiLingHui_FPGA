// 协议契约：帧内X0宽高仅保存9位、前端真实行计数10位；输入合法范围仍由原帧命令检查。
// 协议契约：软核先加载固定17层模型权重，再以一次frame握手启动完整一帧；不要求软件逐行干预。
// width4/height4为四分之一尺寸，范围2..480/2..270；真实图像宽高为其四倍，配置在握手沿锁存。
// 输入、输出、X0地址和字节行跨度原样交给DMA适配器；像素格式与AXI突发在host层定义，本模块不做宽地址乘法。
// 前端按Stem(n)、H(n)、V(n-1)推进，V每完成奇行立即Down；末行V单独drain，再等待整帧X0写响应。
// 前端RGB DMA一次提供两条真实输入行，允许与Stem计算流式重叠；input_done表示两行数据已消费且读事务结束。
// checkpoint_committed表示本帧全部X0写入已收到成功响应；output_committed表示本帧全部RGB输出成功写回。
// 上述完成条件只能在对应帧内置位，直到clear_work再清零；不能拿FIFO空或最后W拍代替AXI写响应。
// row_done表示真实计算、配对写入及供窗排空；所有行请求最多一条在途，ready可等待权重和数据。
// model握手优先于同拍frame及行/DMA请求；立即禁止新工作并置abort_req，当前帧允许成为无效半帧。
// abort_req期间适配器停止新请求、丢弃旧计算结果，但必须完成已接受的AXI握手及响应，禁止复位在途AXI事务。
// abort_quiescent表示引擎、供窗、写队列及已发总线事务全部安全静止；随后clear_work清工作控制和缓存标签。
// clear_work不得清权重主表或AXI在途协议状态；本模块同时清内含strip状态，外部行/窗口/缓存控制同步清理。
// 换权重只收一条在途命令，重载时model_ready为零；主表及量化参数全部提交后model_done，失败不得置model_loaded。
// 新包沿用descriptor_package的固定结构及布局；切换不同网络拓扑不属于换权重指令。
// frame_done只在全部计算、输出写响应及boundary_ready都完成后单拍通知；中止不产生frame_done且不自动重跑。
// 软件中断的保持与清除由寄存器模块负责，本模块提供frame_done/frame_aborted/model_done/task_error单拍事件。
// 前端/主体切换先等待boundary_ready再留clear_work完整一拍，满足各bank切相位静置要求。
// prefetch为下一实际层提示，加载器仍须等当前行真正提交PE读bank；它不是另一次行启动。
module ngm_frame_sequencer #( // 固定模型整帧与权重命令控制。
    parameter int unsigned ROW_W=11,COL_W=11,COUNT_W=10,ADDR_W=32,STRIDE_W=24 // 地址位宽可随最终AXI配置调整。
)( // 接口开始。
    input logic clk,reset, // 同步控制时钟与复位。
    input logic frame_valid, // 软核一帧命令。
    output logic frame_ready, // 可以锁存新帧配置。
    input logic [COL_W-1:0] frame_width4, // 原始图像宽度除四。
    input logic [ROW_W-1:0] frame_height4, // 原始图像高度除四。
    input logic [ADDR_W-1:0] frame_input_base,frame_output_base,frame_x0_base, // 三块DDR区域基址。
    input logic [STRIDE_W-1:0] frame_input_stride,frame_output_stride,frame_x0_stride, // 字节行跨度。
    input logic model_valid, // 可抢占当前帧的换权重命令。
    output logic model_ready, // 无待处理换权重命令。
    input logic [ADDR_W-1:0] model_base, // 新权重包DDR首地址。
    output logic model_loaded,busy,frame_done,frame_aborted,model_done,task_error, // 权重可用、占用与终结事件。
    output logic [2:0] error_code, // 最近失败的外部错误原因，成功新命令清零。
    output logic [ADDR_W-1:0] input_base,output_base,x0_base,load_base, // 锁存配置，不随软核改寄存器变化。
    output logic [STRIDE_W-1:0] input_stride,output_stride,x0_stride, // 锁存DMA行跨度。
    output logic [COL_W-1:0] width4, // 当前帧四分之一宽。
    output logic [ROW_W-1:0] height4, // 当前帧四分之一高。
    output logic load_valid, // 整个主表与参数包重载请求。
    input logic load_ready,load_done,load_error, // 请求接受、成功提交或失败；done/error不可同拍。
    output logic abort_req,clear_work, // 丢帧停止新工作与安全工作状态清除。
    input logic abort_quiescent,boundary_ready, // 抢占排空和正常阶段静止。
    input logic [2:0] work_error, // 当前帧DMA/引擎/协议错误，非零触发安全终止。
    input logic checkpoint_committed,output_committed, // 两个整帧写响应完成条件。
    output logic cfg_front,strip_start, // 存储相位及主体新strip标签清除。
    output logic input_valid, // Stem所需两条RGB输入行的流式DMA命令。
    input logic input_ready,input_done, // 命令接受与数据消费/读响应结束。
    output logic [ROW_W-1:0] input_row, // 第一条真实RGB行，第二条为加一。
    output logic [COL_W-1:0] input_width, // 两行各自真实像素宽度。
    output logic dma_valid, // 主体X0行预取命令，末字同时提交C/D。
    input logic dma_ready,dma_done, // X0命令接受与末字提交。
    output logic [ROW_W-1:0] dma_row, // X0真实行号。
    output logic [COL_W-1:0] dma_lo,dma_hi,dma_center_lo,dma_center_hi, // X0范围与C中心。
    output logic [COL_W-1:0] strip_s,strip_e,tail_base,bank_rgb_width, // strip中心、D基址与RGB局部保存宽。
    output wire row_output_stage, // Direct FSM decode; no layer-mux cascade.
    output logic row_valid, // 前端或主体整行计算命令。
    input logic row_ready,row_done, // 行接受与实际结果排空。
    output logic [4:0] row_layer, // 当前层0..16。
    output logic [ROW_W-1:0] row_id,read_height, // 输出行与输入真实高度。
    output logic [COL_W-1:0] row_x,row_ab_col,read_width, // 真实组首列、AB局部首列和输入宽度。
    output logic [COUNT_W-1:0] row_count, // 实际空间组数。
    output logic [1:0] read_slot,write_slot, // 三行环输入与输出槽。
    output logic [COL_W-1:0] read_lo,read_hi,emit_lo,emit_hi, // 输入保存范围与有效输出范围。
    output logic [COL_W-1:0] read_center_lo,read_center_hi,write_center_lo,write_center_hi, // 主体C中心描述符。
    output logic prefetch_valid, // 当前行期间下一实际层提示。
    output logic [4:0] prefetch_layer // 提示层号。
); // 接口结束。
    typedef enum logic [3:0] {IDLE,SETUP,STEM,HCONV,VCONV,DOWN,CHECKPOINT,BODY,DRAIN,ABORT,MODEL_OFFER,MODEL_WAIT,ABORT_CLEAR} state_t; // 生命周期。
    state_t state_q; // 唯一帧级状态。
    logic waiting_q,row_finished_q,input_sent_q,input_pending_q,load_pending_q,aborted_frame_q; // 窄在途与终结标签。
    (* syn_preserve = "true" *) logic clear_work_q; // 直接驱动安全清理控制的等价状态译码。
    logic [9:0] stem_row_q,v_row_q; // 两个独立真实前端行计数。
    logic [1:0] h_slot_q,v_slot_q; // 三行环窄槽计数，禁止宽行取模。
    logic [8:0] width4_q,height4_q; // 配置域只需9位，避免复制宽范围控制。
    assign width4=COL_W'(width4_q);assign height4=ROW_W'(height4_q); // 端口保持原标签位宽。
    wire front_stage=state_q>=STEM && state_q<=DOWN; // 前端四种实际stage。
    wire active_frame=state_q>=SETUP && state_q<=DRAIN; // 包含DDR排空的当前帧。
    wire model_take=model_valid && model_ready; // 抢占权重命令接受。
    wire frame_take=frame_valid && frame_ready; // 帧命令接受。
    wire killed=model_take || (active_frame && work_error!=0) || state_q==ABORT || state_q==ABORT_CLEAR; // 当拍阻止所有新工作。
    wire front_done=front_stage && (row_finished_q || (waiting_q && row_done)); // 不要求计算和输入DMA同拍结束。
    wire [COL_W-1:0] width2=COL_W'(width4<<1); // 前端中间宽。
    wire [ROW_W-1:0] height2=ROW_W'(height4<<1); // 前端中间高。
    logic s_start_ready,s_busy,s_done,s_strip_start,s_row_valid,s_dma_valid,s_prefetch_valid; // 内含strip握手。
    logic [4:0] s_layer,s_prefetch_layer; // 主体命令层。
    logic [ROW_W-1:0] s_row,s_read_height; // 主体真实行与高度。
    logic [COL_W-1:0] s_x,s_ab_col,s_read_width,s_read_lo,s_read_hi,s_emit_lo,s_emit_hi; // 主体几何。
    logic [COL_W-1:0] s_read_center_lo,s_read_center_hi,s_write_center_lo,s_write_center_hi; // 主体C范围。
    logic [COUNT_W-1:0] s_count;logic [1:0] s_read_slot,s_write_slot; // 主体组数和槽。
    assign model_ready=state_q!=ABORT && state_q!=ABORT_CLEAR && state_q!=MODEL_OFFER && state_q!=MODEL_WAIT; // 不另建命令队列。
    assign frame_ready=state_q==IDLE && model_loaded && !model_valid; // 权重命令有同拍优先权。
    assign busy=state_q!=IDLE;assign abort_req=killed; // 占用与立即中止通知。
    assign clear_work=clear_work_q; // 直接由等价状态寄存器驱动，避免状态/抢占扇出组合链。
    wire s_output_stage;
    assign row_output_stage = state_q==DOWN ||
                              (state_q==BODY && s_output_stage);
    assign load_valid=state_q==MODEL_OFFER; // 重载地址在回压期间保持。
    assign cfg_front=state_q>=SETUP && state_q<=CHECKPOINT; // 含切相位静置和X0排空。
    assign input_valid=state_q==STEM && !input_sent_q && !killed; // 每个Stem仅一次两行读取。
    assign input_row=ROW_W'(ROW_W'(stem_row_q)<<1);assign input_width=COL_W'(width4<<2); // PixelUnshuffle的两条原始行。
    assign dma_valid=state_q==BODY && s_dma_valid && !killed; // 不透传非运行strip请求。
    assign strip_start=state_q==BODY && s_strip_start && !killed; // 只在静止边界清C标签。
    ngm_strip_sequencer #(.ROW_W(ROW_W),.COL_W(COL_W),.COUNT_W(COUNT_W)) u_strip_sequencer( // 复用已验收的主体与尾部调度。
        .clk(clk),.reset(reset || clear_work),.start(state_q==CHECKPOINT && checkpoint_committed && boundary_ready && !killed), // X0写响应全部结束才启动。
        .boundary_ready(boundary_ready && !killed),.start_ready(s_start_ready),.busy(s_busy),.done(s_done),.strip_start(s_strip_start), // 主体边界。
        .width4(width4),.height4(height4),.strip_s(strip_s),.strip_e(strip_e),.tail_base(tail_base), // 锁存帧几何。
        .dma_valid(s_dma_valid),.dma_ready(state_q==BODY && dma_ready && !killed),.dma_done(state_q==BODY && dma_done && !killed), // 停止透传旧DMA完成。
        .dma_row(dma_row),.dma_lo(dma_lo),.dma_hi(dma_hi),.dma_center_lo(dma_center_lo),.dma_center_hi(dma_center_hi), // X0读取范围。
        .row_output_stage(s_output_stage),.row_valid(s_row_valid),.row_ready(state_q==BODY && row_ready && !killed),.row_done(state_q==BODY && row_done && !killed), // 同一物理行引擎。
        .row_layer(s_layer),.prefetch_valid(s_prefetch_valid),.prefetch_layer(s_prefetch_layer), // 层和预取。
        .row_id(s_row),.read_height(s_read_height),.row_x(s_x),.row_ab_col(s_ab_col),.read_width(s_read_width), // 真实坐标。
        .row_count(s_count),.read_slot(s_read_slot),.write_slot(s_write_slot), // 打包和物理槽。
        .read_lo(s_read_lo),.read_hi(s_read_hi),.emit_lo(s_emit_lo),.emit_hi(s_emit_hi), // 保存与输出范围。
        .read_center_lo(s_read_center_lo),.read_center_hi(s_read_center_hi),.write_center_lo(s_write_center_lo),.write_center_hi(s_write_center_hi), // C槽范围。
        .bank_rgb_width(bank_rgb_width) // D局部RGB宽。
    ); // strip实例结束。
    always_comb begin // 前端窄描述符与主体输出共用一份外部端口。
        row_valid=front_stage && !waiting_q && !row_finished_q && (state_q!=STEM || input_sent_q) && !killed; // 已接受的行不重复发送。
        row_layer=0;row_id=stem_row_q;read_height=ROW_W'(height4<<2);read_width=COL_W'(width4<<2); // Stem真实输入尺寸。
        row_x=0;row_ab_col=0;row_count=COUNT_W'(width2);read_slot=h_slot_q;write_slot=h_slot_q; // 前端整幅每组一点。
        read_lo=0;read_hi=read_width;emit_lo=0;emit_hi=width2; // Stem输出宽减半。
        read_center_lo=0;read_center_hi=width4;write_center_lo=0;write_center_hi=width4; // 前端不使用Body中心。
        prefetch_valid=front_stage && waiting_q && !killed;prefetch_layer=1; // Stem之后H。
        case(state_q) // 前端固定拓扑。
            HCONV:begin row_layer=1;read_height=height2;read_width=width2;read_hi=width2;prefetch_layer=stem_row_q==0 ? 5'd0 : 5'd2;end // 首H之后等待下一真实行。
            VCONV:begin row_layer=2;row_id=v_row_q;read_height=height2;read_width=width2;read_hi=width2;read_slot=v_slot_q;write_slot=v_slot_q;prefetch_layer=v_row_q[0] ? 5'd3 : stem_row_q==height2-1'b1 ? 5'd2 : 5'd0;end // 每齐两行立即Down，末偶V之后drain末奇V。
            DOWN:begin row_layer=3;row_id=ROW_W'(v_row_q>>1);read_height=height2;read_width=width2;read_hi=width2;row_count=COUNT_W'(width4);emit_hi=width4;prefetch_layer=v_row_q==height2-1'b1 ? 5'd4 : 5'd0;end // 一条X0输出消费相邻两条Encoder-V行。
            BODY:begin // 主体字段直接选取，禁止再寄存第二份描述符。
                row_valid=s_row_valid && !killed;row_layer=s_layer;row_id=s_row;read_height=s_read_height; // 主体生命周期。
                row_x=s_x;row_ab_col=s_ab_col;read_width=s_read_width;row_count=s_count;read_slot=s_read_slot;write_slot=s_write_slot; // 主体几何。
                read_lo=s_read_lo;read_hi=s_read_hi;emit_lo=s_emit_lo;emit_hi=s_emit_hi; // 主体范围。
                read_center_lo=s_read_center_lo;read_center_hi=s_read_center_hi;write_center_lo=s_write_center_lo;write_center_hi=s_write_center_hi; // C中心。
                prefetch_valid=s_prefetch_valid && !killed;prefetch_layer=s_prefetch_layer; // 主体预取提示。
            end // 主体端口选择结束。
            default:begin end // 非运行状态字段不消费。
        endcase // 固定拓扑结束。
    end // 外部描述符结束。
    always_ff @(posedge clk)begin // 只保存窄状态及必要软件配置。
        if(reset)begin // 复位后权重必须重新明确加载。
            state_q<=IDLE;clear_work_q<=0;model_loaded<=0;frame_done<=0;frame_aborted<=0;model_done<=0;task_error<=0;error_code<=0; // 初始状态。
            input_base<=0;output_base<=0;x0_base<=0;load_base<=0;input_stride<=0;output_stride<=0;x0_stride<=0; // 确定配置。
            width4_q<=0;height4_q<=0;stem_row_q<=0;v_row_q<=0;h_slot_q<=0;v_slot_q<=0; // 清几何与环槽。
            waiting_q<=0;row_finished_q<=0;input_sent_q<=0;input_pending_q<=0;load_pending_q<=0;aborted_frame_q<=0; // 清在途。
        end else begin // 命令优先级高于旧帧完成。
            // Predict the next-cycle decode exactly; this is not a pipeline delay.
            if(model_take || (active_frame && work_error!=0))clear_work_q<=0;
            else case(state_q)
                IDLE:clear_work_q<=frame_take;
                SETUP:clear_work_q<=!boundary_ready;
                ABORT:clear_work_q<=abort_quiescent;
                default:clear_work_q<=0;
            endcase
            frame_done<=0;frame_aborted<=0;model_done<=0;task_error<=0; // 终结事件单拍。
            if(model_take)begin // 可从正常帧任意阶段抢占。
                load_base<=model_base;model_loaded<=0;load_pending_q<=1;aborted_frame_q<=active_frame;error_code<=0;state_q<=ABORT; // 等已发事务安全排空。
            end else if(active_frame && work_error!=0)begin // 帧异常也走相同排空路径。
                error_code<=work_error;load_pending_q<=0;aborted_frame_q<=1;state_q<=ABORT; // 不虚报帧完成。
            end else begin // 正常命令执行。
                if(input_valid && input_ready)begin input_sent_q<=1;input_pending_q<=1;end // 已启动两行RGB流。
                if(input_done && input_pending_q)input_pending_q<=0; // 输入读事务安全完成。
                if(front_stage && row_valid && row_ready)waiting_q<=1; // 锁住当前描述符。
                if(front_stage && waiting_q && row_done)begin waiting_q<=0;row_finished_q<=1;end // 等另一个DMA完成条件。
                case(state_q) // 帧级阶段。
                    IDLE:if(frame_take)begin // 一次锁存完整帧所需配置。
                        input_base<=frame_input_base;output_base<=frame_output_base;x0_base<=frame_x0_base; // DDR缓冲。
                        input_stride<=frame_input_stride;output_stride<=frame_output_stride;x0_stride<=frame_x0_stride; // 字节跨度。
                        width4_q<=9'(frame_width4);height4_q<=9'(frame_height4);error_code<=0;stem_row_q<=0;v_row_q<=0;h_slot_q<=0;v_slot_q<=0;state_q<=SETUP; // 新帧开始。
                    end // 帧命令锁存结束。
                    SETUP:if(boundary_ready)begin waiting_q<=0;row_finished_q<=0;input_sent_q<=0;input_pending_q<=0;state_q<=STEM;end // 工作状态清理后进入前端。
                    STEM:if(front_done && (!input_pending_q || input_done))begin row_finished_q<=0;state_q<=HCONV;end // 同时等Stem结果和RGB读事务结束。
                    HCONV:if(front_done)begin // 新H行提交后竖向依赖齐全。
                        row_finished_q<=0; // 下一行生命周期。
                        if(stem_row_q==0)begin stem_row_q<=1;h_slot_q<=1;input_sent_q<=0;state_q<=STEM;end // 顶边V必须等H1。
                        else state_q<=VCONV; // 计算真实V(n-1)。
                    end // H行结束。
                    VCONV:if(front_done)begin // 两行C/三行AB和两行D的生命周期推进。
                        row_finished_q<=0;v_slot_q<=v_slot_q==2 ? 0 : v_slot_q+1'b1; // V中心环槽不做宽取模。
                        if(v_row_q[0])state_q<=DOWN; // 奇行提交后立即消费D偶奇对。
                        else begin // 偶V后等待下一H，或直接drain末奇V。
                            v_row_q<=v_row_q+1'b1; // 下一个真实V。
                            if(stem_row_q!=height2-1'b1)begin stem_row_q<=stem_row_q+1'b1;h_slot_q<=h_slot_q==2 ? 0 : h_slot_q+1'b1;input_sent_q<=0;state_q<=STEM;end // 旧C残差已消费，允许复用。
                        end // 偶V推进结束。
                    end // V行结束。
                    DOWN:if(front_done)begin // 一条X0已发写，响应可在之后排空。
                        row_finished_q<=0; // 清本行完成。
                        if(v_row_q==height2-1'b1)state_q<=CHECKPOINT; // 全部前端算完。
                        else begin v_row_q<=v_row_q+1'b1;stem_row_q<=stem_row_q+1'b1;h_slot_q<=h_slot_q==2 ? 0 : h_slot_q+1'b1;input_sent_q<=0;state_q<=STEM;end // 消费D后允许下一偶V覆盖。
                    end // Down行结束。
                    CHECKPOINT:if(checkpoint_committed && boundary_ready)state_q<=BODY; // 同拍启动内含strip，下一拍切到Body。
                    BODY:if(s_done)state_q<=DRAIN; // 算完不等于DDR结果已提交。
                    DRAIN:if(output_committed && boundary_ready)begin frame_done<=1;state_q<=IDLE;end // 完整结果成功提交才通知软核。
                    // Quiescence is sampled before asserting the wide reset.
                    // The cleanup state holds abort for one extra idle cycle;
                    // AXI host state is never reset while transactions are live.
                    ABORT:if(abort_quiescent)state_q<=ABORT_CLEAR;
                    ABORT_CLEAR:begin // 总线及引擎安全结束后清旧工作。
                        waiting_q<=0;row_finished_q<=0;input_sent_q<=0;input_pending_q<=0; // 清前端窄在途。
                        frame_aborted<=aborted_frame_q;aborted_frame_q<=0; // 丢帧终结通知一次。
                        if(load_pending_q)begin load_pending_q<=0;state_q<=MODEL_OFFER;end // 立即开始新包重载。
                        else begin task_error<=error_code!=0;state_q<=IDLE;end // 异常帧结束，软件可重新发帧。
                    end // 中止排空结束。
                    MODEL_OFFER:if(load_ready)state_q<=MODEL_WAIT; // 地址与请求在回压期间保持。
                    MODEL_WAIT:if(load_done || load_error)begin // 不给不完整权重包放行。
                        model_loaded<=load_done && !load_error;model_done<=load_done && !load_error;task_error<=load_error;error_code<=load_error ? 3'd4 : 3'd0;state_q<=IDLE; // 成功或失败独立通知。
                    end // 权重提交结束。
                    default:begin end // 保持等待外部完成条件。
                endcase // 帧生命周期结束。
            end // 正常执行结束。
        end // 同步控制结束。
    end // 窄状态寄存器结束。
`ifdef SIM_ASSERT // 非法驱动检查只保留在默认仿真回归。
    always @(posedge clk)if(!reset && clear_work_q !== (state_q==SETUP || state_q==ABORT_CLEAR))$fatal(1,"FRAME clear_work state prediction mismatch"); // 直接状态译码逐周期等价。
    always @(posedge clk)if(!reset && !killed)begin // 不检查中止后允许丢弃的旧返回。
        if(frame_take && (frame_width4<2 || frame_width4>480 || frame_height4<2 || frame_height4>270))$fatal(1,"FRAME invalid dimensions"); // 软件须提供固定模型支持尺寸。
        if(input_done && !input_pending_q)$fatal(1,"FRAME unsolicited input_done"); // 只接受已发DMA完成。
        if(front_stage && row_done && !waiting_q)$fatal(1,"FRAME unsolicited row_done"); // 只接受已发前端行。
        if((load_done || load_error) && state_q!=MODEL_WAIT)$fatal(1,"FRAME unsolicited load result"); // 完成须对应重载。
        if(load_done && load_error)$fatal(1,"FRAME conflicting load result"); // 成功与失败互斥。
    end // 默认协议断言结束。
`endif // 仿真开关结束。
endmodule // 帧控制结束。
