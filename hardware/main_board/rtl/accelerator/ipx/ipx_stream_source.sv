// 协议契约：流入的每个128位字含8个小端RGB565像素；行内有效像素数由流行宽给出，行尾填充不计数。
// 流式契约：转发整行接缝halo及中心区间，忽略行尾填充像素。
// 连续队列隔开NPU行提交与IPX逐像素消费，不增加算术并行度。
// 默认512拍8KB，7块512×20 RAM10；仅指针/有效位复位。
module ipx_stream_source #(parameter ADDR_BITS=9)(
    input logic clk,clear,run,
    input wire ipx_types::config_t cfg,
    input logic word_valid,
    output logic word_ready,
    input logic [127:0] word_data,
    output logic pixel_valid,
    input logic pixel_ready,
    output logic [17:0] pixel_data,
    output wire completed // 完整条带已消费且所有缓存/输出均排空。
);
    import ipx_types::*;
    wire [127:0] returned;
    logic [ADDR_BITS-1:0] read_q,write_q;
    logic [ADDR_BITS:0] count_q;
    logic read_pending_q;
    logic [127:0] word_q;
    logic word_q_valid;
    logic [2:0] pixel_q;
    logic [10:0] row_q,x_base_q; // 流行号与当前字首像素的行内列。
    wire [10:0] st_width=stream_width(cfg); // 流行宽：中心加两侧接缝halo。
    wire [10:0] x_pix=x_base_q+11'(pixel_q); // 当前像素的行内列。
    wire pix_real=x_pix<st_width; // 行尾填充像素不参与转发。
    wire pix_forward=pix_real;
    wire pop=run&&!word_q_valid&&!read_pending_q&&count_q!=0;
    wire push=word_valid&&word_ready;
    wire consume=run&&word_q_valid&&(!pixel_valid||pixel_ready); // 丢弃像素不等待下游。
    assign word_ready=run&&count_q<(1<<ADDR_BITS);
    assign completed=row_q==cfg.height && count_q==0 && !read_pending_q && !word_q_valid && !pixel_valid;
    localparam SLICE=ADDR_BITS==9?20:ADDR_BITS==10?10:5;
    ipx_ram #(.WIDTH(128),.DEPTH_BITS(ADDR_BITS),.SLICE(SLICE)) u_fifo(.clk(clk),
        .read_enable(pop),.write_enable(push),.read_address(read_q),
        .write_address(write_q),.write_data(word_data),.read_data(returned));
    always_ff @(posedge clk)begin
        if(clear)begin
            pixel_valid<=0;word_q_valid<=0;pixel_q<=0;
            read_q<=0;write_q<=0;count_q<=0;read_pending_q<=0;
            row_q<=0;x_base_q<=0;
        end
        else begin
            read_pending_q<=pop;
            if(push)write_q<=write_q+1'b1;
            if(pop)read_q<=read_q+1'b1;
            case({push,pop})
                2'b10:count_q<=count_q+1'b1;
                2'b01:count_q<=count_q-1'b1;
                default:begin end
            endcase
            if(pixel_valid&&pixel_ready)pixel_valid<=0;
            if(read_pending_q)begin word_q<=returned;word_q_valid<=1;pixel_q<=0;end
            if(consume)begin
                if(pix_forward)begin pixel_data<=expand_rgb565(word_q[15:0]);pixel_valid<=1;end
                word_q<=word_q>>16;
                if(pixel_q==3'd7||x_pix>=st_width-1'b1)begin // 当前字结束或本行在字内提前结束。
                    word_q_valid<=0;pixel_q<=0;
                    if(x_pix>=st_width-1'b1)begin x_base_q<=0;row_q<=row_q+1'b1;end // 下一字起新行。
                    else x_base_q<=x_base_q+11'd8;
                end else pixel_q<=pixel_q+3'd1;
            end
        end
    end
`ifdef SIM_ASSERT
    always @(posedge clk)if(!clear)begin
        if(count_q>(1<<ADDR_BITS))$fatal(1,"Stream FIFO overflow");
        if(read_pending_q&&word_q_valid)$fatal(1,"Stream FIFO return overwrites word");
        // A new cfg is captured before LAUNCH clears the previous task's row.
        // Only running-task coordinates belong to the current cfg.
        if(run && row_q>11'(cfg.height))$fatal(1,"Stream source row overflow");
    end
`endif
endmodule
