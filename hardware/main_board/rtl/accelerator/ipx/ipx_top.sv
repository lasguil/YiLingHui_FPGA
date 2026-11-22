// 协议契约：START校验后读原图/写结果并等最后B；LOAD_DDR复用读DMA，完整768字节后才置表有效。
// 流式唯一路径：NPU结果恒经桥字流进入，无流/DDR模式选择；DDR只读同帧原图并写最终帧。
// 180MHz、公共四拍像素时隙，支持480p/720p/1080p三档；仅720p有30fps硬目标。
// 信用按每行ceil(2*流行宽/16)拍×帧高发放，行尾半拍由流源按行计数消化。
// reset须与互连协调且无在途事务；局部ABORT排空旧AR/AW/W/B，不撤销已提出的VALID。
module ipx_top #(parameter integer MAX_ROW_WIDTH=2048)( // 独立引擎默认保留宽行能力，整机按条带实例化。
    input wire csr_valid,csr_write,
    input wire [11:0] csr_address,
    input wire [31:0] csr_wdata,
    input wire [3:0] csr_wstrb,
    output logic csr_ready,csr_error,
    output wire [31:0] csr_rdata,
    input logic clk,reset, // 单一处理/总线时钟，外部CDC由互连负责。
    output logic irq, // 完成/错误中断，W1C清除。
    output logic [3:0] m_axi_arid,m_axi_awid, // 单读ID0、单写ID1。
    output logic [31:0] m_axi_araddr,m_axi_awaddr, // DDR字节地址。
    output logic [7:0] m_axi_arlen,m_axi_awlen, // 每burst至多8拍。
    output logic [2:0] m_axi_arsize,m_axi_awsize, // 16字节拍。
    output logic [1:0] m_axi_arburst,m_axi_awburst, // INCR。
    output logic m_axi_arvalid,m_axi_awvalid,m_axi_rready,m_axi_wlast,m_axi_wvalid,m_axi_bready, // DDR输出握手。
    input logic m_axi_arready,m_axi_awready,m_axi_rlast,m_axi_rvalid,m_axi_wready,m_axi_bvalid, // DDR输入握手。
    input logic [3:0] m_axi_rid,m_axi_bid, // DDR返回ID。
    input logic [127:0] m_axi_rdata, // DDR返回数据。
    input logic [1:0] m_axi_rresp,m_axi_bresp, // DDR响应错误。
    output logic [127:0] m_axi_wdata, // DDR输出数据。
    input logic [127:0] stream_data,
    input logic stream_valid,
    output logic stream_ready,
    output logic stream_start,
    output logic [18:0] stream_words,
    output logic [15:0] m_axi_wstrb, //  行尾部分拍保护。
    output wire task_busy // 已有状态的组合导出，锁定整帧路由配置。
); // 接口结束。
    import ipx_types::*; // 统一窄字段与定点契约。
    typedef enum logic [2:0] {IDLE,CHECK_INIT,CHECK_ROWS,LAUNCH,RUN,DRAIN,TABLE_LAUNCH,TABLE_RUN} state_t; // 普通帧与DDR表装载共用读DMA。
    state_t state_q; // 影子配置与不变的当前任务快照。
    config_t shadow,cfg; // 影子配置与不变的当前任务快照。
    logic start,abort_command,done_event; // 事件与首错误。
    logic [3:0] error_code; // 事件与首错误。
    logic table_write,table_valid,table_dma_start,table_task_q; // 单套768字节RGB平面表。
    logic table_byte_valid;wire table_byte_ready;logic [7:0] table_byte_data;
    logic [9:0] table_address; // 单套表装载口。
    logic [7:0] table_data; // 公共8位RGB平面表数据。
    logic [31:0] cycles,input_pixels,output_pixels,read_beats,write_beats,input_stalls,output_stalls; // 实际握手/墙钟计数。
    logic [32:0] destination_end_q,original_end_q; // 顺序累加范围，不用DSP计算stride×height。
    logic [10:0] check_rows_q; // 顺序累加范围，不用DSP计算stride×height。
    wire [32:0] destination_next=destination_end_q+{17'b0,cfg.dst_stride}; // 最多1080拍校验，约6us。
    wire [32:0] original_next=original_end_q+{17'b0,cfg.original_stride};
    wire [10:0] stream_width_q=stream_width(cfg); // 流行宽=中心加两侧接缝halo。
    wire [12:0] stream_row_bytes={2'b0,stream_width_q,1'b0};
    wire [8:0] stream_row_words=stream_row_bytes[12:4]+9'(|stream_row_bytes[3:0]); // 每行整拍数向上取整。
    wire busy=state_q!=IDLE; // 任务快照在launch前已稳定。
    assign task_busy=busy||start; // 不增加状态或存储。
    wire launch=state_q==LAUNCH; // 任务快照在launch前已稳定。
    wire table_launch=state_q==TABLE_LAUNCH;
    wire table_run=state_q==TABLE_RUN;
    wire dma_launch=launch||table_launch;
    wire dma_table_mode=table_launch||table_run||(state_q==DRAIN&&table_task_q);
    wire dma_finished,dma_idle,read_error,write_error; // 物理总线完成条件。
    wire abort_all=state_q==DRAIN||abort_command||read_error||write_error; // 新事务立即禁用，旧事务仍排空。
    wire run=state_q==RUN&&!abort_all; // 所有像素valid在非运行期隔离。
    wire dma_run=run||(table_run&&!abort_all);
    wire clear=reset||launch||!run; // 所有像素valid在非运行期隔离。
    logic [1:0] phase_q; // 全链一个公共相位。
    logic step,bad_config; // 全链一个公共相位。
    wire input_valid,input_ready,output_valid,output_ready,crop_valid,crop_done,crop_needs_input; // 输入裁切和输出实际握手。
    wire [17:0] input_data,output_data,crop_data,saturation_data,curve_data; // 各级完整RGB宏输出。
    wire dma_pixel_valid,dma_pixel_ready;
    wire [17:0] dma_pixel_data;
    
    wire saturation_valid,curve_token_valid; // 固定流水级有效标记。
    meta_t crop_meta,saturation_meta,curve_meta; // 工作值及有限图案与四相槽对齐。
    wire final_ready=output_ready||!output_valid; // 最后像素不能覆盖未接受结果。
    always_comb begin // 正常配置只需有限范围/组合检查。
        bad_config=cfg.height==0||cfg.height>1080||cfg.dst_height!=cfg.height; // 帧高与输出高必须一致。
        bad_config=bad_config||cfg.dst_width==0||cfg.dst_width>1920||cfg.dst_width[0]!=0; // 中心行宽为偶数像素。
        bad_config=bad_config||cfg.st_lo>8||cfg.st_hi>8; // 接缝halo只允许0或8（内部接缝两组四点组）。
        bad_config=bad_config||cfg.width!=stream_width_q; // 窗口行宽必须与几何一致。
        bad_config=bad_config||cfg.width>MAX_ROW_WIDTH; // 在任何DDR事务和RAM访问前拒绝超容量任务。
        bad_config=bad_config||cfg.dst[3:0]!=0||cfg.dst_stride[3:0]!=0||cfg.dst_stride<{4'b0,cfg.dst_width,1'b0}; // 对齐和有效行长度，步长不得截断。
        bad_config=bad_config||cfg.original_src[3:0]!=0||cfg.original_stride[3:0]!=0||cfg.original_stride<{4'b0,cfg.width,1'b0}; // 原图行必须完整覆盖读取行宽。
        bad_config=bad_config||cfg.saturation>512||cfg.saturation_out>512||cfg.alpha>256; // 系数范围。
        bad_config=bad_config||cfg.ai_alpha>256;
        
        for(int channel=0;channel<3;channel++)begin // 原始字段只校验一次，不在每像素重复。
            if(cfg.color_min[channel*8+:8]>cfg.color_max[channel*8+:8])bad_config=1; // 选区上下限。
        end // 参数检查结束。
        step=run&&(phase_q!=0||final_ready); // 只在宏边界接收最终像素，其他相位不可能覆盖。
    end // 任务组合结束。
    ipx_regs #(.MAX_ROW_WIDTH(MAX_ROW_WIDTH)) u_regs(.clk(clk),.reset(reset),.busy(busy), // 任务控制与装表。
        .done_event(done_event),.error_code(error_code),.cycles(cycles), // 任务控制与装表。
        .input_pixels(input_pixels),.output_pixels(output_pixels),.read_beats(read_beats), // 任务控制与装表。
        .write_beats(write_beats),.input_stalls(input_stalls),.output_stalls(output_stalls), // 任务控制与装表。
        .shadow(shadow),.start(start),.abort(abort_command), // 任务控制与装表。
        .table_write(table_write),.table_address(table_address), // 单表事务装载。
        .table_data(table_data),.table_valid(table_valid), // 单表事务装载。
        .table_dma_start(table_dma_start),.table_byte_valid(table_byte_valid),.table_byte_ready(table_byte_ready),.table_byte_data(table_byte_data),
        .table_dma_finish(table_run&&dma_finished&&dma_idle),.table_dma_error((table_launch&&abort_command)||(table_run&&(abort_command||read_error||write_error))),
        .irq(irq),.csr_valid(csr_valid), .csr_write(csr_write), .csr_address(csr_address), .csr_wdata(csr_wdata), .csr_wstrb(csr_wstrb), .csr_ready(csr_ready), .csr_error(csr_error), .csr_rdata(csr_rdata)); // 原生寄存器端口。
    assign stream_start=launch; // 每条带启动直接发放精确拍数信用。
    wire stream_pixel_valid,stream_pixel_ready,mix_ready;
    wire stream_completed;
    wire [17:0] stream_pixel;
    ipx_stream_source u_stream(.clk(clk),.clear(reset||launch),.run(run),.cfg(cfg),
        .word_valid(stream_valid),.word_ready(stream_ready),.word_data(stream_data),
        .pixel_valid(stream_pixel_valid),.pixel_ready(stream_pixel_ready),.pixel_data(stream_pixel),.completed(stream_completed));
    assign dma_pixel_ready=mix_ready&&stream_pixel_valid; // 原图与流像素严格一对一。
    assign stream_pixel_ready=mix_ready&&dma_pixel_valid;
    ipx_dma u_dma(.clk(clk),.reset(reset),.launch(dma_launch),.run(dma_run),.abort(abort_all),.table_mode(dma_table_mode),.cfg(cfg), // 原图读与最终帧写/表装载。
        .pixel_valid(dma_pixel_valid),.pixel_ready(dma_pixel_ready),.pixel_data(dma_pixel_data),
        .table_byte_valid(table_byte_valid),.table_byte_ready(table_byte_ready),.table_byte_data(table_byte_data),
        .result_valid(run&&phase_q==0&&output_valid),.result_ready(output_ready),.result_data(output_data), // 原图读与最终帧写。
        .finished(dma_finished),.idle(dma_idle),.read_error(read_error), // 原图读与最终帧写。
        .write_error(write_error), // 原图读与最终帧写。
        .m_axi_arid(m_axi_arid),.m_axi_awid(m_axi_awid),.m_axi_araddr(m_axi_araddr), // 输出AXI通道。
            .m_axi_awaddr(m_axi_awaddr),.m_axi_arlen(m_axi_arlen),.m_axi_awlen(m_axi_awlen), // 输出AXI通道。
            .m_axi_arsize(m_axi_arsize),.m_axi_awsize(m_axi_awsize),.m_axi_arburst(m_axi_arburst), // 输出AXI通道。
            .m_axi_awburst(m_axi_awburst),.m_axi_arvalid(m_axi_arvalid),.m_axi_awvalid(m_axi_awvalid), // 输出AXI通道。
            .m_axi_rready(m_axi_rready),.m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid), // 输出AXI通道。
            .m_axi_bready(m_axi_bready), // 输出AXI通道。
        .m_axi_arready(m_axi_arready),.m_axi_awready(m_axi_awready),.m_axi_rlast(m_axi_rlast), // 输入AXI/写数据。
            .m_axi_rvalid(m_axi_rvalid),.m_axi_wready(m_axi_wready),.m_axi_bvalid(m_axi_bvalid), // 输入AXI/写数据。
            .m_axi_rid(m_axi_rid),.m_axi_bid(m_axi_bid),.m_axi_rdata(m_axi_rdata), // 输入AXI/写数据。
            .m_axi_rresp(m_axi_rresp),.m_axi_bresp(m_axi_bresp),.m_axi_wdata(m_axi_wdata), // 输入AXI/写数据。
            .m_axi_wstrb(m_axi_wstrb)); // 输入AXI/写数据。
    ipx_ai_mix u_ai_mix(.clk(clk),.clear(clear),.run(run),.step(step),.phase(phase_q),.cfg(cfg),
        .in_valid(dma_pixel_valid&&stream_pixel_valid),.in_ready(mix_ready),
        .in_data(cfg.ai_enable&&cfg.ai_alpha==0?dma_pixel_data:stream_pixel), // 强度0取原图，其余取NPU结果。
        .in_original(dma_pixel_data),
        .out_valid(input_valid),.out_ready(input_ready),.out_data(input_data)); // 一颗DSP，AI强度在所有特效之前生效。
    ipx_crop #(.MAX_ROW_WIDTH(MAX_ROW_WIDTH)) u_crop(.clk(clk),.clear(clear),.run(run),
        .step(step),.phase(phase_q),.cfg(cfg),.in_valid(input_valid),.in_ready(input_ready),
        .needs_input(crop_needs_input),.in_data(input_data),.out_valid(crop_valid),.completed(crop_done),
        .out_data(crop_data),.meta(crop_meta));
    ipx_saturation u_saturation(.clk(clk),.clear(clear),.step(step),
        .phase(phase_q),.cfg(cfg),.in_valid(crop_valid),.in_data(crop_data),.in_meta(crop_meta),
        .out_valid(saturation_valid),.out_data(saturation_data),.out_meta(saturation_meta));
    ipx_curve u_curve(.clk(clk),.clear(clear),.step(step),.phase(phase_q),.cfg(cfg),
        .table_write(table_write),.table_address(table_address),.table_data(table_data[7:2]),
        .in_valid(saturation_valid),.in_data(saturation_data),.in_meta(saturation_meta),
        .out_valid(curve_token_valid),.out_data(curve_data),.out_meta(curve_meta));
    ipx_finish u_finish(.clk(clk),.clear(clear),.step(step),.phase(phase_q),.cfg(cfg),
        .in_valid(curve_token_valid),.in_data(curve_data),.in_meta(curve_meta),
        .out_valid(output_valid),.out_data(output_data));
    always_ff @(posedge clk)begin // 唯一任务控制与总周期计数。
        if(reset)begin stream_words<=0;state_q<=IDLE;table_task_q<=0; // 安全硬复位。
            cfg<='0; // 安全硬复位。
            error_code<=0; // 安全硬复位。
            done_event<=0; // 安全硬复位。
            destination_end_q<=0; // 安全硬复位。
            original_end_q<=0;
            check_rows_q<=0; // 安全硬复位。
            phase_q<=0; // 安全硬复位。
            cycles<=0; // 安全硬复位。
            input_pixels<=0; // 安全硬复位。
            output_pixels<=0; // 安全硬复位。
            read_beats<=0; // 安全硬复位。
            write_beats<=0; // 安全硬复位。
            input_stalls<=0; // 安全硬复位。
            output_stalls<=0; // 安全硬复位。
        end // 安全硬复位。
        else begin // 正常任务生命周期。
            done_event<=0; // 完成脉冲给CSR保持。
            if(clear)phase_q<=0; // 只用CE，不用软件轮询产生像素时钟。
            else if(step)phase_q<=phase_q+1'b1; // 只用CE，不用软件轮询产生像素时钟。
            if(busy)cycles<=cycles+1'b1; // 包含校验、DDR等待、排空与最后B。
            if(input_valid&&input_ready)input_pixels<=input_pixels+1'b1; // 实际输入采样像素。
            if(run&&phase_q==0&&output_valid&&output_ready)output_pixels<=output_pixels+1'b1; // 实际输出独立像素。
            if(m_axi_rvalid&&m_axi_rready)read_beats<=read_beats+1'b1; // 包含中止排空的总线拍。
            if(m_axi_wvalid&&m_axi_wready)write_beats<=write_beats+1'b1; // 按真实W握手统计。
            if(run&&phase_q==0&&step&&crop_needs_input&&!input_valid)input_stalls<=input_stalls+32'd4; // 等待真实输入像素。
            if(run&&phase_q==0&&!final_ready)output_stalls<=output_stalls+1'b1; // 输出背压墙钟拍。
            case(state_q) // 不使用通用描述符解释器。
                IDLE:if(table_dma_start)begin
                    cfg<=shadow;
                    table_task_q<=1;
                    state_q<=TABLE_LAUNCH;
                    error_code<=0;
                end else if(start)begin
                    table_task_q<=0;
                    stream_words<=0;
                    cfg<=shadow; // 原子任务快照。
                    state_q<=CHECK_INIT; // 原子任务快照。
                    error_code<=0; // 原子任务快照。
                    cycles<=0; // 原子任务快照。
                    input_pixels<=0; // 原子任务快照。
                    output_pixels<=0; // 原子任务快照。
                    read_beats<=0; // 原子任务快照。
                    write_beats<=0; // 原子任务快照。
                    input_stalls<=0; // 原子任务快照。
                    output_stalls<=0; // 原子任务快照。
                end // 原子任务快照。
                CHECK_INIT:begin // 第一拍有限参数检查，不访问DDR。
                    if(bad_config)begin error_code<=1; // BAD_CONFIG。
                        done_event<=1; // BAD_CONFIG。
                        state_q<=IDLE; // BAD_CONFIG。
                    end // BAD_CONFIG。
                    else if(!table_valid)begin error_code<=6; // TABLE_INVALID。
                        done_event<=1; // TABLE_INVALID。
                        state_q<=IDLE; // TABLE_INVALID。
                    end // TABLE_INVALID。
                    else begin destination_end_q<={1'b0,cfg.dst}; // 逐行加法校验地址范围。
                        original_end_q<={1'b0,cfg.original_src};
                        check_rows_q<=cfg.height; // 逐行加法校验地址范围。
                        state_q<=CHECK_ROWS; // 逐行加法校验地址范围。
                    end // 逐行加法校验地址范围。
                end // 初检结束。
                CHECK_ROWS:begin // 最大1080拍预检，避免两个32位乘法器。
                    stream_words<=stream_words+{10'b0,stream_row_words}; // 顺便计算条带拍数，不用乘法器。
                    destination_end_q<=destination_next; // 完整包含行stride分配。
                    original_end_q<=original_next;
                    check_rows_q<=check_rows_q-1'b1; // 完整包含行stride分配。
                    if(destination_next[32]||original_next[32])begin error_code<=2; // ADDRESS_OVERFLOW。
                        done_event<=1; // ADDRESS_OVERFLOW。
                        state_q<=IDLE; // ADDRESS_OVERFLOW。
                    end // ADDRESS_OVERFLOW。
                    else if(check_rows_q==1)begin // 只在全范围已知后检查重叠。
                        if(!(original_next<={1'b0,cfg.dst}||destination_next<={1'b0,cfg.original_src}))begin error_code<=2; // OVERLAP。
                            done_event<=1; // OVERLAP。
                            state_q<=IDLE; // OVERLAP。
                        end // OVERLAP。
                        else state_q<=LAUNCH; // 两个帧区互不覆盖。
                    end // 范围检查结束。
                    if(abort_command)begin error_code<=5; // 尚无在途事务时立即中止。
                        done_event<=1; // 尚无在途事务时立即中止。
                        state_q<=IDLE; // 尚无在途事务时立即中止。
                    end // 尚无在途事务时立即中止。
                end // 校验状态结束。
                LAUNCH:state_q<=RUN; // 这一拍清DMA/FIFO与窗口valid，不清表。
                TABLE_LAUNCH:if(abort_command)begin
                    error_code<=4'd5;
                    state_q<=DRAIN;
                end else state_q<=TABLE_RUN;
                TABLE_RUN:begin
                    if(read_error||write_error||abort_command)begin
                        error_code<=read_error?4'd3:write_error?4'd4:4'd5;
                        state_q<=DRAIN;
                    end else if(dma_finished&&dma_idle)begin
                        table_task_q<=0;
                        state_q<=IDLE;
                    end
                end
                RUN:begin // 不将同一帧各算术级耗时串行累加。
                    if(read_error||write_error||abort_command)begin error_code<=read_error?4'd3:write_error?4'd4:4'd5; // 首错停止新事务。
                        state_q<=DRAIN; // 首错停止新事务。
                    end // 首错停止新事务。
                    else if(dma_finished&&dma_idle&&stream_completed&&crop_done)begin done_event<=1; // 最后B及完整NPU条带均已排空。
                        state_q<=IDLE; // 最后B及R通道均已静止。
                    end // 最后B及R通道均已静止。
                end // 正常执行结束。
                DRAIN:if(dma_idle)begin done_event<=1; // 已提出的AR/AW/W全部排空。
                    state_q<=IDLE;table_task_q<=0; // 已提出的AR/AW/W全部排空。
                end // 已提出的AR/AW/W全部排空。
                default:state_q<=IDLE; // 复位后的安全兜底。
            endcase // 任务控制结束。
        end // 正常寄存器结束。
    end // 顶层控制结束。
`ifdef SIM_ASSERT // 边界和完成证明。
    always @(posedge clk)if(!reset)begin // 集成期间开启。
        if(launch&&!dma_idle)$fatal(1,"IPX launch with outstanding AXI"); // 不能复位在途事务。
        if(done_event&&!dma_idle)$fatal(1,"IPX premature DONE"); // 完成以最后B为界。
    end // 检查结束。
`endif // 仿真断言结束。
endmodule // 独立DDR图像引擎结束。
