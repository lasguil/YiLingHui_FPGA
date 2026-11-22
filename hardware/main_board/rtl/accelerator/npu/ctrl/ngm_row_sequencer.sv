// 协议契约：cmd握手执行固定模型一条真实行；行间依赖、权重预取及源行提交由strip定序器保证。
// cmd_weights_ready表示本命令39×有效槽数+40项已装完；行启动提交单套SRL层锚点，每个stage均须配套装载。
// cmd_valid期间保持描述符；合法性预检查一拍后才可握手。命令接受后锁存窄字段，外部可摆下一命令；next_*基址查询下一命令，不改变当前运行层。
// 接受命令后留一个完整空闲沿给bank切相位；不产生strip_start、DMA或帧级调度。
// win_req是完整窗口的逻辑事务，不是memory_subsystem.req逐字事务，两者禁止直接接线。
// 窗口供数路径负责Stem输入、横向三列、Down/Head两次读、Decoder-V偶奇请求合并及residual读取。
// win_x为真实组首列；供数路径按请求顺序写行引擎load端，window_done与最后一次load同拍。
// window_done无回压；供数路径须避免覆盖正在算或已完成未消费的半区，不能把所有RAM返回直接当完整窗口。
// 通常最多三个未消费的逻辑窗口请求；Decoder-V需四个名额覆盖两窗一读与一级原字请求寄存。
// 名额只包含窄事务，不保存激活数据；两块实体窗口由供数路径保护；请求间隔slots×batches拍。
// 首窗到达当拍即可启动行引擎，不等下一拍；否则Decoder-V的紧接奇窗可能在空闲态被错误翻牌。
// issue_batch_last标记实际批末issue，residual须在其后8拍送到skip_codes；本模块不保存宽激活数据。
// 行引擎从真实首列计数，code_x/pixel_x直接返回真实坐标；AB局部列加命令沿算好的局部/真实列偏移，不反复做坐标减法。
// code/pixel无回压；结果有效时sink_ready必须为一，否则报错并停止正常完成，不能静默丢数。
// row_done等最后实际结果、写口和全部窗口排空；最近邻纵向两行使用源行别名，不再等待重复写。
// 所有engine_*及window_done必须来自同一行引擎；reset清控制与错误，非法命令不接受。
module ngm_row_sequencer #( // 固定模型的窄行控制。
    parameter int unsigned ROW_W=11,COL_W=11,COUNT_W=10 // 行列和组数位宽与现有行引擎一致。
)( // 接口开始。
    input logic clk,reset, // 时钟与同步复位。
    input logic cmd_valid,cmd_weights_ready, // 行命令和对应权重已装好。
    output logic cmd_ready, // 接受命令指示。
    input logic [4:0] cmd_layer_id, // 待执行层。
    input logic [ROW_W-1:0] cmd_row, // 真实行号。
    input logic [COL_W-1:0] cmd_x_start,cmd_ab_col_start, // 真实和AB局部行首。
    input logic [COUNT_W-1:0] cmd_point_count, // 调用方已按1/4/5打包的完整组数。
    input logic [1:0] cmd_read_slot,cmd_write_slot, // 中心读槽和结果写槽。
    output logic next_desc_valid, // 外部当前待执行描述符合法。
    output logic [11:0] next_weight_base,next_param_base, // 待执行层主表基址。
    output logic busy,row_done, // 当前行占用与已全部写回脉冲。
    output logic [4:0] stage_layer_id, // 正在执行层，保持至完成。
    output logic [ROW_W-1:0] stage_row, // 正在执行行。
    output logic [1:0] stage_read_slot,stage_write_slot, // 正在执行行槽。
    output logic [2:0] cfg_kind,cfg_point_group, // 运行形状，连接现有行引擎。
    output logic [1:0] cfg_slots,cfg_batches, // 运行段数和批数。
    output logic [COL_W-1:0] cfg_x_start, // 真实行首锁存后送行引擎现有列走位器。
    output logic [COUNT_W-1:0] cfg_point_count, // 运行组数。
    output logic engine_row_start_valid, // 首窗口和行配置联合启动请求。
    input logic engine_row_ready, // 现有行引擎行握手。
    output logic win_req_valid, // 完整窗口逻辑请求。
    input logic win_req_ready, // 窗口供数路径可接收。
    output logic [COL_W-1:0] win_x,win_ab_col, // 下一窗口真实和局部列。
    input logic window_done, // 完整窗口装好。
    input logic engine_window_released,engine_row_boundary, // 点末issue和本行末点。
    output logic window_take, // 当拍行引擎真正消费一个窗口。
    output logic issue_batch_last,issue_batch, // 当前实际批末issue和批号。
    output logic [COL_W-1:0] issue_x, // 当前issue所属真实组首列。
    input logic engine_code_valid,engine_code_batch, // 非RGB结果有效及批。
    input logic [COL_W-1:0] engine_code_x, // 行引擎真实组首列。
    input logic code_sink_ready, // memory_subsystem.code_ready，包含最近邻第二行占用。
    output logic [COL_W-1:0] code_x,code_ab_col, // 返回真实和AB局部列。
    input logic engine_pixel_valid,pixel_sink_ready, // RGB字节有效和输出队列接收。
    input logic [1:0] engine_pixel_beat, // RGB组内字节拍0/1/2。
    input logic [COL_W-1:0] engine_pixel_x, // RGB真实组首列。
    output logic [COL_W-1:0] pixel_x, // RGB真实组首列。
    output logic protocol_error // 命令或无回压结果错误保持。
); // 接口结束。
    typedef enum logic [2:0] {IDLE,SETTLE,WAIT_FIRST,RUN,DRAIN,FAULT} state_t; // 行生命周期。
    state_t state_q; // 当前生命周期。
    logic [2:0] next_kind,next_group;logic [1:0] next_slots,next_batches; // 待执行形状。
    ngm_descriptor_store u_descriptor_store( // 单份地址查询，允许上层预取下一命令。
        .layer_id(cmd_layer_id),.desc_valid(next_desc_valid),.kind(next_kind), // 待执行层。
        .slots(next_slots),.batches(next_batches),.point_group(next_group), // 模型形状。
        .weight_base(next_weight_base),.param_base(next_param_base) // 待执行层基址。
    ); // 描述符例化结束。
    logic [COL_W-1:0] ab_offset_q; // 真实坐标到AB局部列的固定偏移。
    logic [COUNT_W-1:0] requests_left_q,results_left_q; // 请求和实际结果分别计数。
    logic [2:0] outstanding_q; // Decoder-V最多四个窄逻辑名额，其他层仍为三个。
    logic window_pending_q,point_active_q,boundary_seen_q; // 已完成下一窗、当前点正在issue、末点已发完。
    logic [2:0] cooldown_q,phase_q; // 请求冷却和当前点issue相位。
    wire [2:0] period_now=cfg_batches==2 ? {cfg_slots,1'b0} : {1'b0,cfg_slots}; // 仅一批或两批，无乘法。
    wire command_good=next_desc_valid && cmd_point_count!=0; // 启动最低合法性。
    wire command_take=cmd_valid && cmd_ready; // 行命令实际接收。
    logic command_good_q; // 合法性提前一拍确定，切断strip算术到RAM读口的组合链。
    always_ff @(posedge clk)begin // valid期间描述符保持；接受后立即撤销旧授权。
        if(reset)command_good_q<=0; // 复位禁止旧命令授权。
        else command_good_q<=state_q==IDLE && cmd_valid && command_good && !command_take; // 一拍预检查，不保存宽数据。
    end // 忙期间清零，下一条命令必须重新检查。

    wire row_take=engine_row_start_valid && engine_row_ready; // 首组实际开始。
    wire next_take=state_q==RUN && !engine_row_boundary && (!point_active_q || engine_window_released) && (window_pending_q || window_done); // 镜像现有点引擎收点条件。
    wire request_take=win_req_valid && win_req_ready; // 窗口请求实际接收。
    wire result_group=cfg_kind==4 ? engine_pixel_valid && engine_pixel_beat==2 && pixel_sink_ready : engine_code_valid && engine_code_batch==(cfg_batches==2) && code_sink_ready; // 只数每组最后一次返回。
    wire result_fault=(engine_code_valid && !code_sink_ready) || (engine_pixel_valid && !pixel_sink_ready); // 无回压路径不得丢数。
    assign busy=state_q!=IDLE; // 包含相位静置和写回排空。
    assign cmd_ready=state_q==IDLE && cmd_weights_ready && command_good_q; // 新权重未装好时不启动。
    assign engine_row_start_valid=state_q==WAIT_FIRST; // 提前等待首窗，允许同拍完成和启动。
    assign window_take=row_take || next_take; // 真正消费时刻。
    assign win_req_valid=(state_q==WAIT_FIRST || state_q==RUN) && requests_left_q!=0 && cooldown_q==0 && (outstanding_q<(stage_layer_id==14 ? 3'd4 : 3'd3) || window_take); // Decoder-V提前排下一对，其余层三个名额。
    assign issue_batch_last=point_active_q && (phase_q=={1'b0,cfg_slots}-1'b1 || phase_q==period_now-1'b1); // 每批最后一次issue。
    assign issue_batch=cfg_batches==2 && phase_q>={1'b0,cfg_slots}; // 实际批号。
    assign code_x=engine_code_x;assign code_ab_col=ab_offset_q+engine_code_x; // 真实列直通，只有AB写口加固定局部偏移。
    assign pixel_x=engine_pixel_x; // RGB真实列直通，不再做写回加法。
    always_ff @(posedge clk)begin // 只保存控制、计数及标签。
        if(reset)begin // 确定控制复位。
            state_q<=IDLE;row_done<=0;protocol_error<=0; // 清生命周期。
            stage_layer_id<=0;stage_row<=0;stage_read_slot<=0;stage_write_slot<=0; // 无运行行。
            cfg_kind<=0;cfg_slots<=1;cfg_batches<=1;cfg_point_group<=1;cfg_point_count<=0; // 安全形状。
            cfg_x_start<=0;ab_offset_q<=0;win_x<=0;win_ab_col<=0;issue_x<=0; // 清窄坐标。
            requests_left_q<=0;results_left_q<=0;outstanding_q<=0; // 清在途数量。
            window_pending_q<=0;point_active_q<=0;boundary_seen_q<=0;cooldown_q<=0;phase_q<=0; // 清窗口控制。
        end else begin // 正常执行。
            row_done<=0; // 完成脉冲。
            if(state_q==IDLE && cmd_valid && !command_good)protocol_error<=1; // 非法命令不接收且报错。
            if(cooldown_q!=0)cooldown_q<=cooldown_q-1'b1; // 回压期间仍推进节奏。
            if(command_take)begin // 当前命令锁存后外部可以查询下一层。
                state_q<=SETTLE;stage_layer_id<=cmd_layer_id;stage_row<=cmd_row; // 行开始。
                stage_read_slot<=cmd_read_slot;stage_write_slot<=cmd_write_slot; // 保存行槽。
                cfg_kind<=next_kind;cfg_slots<=next_slots;cfg_batches<=next_batches;cfg_point_group<=next_group;cfg_point_count<=cmd_point_count; // 保存运行形状。
                cfg_x_start<=cmd_x_start;ab_offset_q<=cmd_ab_col_start-cmd_x_start;win_x<=cmd_x_start;win_ab_col<=cmd_ab_col_start;issue_x<=cmd_x_start; // 保存行基址。
                requests_left_q<=cmd_point_count;results_left_q<=cmd_point_count;outstanding_q<=0; // 初始化本行计数。
                window_pending_q<=0;point_active_q<=0;boundary_seen_q<=0;cooldown_q<=0;phase_q<=0; // 无旧窗口。
            end else begin // 推进当前行。
                if(state_q==SETTLE)state_q<=WAIT_FIRST; // 完整空一个相位切换沿。
                if(row_take)state_q<=RUN; // 首窗到达时即启动。
                if(request_take)begin // 回压时这些字段均保持。
                    requests_left_q<=requests_left_q-1'b1; // 下一未发请求。
                    win_x<=win_x+COL_W'(cfg_point_group);win_ab_col<=win_ab_col+COL_W'(cfg_point_group); // 只做1/4/5增量。
                    cooldown_q<=period_now-1'b1; // 相邻请求间隔本层一个点的issue拍数。
                end // 请求推进结束。
                case({request_take,window_take}) // 同拍请求和消费抵消。
                    2'b10:outstanding_q<=outstanding_q+1'b1; // 新请求占名额。
                    2'b01:outstanding_q<=outstanding_q-1'b1; // 点引擎消费名额。
                    default:begin end // 保持。
                endcase // 在途数量结束。
                case({window_done,window_take}) // 一份下一窗完成标记，不复制窗口数据。
                    2'b10:window_pending_q<=1; // 已完成但未消费。
                    2'b01:window_pending_q<=0; // 消费已有完成窗口。
                    default:begin end // 同拍一进一出或保持。
                endcase // 完成标记结束。
                if(window_take)begin // 下一点从下一周期开始issue。
                    point_active_q<=1;phase_q<=0; // 与现有点引擎状态同步。
                    if(!row_take)issue_x<=issue_x+COL_W'(cfg_point_group); // 后续点真实列。
                end else if(engine_window_released)point_active_q<=0; // 未接受下一点时等待。
                else if(point_active_q)phase_q<=phase_q+1'b1; // 一点最多六次issue。
                if(engine_row_boundary)boundary_seen_q<=1; // 最后issue完成，仍等待实际结果。
                if(result_group && results_left_q!=0)begin // 只在有效末批或RGB末字节返回时计数。
                    results_left_q<=results_left_q-1'b1; // 减少在途结果。
                    if(results_left_q==1)state_q<=DRAIN; // 最后实际结果已接收。
                end // 结果更新结束。
                if(state_q==DRAIN && code_sink_ready && outstanding_q==0 && !window_pending_q && boundary_seen_q)begin // 包括最近邻第二行的接收状态。
                    state_q<=IDLE;row_done<=1; // 完整行写回结束。
                end // 写回排空结束。
                if(result_fault)begin protocol_error<=1;state_q<=FAULT;end // 丢数后禁止谎报正常完成。
            end // 当前行推进结束。
        end // 正常执行结束。
    end // 控制寄存器结束。
`ifdef SIM_ASSERT // 上游非法调度只作仿真检查，不增加宽硬件比较。
    always @(posedge clk)if(!reset)begin // 逐事务协议检查。
        if(window_done && !(state_q==WAIT_FIRST || state_q==RUN))$fatal(1,"ROWSEQ window outside active row"); // 静止边界不装窗。
        if(window_done && window_pending_q)$fatal(1,"ROWSEQ window overwrite"); // 消费旧窗的沿也不能覆盖旧窗，角色只能在该沿之后翻转。
        if(window_take && outstanding_q==0 && !request_take)$fatal(1,"ROWSEQ unrequested window"); // 消费必须对应请求。
        if(engine_window_released && (!point_active_q || phase_q!=period_now-1'b1))$fatal(1,"ROWSEQ issue phase mismatch"); // 镜像时刻与真实issue一致。
        if(engine_row_boundary && requests_left_q!=0)$fatal(1,"ROWSEQ early row boundary"); // 最后组已发请求。
        if(result_group && (results_left_q==0 || state_q==IDLE))$fatal(1,"ROWSEQ extra result"); // 返回组数准确。
        if(result_fault)$fatal(1,"ROWSEQ result backpressure"); // 无回压契约必须可证伪。
    end // 协议检查结束。
`endif // 仿真检查结束。
endmodule // 行定序器结束。
