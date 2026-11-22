/* OPTIMIZATION_NOTE_20261005
 * DMA资源优化约束（2026-10-05）：读字寄存器只在实际消费像素时右移16位。
 * 背压时禁止移位；主图/原图各自状态保持，不能把同拍到达当作像素配对依据。
 * 21位stride步进覆盖16位stride及合法最大左移5位，随后扩展为32位地址；不放宽地址溢出规则。
 * 同步RAM写队列有front预取延迟，必须按valid出W拍；容量仍24、burst稳态每拍一字。
 * 这些优化不新增DDR事务；流式唯一路径下读端只读原图。
 * 详见 docs/OPTIMIZATION_CONSTRAINTS.md。
 */
// 协议契约：每命令仅当前最多8拍burst；读先预留8槽，写先积齐整burst，成功完成必须等最后B。
// 流式契约：读端只读原图（NPU结果只走字流），删除双源配对；读行宽为窗口行宽，写行宽为中心行宽。
// RGB565读每次消费半字、写分两个字节打包，8像素/128位拍；行尾keep丢弃padding，中止不清在途写FIFO。
module ipx_dma( // 读控制、字节适配与窄深度FIFO各只有一份。
    input logic clk,reset,launch,run,abort,table_mode, // table_mode复用读FIFO按字节消费。
    input wire ipx_types::config_t cfg, // 整任务不变的快照。
    output logic pixel_valid, // 完整RGB像素保持至消费。
    input logic pixel_ready, // 空间前端接受像素。
    output logic [17:0] pixel_data, // 同坐标原图，AI混合配对使用。
    output logic table_byte_valid,input logic table_byte_ready,output logic [7:0] table_byte_data,
    input logic result_valid, // 最终效果像素。
    output logic result_ready, // 能接收一整个像素。
    input logic [17:0] result_data, // 已对齐最终RGB。
    output logic finished,idle,read_error,write_error, // 最后B完成或总线状态。
    output logic [3:0] m_axi_arid,m_axi_awid, // 固定单读/写ID。
    output logic [31:0] m_axi_araddr,m_axi_awaddr, // 对齐字节地址。
    output logic [7:0] m_axi_arlen,m_axi_awlen, // INCR拍数减一。
    output logic [2:0] m_axi_arsize,m_axi_awsize, // 恒为4。
    output logic [1:0] m_axi_arburst,m_axi_awburst, // 恒为INCR。
    output logic m_axi_arvalid,m_axi_awvalid,m_axi_rready,m_axi_wlast,m_axi_wvalid,m_axi_bready, // 总线输出握手。
    input logic m_axi_arready,m_axi_awready,m_axi_rlast,m_axi_rvalid,m_axi_wready,m_axi_bvalid, // 总线输入握手。
    input logic [3:0] m_axi_rid,m_axi_bid, // 返回ID。
    input logic [127:0] m_axi_rdata, // 连续16字节。
    input logic [1:0] m_axi_rresp,m_axi_bresp, // 错误响应不得丢弃。
    output logic [127:0] m_axi_wdata, // 写FIFO队首保持。
    output logic [15:0] m_axi_wstrb // 末拍有效字节。
); // 接口结束。
    import ipx_types::*; // 空间模式决定采样源行步进。
    logic [31:0] read_address_q,read_row_q,write_address_q,write_row_q; // 地址只按burst或行递增。
    logic [12:0] read_left_q,write_left_q; // 当前行剩余有效字节。
    logic [10:0] read_y_q,write_y_q; // 已采样的源行号与已输出的目标行号。
    logic read_finished_q; // 只有当前命令长度快照。
    logic [12:0] read_chunk_q,write_chunk_q; // 只有当前命令长度快照。
    wire [10:0] win_width=11'(cfg.dst_width+cfg.st_lo+cfg.st_hi); // 窗口/原图读取行宽。
    wire [12:0] read_row_bytes=table_mode?13'd768:{2'b0,win_width,1'b0}; // 表加载768字节，正常读窗口行。
    wire [12:0] write_row_bytes={2'b0,cfg.dst_width,1'b0}; // 输出中心行字节数，最大3840。
    wire [4:0] row_step=5'd1; // 每一源行均读取。
    wire [20:0] source_step={5'd0,cfg.original_stride};
    logic read_command,read_ready,read_valid,read_accept,read_done,read_last; // AXI读命令与返回。
    logic write_command,write_ready,write_valid,write_accept,write_done; // AXI写命令与数据。
    wire [127:0] returned_data; // 不把连续字节数膨胀成16位keep存储。
    wire [4:0] returned_bytes; // 不把连续字节数膨胀成16位keep存储。
    wire [132:0] read_front; // 读带5位长度，写带4位末字节。
    wire [131:0] write_front; // 读带5位长度，写带4位末字节。
    logic [131:0] write_entry; // 读带5位长度，写带4位末字节。
    logic [3:0] read_count; wire [4:0] write_count; wire write_space; // FIFO实际握手。
    logic read_pop,write_pop,write_push; // FIFO实际握手。
    logic [12:0] read_chunk,write_chunk; // 当前可发burst长度。
    logic [3:0] write_needed; // 当前可发burst长度。
    logic [127:0] read_word_q,write_word_q,assembled_word; // 两个当前拍寄存均保存补码，8位适配处恢复，节省128位反相LUT。
    logic [4:0] read_bytes_q; // 适配器占用与有效字节数。
    logic read_word_valid_q,pack_active_q; // 适配器占用与有效字节数。
    logic [3:0] read_byte_q,write_byte_q; // 小字节/通道计数。
    logic write_channel_q; // 小字节/通道计数。
    logic [15:0] packed_pixel_q; // 当前输出像素与行尾判定。
    logic [10:0] packed_x_q; // 当前输出像素与行尾判定。
    wire clear=reset||launch; // 新任务必须已排空旧总线。
    wire [15:0] read_half=~read_word_q[15:0]; // 只对选出的8位恢复极性，反相吸收在选择LUT中。
    wire consume_byte=run&&!table_mode&&read_word_valid_q&&(!pixel_valid||pixel_ready); // 结果槽被占用时不覆盖。
    wire consume_table_byte=run&&table_mode&&read_word_valid_q&&table_byte_ready;
    wire pack_end=write_byte_q==15||(write_channel_q==1&&packed_x_q==cfg.dst_width-1'b1); // 拍满或有效行结束。
    wire pack_byte=run&&pack_active_q&&(!pack_end||write_space); // 刷拍前保证有队列槽。
    function automatic logic [12:0] chunk_bytes(input logic [12:0] remaining,input logic [11:0] address); // burst不跨4KiB。
        logic [12:0] page_left; // 最大4096字节。
        begin page_left=13'd4096-{1'b0,address}; // 只有窄比较。
            chunk_bytes=remaining<128?remaining:13'd128; // 只有窄比较。
            if(page_left<chunk_bytes)chunk_bytes=page_left; // 只有窄比较。
        end // 只有窄比较。
    endfunction // 拆分函数结束。
    always_comb begin // 读写命令分别自主推进，不等待算术整帧完成。
        read_chunk=chunk_bytes(read_left_q,read_address_q[11:0]); // 对齐地址下尾拍只出现在行尾。
        write_chunk=chunk_bytes(write_left_q,write_address_q[11:0]); // 对齐地址下尾拍只出现在行尾。
        write_needed=write_chunk[7:4]+{3'b0,|write_chunk[3:0]}; // chunk≤128，明确4位ceil(chunk/16)。
        read_command=run&&!read_done&&!read_finished_q&&read_count==0;
        write_command=run&&!table_mode&&!write_done&&!finished&&write_count>={1'b0,write_needed}; // AW前数据已完整，B完成拍不重发旧地址。
        assembled_word=write_word_q; // 当前字节在8位选择器出口取补码。
        assembled_word[write_byte_q*8+:8]=~(write_channel_q ? packed_pixel_q[15:8] : packed_pixel_q[7:0]); // 当前字节在8位选择器出口取补码。
        write_entry={~write_byte_q,assembled_word}; // SRL反相Q恢复字节编号和RGB，不存展开的掩码。
        write_push=pack_byte&&pack_end; // 真正的数据握手。
        write_pop=write_valid&&write_accept; // 真正的数据握手。
        read_pop=run&&!read_word_valid_q&&read_count!=0;
        table_byte_valid=run&&table_mode&&read_word_valid_q;
        table_byte_data=~read_word_q[7:0];
        result_ready=run&&!table_mode&&!pack_active_q; // 一次接收完整像素，随后两拍写字节。
    end // 组合控制结束。
    ipx_fifo8 #(.WIDTH(133),.INVERT_INPUT(0)) u_read_fifo(.clk(clk),.clear(clear), // 原始R输入直接进SRL，返回补码。
        .push(read_valid&&read_accept),.pop(read_pop),.data_in({returned_bytes,returned_data}), // 原始R输入直接进SRL，返回补码。
        .data_out(read_front),.count(read_count)); // 原始R输入直接进SRL，返回补码。
    ipx_write_queue u_write_fifo(.clk(clk),.clear(clear), // 输入已是补码，Q返回正常RGB/末字节号。
        .push(write_push),.pop(write_pop),.data_in(write_entry), // 输入已是补码，Q返回正常RGB/末字节号。
        .data_out(write_front),.count(write_count),.ready(write_space),.valid(write_valid)); // 输入已是补码，Q返回正常RGB/末字节号。
    assign read_accept=read_count<8;

    ipx_axi_master u_axi( // 每个外层命令只一个已预留burst。
        .clk(clk),.reset(clear),.abort(abort), // launch已保证总线静止，清旧错误标记。
            .read_valid(read_command),.read_ready(read_ready),.read_address(read_address_q),
            .read_length(read_chunk[7:0]), // launch已保证总线静止，清旧错误标记。
        .read_data_valid(read_valid),.read_data_ready(read_accept),.read_data(returned_data), // R错误向顶层保持。
            .read_bytes(returned_bytes),.read_last(read_last),.read_done(read_done), // R错误向顶层保持。
            .read_error(read_error), // R错误向顶层保持。
        .write_valid(write_command),.write_ready(write_ready),.write_address(write_address_q),.write_length(write_chunk[7:0]), // 当前FIFO已含全部拍。
        .write_data_valid(write_valid),.write_data_ready(write_accept),.write_data(write_front[127:0]), // B响应后才完成。
            .write_last_byte(write_front[131:128]),.write_done(write_done),.write_error(write_error), // B响应后才完成。
            .idle(idle), // B响应后才完成。
        .m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen), // 读地址通道。
            .m_axi_arsize(m_axi_arsize),.m_axi_arburst(m_axi_arburst),.m_axi_arvalid(m_axi_arvalid), // 读地址通道。
            .m_axi_arready(m_axi_arready), // 读地址通道。
        .m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp), // 读数据通道。
            .m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready), // 读数据通道。
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen), // 写地址通道。
            .m_axi_awsize(m_axi_awsize),.m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid), // 写地址通道。
            .m_axi_awready(m_axi_awready), // 写地址通道。
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast), // 写数据/响应。
            .m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),.m_axi_bid(m_axi_bid), // 写数据/响应。
            .m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready)); // 写数据/响应。
    always_ff @(posedge clk)begin // 地址计数均以命令握手为准。
        if(clear)begin // cfg在launch前已经稳定。
            read_address_q<=cfg.original_src;
            read_row_q<=cfg.original_src;
            write_address_q<=cfg.dst; // 帧地址。
            write_row_q<=cfg.dst; // 帧地址。
            read_left_q<=read_row_bytes; // 行状态。
            write_left_q<=write_row_bytes; // 行状态。
            read_y_q<=0; // 行状态。
            write_y_q<=0; // 行状态。
            read_finished_q<=0; // 行状态。
            finished<=0; // 行状态。
            read_chunk_q<=0; // 命令快照。
            write_chunk_q<=0; // 命令快照。
            pixel_valid<=0; // 不清当前拍数据，valid隔离旧任务。
            read_word_valid_q<=0; // 不清当前拍数据，valid隔离旧任务。
            read_byte_q<=0; // 不清当前拍数据，valid隔离旧任务。
            read_bytes_q<=0; // 不清当前拍数据，valid隔离旧任务。
            pack_active_q<=0; // 打包器只复位有效性与索引。
            packed_x_q<=0; // 打包器只复位有效性与索引。
            write_channel_q<=0; // 打包器只复位有效性与索引。
            write_byte_q<=0; // 打包器只复位有效性与索引。
        end else begin // 正常搬运；abort只影响新命令，已接受W继续出队。
            if(read_command&&read_ready)read_chunk_q<=read_chunk; // 当前返回对应长度。
            if(write_command&&write_ready)write_chunk_q<=write_chunk; // 当前B对应长度。
            if(read_done&&run)begin // 前一命令数据均已进入FIFO。
                if(read_left_q==read_chunk_q)begin // 当前采样行结束。
                    if({1'b0,read_y_q}+{7'b0,row_step}>={1'b0,(table_mode?11'd1:cfg.height)})read_finished_q<=1; // 最后一条被采样源行。
                    else begin
                        read_y_q<=read_y_q+11'(row_step);
                        read_row_q<=read_row_q+source_step;
                        read_address_q<=read_row_q+source_step;
                        read_left_q<=read_row_bytes;
                    end
                end else begin
                    read_left_q<=read_left_q-read_chunk_q;
                    read_address_q<=read_address_q+32'(read_chunk_q);
                end
            end // 读完成结束。
            if(write_done&&run)begin // 最后B才推进目标。
                if(write_left_q==write_chunk_q)begin // 当前目标行结束。
                    if(write_y_q==cfg.height-1'b1)finished<=1; // 整帧所有B均完成。
                    else begin write_y_q<=write_y_q+1'b1; // 下一目标行。
                        write_row_q<=write_row_q+32'(cfg.dst_stride); // 下一目标行。
                        write_address_q<=write_row_q+32'(cfg.dst_stride); // 下一目标行。
                        write_left_q<=write_row_bytes; // 下一目标行。
                    end // 下一目标行。
                end else begin write_left_q<=write_left_q-write_chunk_q; // 下一写burst。
                write_address_q<=write_address_q+32'(write_chunk_q); // 下一写burst。
                end // 下一写burst。
            end // 写完成结束。
            // The table byte count is owned by ipx_regs. DMA completion means
            // every issued read beat has been returned and consumed.
            if(table_mode&&read_finished_q&&read_count==0&&!read_word_valid_q&&idle)finished<=1;
            if(pixel_valid&&pixel_ready)pixel_valid<=0; // 持有像素仅消费一次。
            if(read_pop)begin read_word_q<=read_front[127:0]; // 数据补码直接注册，仅5位长度恢复。
                read_bytes_q<=~read_front[132:128]; // 数据补码直接注册，仅5位长度恢复。
                read_word_valid_q<=1; // 数据补码直接注册，仅5位长度恢复。
                read_byte_q<=0; // 数据补码直接注册，仅5位长度恢复。
            end // 数据补码直接注册，仅5位长度恢复。
            if(consume_byte)begin
                read_word_q <= read_word_q >> 16;
                pixel_data<=expand_rgb565(read_half);
                pixel_valid<=1;
                if({1'b0,read_byte_q}+5'd2==read_bytes_q)begin read_word_valid_q<=0;
                    read_byte_q<=0;
                end else read_byte_q<=read_byte_q+4'd2;
            end // 解包字节结束。
            if(consume_table_byte)begin
                read_word_q<=read_word_q>>8;
                if({1'b0,read_byte_q}+5'd1==read_bytes_q)begin read_word_valid_q<=0;read_byte_q<=0;end
                else read_byte_q<=read_byte_q+1'b1;
            end
            if(result_valid&&result_ready)begin packed_pixel_q<=pack_rgb565(result_data); // 完整像素暂存。
                pack_active_q<=1; // 完整像素暂存。
                write_channel_q<=0; // 完整像素暂存。
            end // 完整像素暂存。
            if(pack_byte)begin // 每拍只改一个字节，少量译码无宽移位器。
                write_word_q<=assembled_word; // 等待时数据保持。
                if(pack_end)write_byte_q<=0; // 高位旧字节由WSTRB保护，不清128位拍寄存器。
                else write_byte_q<=write_byte_q+1'b1; // 高位旧字节由WSTRB保护，不清128位拍寄存器。
                if(write_channel_q==1)begin // 当前像素的B写入后才能接受下一个像素。
                    pack_active_q<=0; // 行尾不跨接padding。
                    write_channel_q<=0; // 行尾不跨接padding。
                    if(packed_x_q==cfg.dst_width-1'b1)packed_x_q<=0; // 行尾不跨接padding。
                    else packed_x_q<=packed_x_q+1'b1; // 行尾不跨接padding。
                end else write_channel_q<=write_channel_q+1'b1; // 下一个RGB字节。
            end // 打包字节结束。
        end // 正常搬运结束。
    end // DMA寄存器结束。
`ifdef SIM_ASSERT // 协议和信用检查。
    always @(posedge clk)if(!clear)begin // 实际发起命令时检查。
        if(read_command&&read_ready&&read_count!=0)$fatal(1,"IPX read credit"); // 当前源完整预留。
        if(write_command&&write_ready&&write_count<{1'b0,write_needed})$fatal(1,"IPX write reservation"); // 禁止AW后缺数据。
        if(consume_byte&&{1'b0,read_byte_q}>=read_bytes_q)$fatal(1,"IPX invalid byte"); // 行尾补齐不可当像素。
    end // 检查结束。
`endif // 仿真断言结束。
endmodule // DMA结束。
