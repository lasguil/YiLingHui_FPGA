// 协议契约：一次start提供一对真实RGB565行的两个16字节对齐地址、真实像素宽和Stem目标行号。
// 每段最多128像素即256字节：先burst读上行并写D前端480..503原有空闲字，再burst读下行对应段。
// 上行每个128位DDR拍写一个D字的低半，高半接零；只用既有D DMA写口，不新建FIFO或RAM。
// 下行DDR拍直通RGB配对器；配对器在segment_start沿锁存段首Stem列及配对数，按逻辑窗口消费。
// segment_consumed表示本段全部上/下行字节已用于成窗且不再引用D暂存；仍须等DDR读响应结束才覆写下一段。
// 两条行地址按256字节递增，不做stride乘法；最后段按真实宽裁剪，宽必须为四的倍数且不大于1920。
// 地址计数只在整个段交付后推进，等待read_ready/D写ready/下行ready时保持原字段与DATA。
// done只在最后段消费与DDR响应都结束后单拍通知；error独立失败脉冲，不能把FIFO空当行完成。
// abort停止发起新命令并丢弃本地状态，AXI后端仍负责排空已接受burst；新start须等待read_ready恢复。
// 此模块只有地址、长度和有效控制；无RAM、DSP及宽数据寄存器，DDR跨4KiB拆分由共用AXI后端完成。
module ngm_input_dma( // RGB上下行分段交替burst控制。
    input logic clk,reset,abort, // NPU时钟、安全复位与抢占。
    input logic start_valid, // 一对真实输入行命令。
    output logic start_ready, // 无旧行且读端空闲。
    input logic [31:0] start_top_address,start_bottom_address, // 上/下RGB行首字节地址。
    input logic [10:0] start_width, // 真实RGB像素宽，4..1920且为四的倍数。
    input logic [10:0] start_stem_row, // 本行Stem结果的真实行号。
    output logic busy,done,error, // 行占用与互斥终结脉冲。
    output logic read_valid, // 上/下段字节区间请求。
    input logic read_ready, // 共用AXI读后端接受命令。
    output logic [31:0] read_address, // 当前段DDR首地址。
    output logic [15:0] read_length, // 当前段有效字节数，最大256。
    input logic read_data_valid, // DDR读拍有效。
    output logic read_data_ready, // 当前消费者可以接收拍。
    input logic [127:0] read_data, // DDR原始RGB字节。
    input logic [15:0] read_keep, // 末拍有效字节屏蔽。
    input logic read_last,read_done,read_error, // 当前命令末拍、响应终结和错误。
    output logic dma_valid, // 上行拍写D原有空闲尾区。
    input logic dma_ready, // 存储子系统接受该拍。
    output logic [10:0] dma_row, // D提交输入段时使用Stem行标签。
    output logic [7:0] dma_word, // 段内拍号0..23。
    output logic [255:0] dma_data, // 低128位有效，高半为零，无新增配对暂存。
    output logic dma_last, // 上行段末拍真正握手时提交。
    output logic segment_start, // 上行段已完整提交，下行开始前的单拍提示。
    output logic [9:0] segment_x, // 本段Stem首列，等于RGB首列除二。
    output logic [6:0] segment_pairs, // 本段上下行两像素配对数1..64。
    input logic segment_consumed, // 配对器已用完本段且可覆写D暂存。
    output logic bottom_valid, // 下行原始DDR拍。
    input logic bottom_ready, // RGB配对器可消费。
    output logic [127:0] bottom_data, // 直接使用AXI后端保持的数据。
    output logic [15:0] bottom_keep // 当前下行拍有效字节。
); // 输入分段DMA接口结束。
    typedef enum logic [2:0] {IDLE,TOP_OFFER,TOP_READ,BOTTOM_OFFER,BOTTOM_READ,WAIT_PAIR} state_t; // 一次只发一条读命令。
    state_t state_q; // 窄行/段状态。
    logic [31:0] top_q,bottom_q;logic [10:0] left_q;logic [7:0] pixels_q; // 两个段地址与剩余像素。
    logic [4:0] word_q;logic consumed_q,bottom_done_q; // 上行拍号及两类完成事实。
    assign busy=state_q!=IDLE;assign start_ready=state_q==IDLE && read_ready && !abort; // AXI安全静止后才接新行。
    assign read_valid=(state_q==TOP_OFFER || state_q==BOTTOM_OFFER) && !abort; // 请求保持至后端接受。
    assign read_address=state_q==TOP_OFFER ? top_q : bottom_q; // 窄地址选择。
    assign read_length={7'b0,pixels_q,1'b0}; // 固定乘三移位加法。
    assign read_data_ready=!abort && (state_q==TOP_READ ? dma_ready : state_q==BOTTOM_READ && bottom_ready); // 不吞无人消费的DDR拍。
    assign dma_valid=state_q==TOP_READ && read_data_valid && !abort; // 上行读拍直达原DMA写口。
    assign dma_word={3'b0,word_q};assign dma_data={128'b0,read_data};assign dma_last=read_last; // 不为上行新增128位暂存。
    assign bottom_valid=state_q==BOTTOM_READ && read_data_valid && !abort;assign bottom_data=read_data;assign bottom_keep=read_keep; // 下行拍直接交成窗。
    assign segment_pairs=pixels_q[7:1]; // 每个Stem点消费同列两像素，不做除法。
    always_ff @(posedge clk)begin // 没有宽数据寄存器。
        if(reset)begin // 安全工作复位。
            state_q<=IDLE;top_q<=0;bottom_q<=0;left_q<=0;pixels_q<=0;word_q<=0;dma_row<=0;segment_x<=0; // 清窄配置。
            consumed_q<=0;bottom_done_q<=0;done<=0;error<=0;segment_start<=0; // 无待处理段。
        end else begin // 正常段控制。
            done<=0;error<=0;segment_start<=0; // 三类通知只维持一拍。
            if(abort)begin state_q<=IDLE;consumed_q<=0;bottom_done_q<=0;end // 总线排空由AXI后端继续完成。
            else begin // 不中止时执行同一行。
                if(segment_consumed)consumed_q<=1; // 不要求成窗与DDR响应在同一拍完成。
                case(state_q) // 上行先提交再读取下行。
                    IDLE:if(start_valid && start_ready)begin // 接收一对真实输入行。
                        top_q<=start_top_address;bottom_q<=start_bottom_address;left_q<=start_width;pixels_q<=start_width>128 ? 8'd128 : 8'(start_width); // 截取首段。
                        dma_row<=start_stem_row;segment_x<=0;word_q<=0;consumed_q<=0;bottom_done_q<=0;state_q<=TOP_OFFER; // 新行从第零列开始。
                    end // 新行接收结束。
                    TOP_OFFER:if(read_ready)state_q<=TOP_READ; // 读上行段。
                    TOP_READ:begin // 上行拍按DDR顺序写D。
                        if(dma_valid && dma_ready)word_q<=word_q+1'b1; // 一拍对应D一个已有字。
                        if(read_done)begin // 上行命令读响应结束。
                            if(read_error)begin error<=1;state_q<=IDLE;end // 不使用带错的输入段。
                            else begin segment_start<=1;state_q<=BOTTOM_OFFER;end // 完整提交后启动对应下行。
                        end // 上行响应结束。
                    end // 上行段接收结束。
                    BOTTOM_OFFER:if(read_ready)state_q<=BOTTOM_READ; // 开始相同列范围的下行burst。
                    BOTTOM_READ:if(read_done)begin // 下行最后拍已消费，但配对器可能还有字节待成窗。
                        if(read_error)begin error<=1;state_q<=IDLE;end // 独立失败终结。
                        else begin bottom_done_q<=1;state_q<=WAIT_PAIR;end // 等全部配对消费者。
                    end // 下行读取结束。
                    WAIT_PAIR:if(bottom_done_q && (consumed_q || segment_consumed))begin // 双重完成后才复用输入暂存。
                        if(left_q<=11'd128)begin done<=1;state_q<=IDLE;end // 真实宽全部交付。
                        else begin // 下一段保持RGB565字节地址对齐。
                            left_q<=left_q-11'd128;pixels_q<=left_q>11'd256 ? 8'd128 : 8'(left_q-11'd128); // 裁最后一段。
                            top_q<=top_q+32'd256;bottom_q<=bottom_q+32'd256;segment_x<=segment_x+10'd64;word_q<=0; // 每次完整前进128像素。
                            consumed_q<=0;bottom_done_q<=0;state_q<=TOP_OFFER; // 原有24字重新使用。
                        end // 下一段配置结束。
                    end // 当前段消费结束。
                    default:state_q<=IDLE; // 确定状态恢复。
                endcase // 段状态机结束。
            end // 非中止路径结束。
        end // 非复位路径结束。
    end // 输入分段窄寄存器结束。
`ifdef SIM_ASSERT // 非法软件描述符不增加硬件数据缓存。
    always @(posedge clk)if(!reset)begin // 输入契约证伪。
        if(start_valid && start_ready && (start_width<4 || start_width>1920 || start_width[1:0]!=0 || start_top_address[3:0]!=0 || start_bottom_address[3:0]!=0))$fatal(1,"INPUT invalid row descriptor"); // 固定模型几何与AXI对齐。
        if(segment_consumed && !(state_q==BOTTOM_OFFER || state_q==BOTTOM_READ || state_q==WAIT_PAIR))$fatal(1,"INPUT unsolicited segment consumed"); // 不能提前覆盖尚未保存的上行段。
        if(dma_valid && dma_ready && word_q>=24)$fatal(1,"INPUT chunk exceeds D free words"); // 不覆盖前端特征行。
    end // 仿真协议检查结束。
`endif // 默认回归启用。
endmodule // 上下行分段burst控制结束。
