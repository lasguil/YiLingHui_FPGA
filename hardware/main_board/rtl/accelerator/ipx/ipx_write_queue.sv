/* OPTIMIZATION_NOTE_20261005
 * 资源约束（2026-10-05）：本队列用7块RAM10替换原SRL存储，交换目标为减少XLR。
 * 逻辑容量仍为24拍，不能按物理32地址空间扩大容量；RAM内容不复位，只清指针/有效位。
 * 同步读须先装入front，不能假定push后立即组合可读；front有效后连续pop可每拍一字。
 * 调用者必须按ready/valid握手，背压时队首保持；改成异步FIFO/修改预取须重验burst与背压。
 * 累计A/B/C压缩省6块RAM10，因此整套优化相对原版净增加1块RAM10，DSP仍118。
 * 详见 docs/OPTIMIZATION_CONSTRAINTS.md。
 */
// 24-word output queue, synchronous RAM with a held first-word output.
// Input is complemented by the DMA packer; RAM output restores the payload.
module ipx_write_queue(
    input logic clk,clear,push,pop,
    input logic [131:0] data_in,
    output wire [131:0] data_out,
    output wire ready,valid,
    output wire [4:0] count
);
    logic [4:0] read_q,write_q,stored_q;
    logic front_valid_q;
    wire read_word = !clear && stored_q != 0 && (!front_valid_q || pop);
    wire [131:0] returned;
    assign count = stored_q + 5'(front_valid_q);
    assign ready = count < 24;
    assign valid = front_valid_q;
    assign data_out = ~returned;
    // Depth32 is a logical address subset of seven physical512x20 blocks.
    ipx_ram #(.WIDTH(132),.DEPTH_BITS(9),.SLICE(20)) u_storage(
        .clk(clk),.read_enable(read_word),.write_enable(push && !clear),
        .read_address({4'd0,read_q}),.write_address({4'd0,write_q}),
        .write_data(data_in),.read_data(returned));
    always_ff @(posedge clk) begin
        if(clear) begin
            read_q <= 0;write_q <= 0;stored_q <= 0;front_valid_q <= 0;
        end else begin
            if(push) write_q <= write_q + 1'b1;
            if(read_word) read_q <= read_q + 1'b1;
            case({push,read_word})
                2'b10: stored_q <= stored_q + 1'b1;
                2'b01: stored_q <= stored_q - 1'b1;
                default: begin end
            endcase
            if(read_word) front_valid_q <= 1;
            else if(pop) front_valid_q <= 0;
        end
    end
`ifdef SIM_ASSERT
    always @(posedge clk) if(!clear) begin
        if(push && !ready) $fatal(1,"RAM output queue overflow");
        if(pop && !valid) $fatal(1,"RAM output queue underflow");
        if(count > 24) $fatal(1,"RAM output queue capacity");
    end
`endif
endmodule
