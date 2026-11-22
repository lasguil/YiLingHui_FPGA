// Reserve one complete 64-beat NPU burst, independently of consumer stalls.
// A registered front beat breaks the DDR-to-NPU combinational return path.
// It preserves RVALID/payload under backpressure while later beats enter RAM.
// Production NPU keeps one burst outstanding and never exceeds 64 beats.
module demo_npu_read_buffer(
    input logic clk,reset,
    input demo_bus_pkg::axi_req_t up_req,
    output demo_bus_pkg::axi_rsp_t up_rsp,
    output demo_bus_pkg::axi_req_t down_req,
    input demo_bus_pkg::axi_rsp_t down_rsp
);
    wire full,empty,reset_busy;
    wire [134:0] fifo_front;
    wire [134:0] incoming={down_rsp.rid,down_rsp.rresp,down_rsp.rlast,down_rsp.rdata};
    logic [134:0] held_front;
    logic front_valid;
    logic [6:0] queued;
    wire down_fire=down_rsp.rvalid && down_req.rready;
    wire up_fire=up_rsp.rvalid && up_req.rready;
    wire capture_front=down_fire && queued==0 && (!front_valid || up_req.rready);
    wire push=down_fire && !capture_front;
    wire pop=up_fire && !front_valid && queued!=0;
    always_comb begin
        down_req=up_req;
        down_req.arvalid=up_req.arvalid && !reset_busy && !reset;
        // The shared DDR return never depends on the consumer's RREADY.
        down_req.rready=!full && !reset_busy && !reset;
        up_rsp=down_rsp;
        up_rsp.arready=down_rsp.arready && !reset_busy && !reset;
        {up_rsp.rid,up_rsp.rresp,up_rsp.rlast,up_rsp.rdata}=
            front_valid ? held_front : fifo_front;
        up_rsp.rvalid=!reset && !reset_busy &&
            (front_valid || (queued!=0 && !empty));
    end
    always_ff @(posedge clk)begin
        if(reset)begin front_valid<=0;queued<=0;end
        else begin
            if(front_valid && up_fire)front_valid<=0;
            if(capture_front)begin held_front<=incoming;front_valid<=1;end
            case({push,pop})
                2'b10:queued<=queued+1'b1;
                2'b01:queued<=queued-1'b1;
                default:begin end
            endcase
        end
    end
    efx_fifo_wrapper #(.SYNC_CLK(1),.MODE("FWFT"),.DEPTH(64),.DATA_WIDTH(135),
        .ASYM_WIDTH_RATIO(4),.OPTIONAL_FLAGS(0)) u_return(
        .clk_i(clk),.wr_clk_i(1'b0),.rd_clk_i(1'b0),
        .a_rst_i(reset),.a_wr_rst_i(reset),.a_rd_rst_i(reset),
        .wr_en_i(push),.rd_en_i(pop),.wdata(incoming),.rdata(fifo_front),
        .full_o(full),.empty_o(empty),.rst_busy(reset_busy),
        .almost_full_o(),.prog_full_o(),.overflow_o(),.wr_ack_o(),
        .datacount_o(),.wr_datacount_o(),.almost_empty_o(),.prog_empty_o(),
        .underflow_o(),.rd_valid_o(),.rd_datacount_o());
`ifndef SYNTHESIS
    logic client_pending;
    logic stalled;
    logic [134:0] previous;
    always @(posedge clk)begin
        if(reset)begin client_pending<=0;stalled<=0;end
        else begin
            if(stalled && (!up_rsp.rvalid ||
                {up_rsp.rid,up_rsp.rresp,up_rsp.rlast,up_rsp.rdata}!==previous))
                $fatal(1,"NPU buffered R changed under backpressure");
            stalled<=up_rsp.rvalid && !up_req.rready;
            previous<={up_rsp.rid,up_rsp.rresp,up_rsp.rlast,up_rsp.rdata};
            if(up_fire && up_rsp.rlast)client_pending<=0;
            if(up_req.arvalid && up_rsp.arready)begin
                if(client_pending && !(up_fire && up_rsp.rlast))$fatal(1,"NPU issued a second buffered read");
                if(up_req.arlen>=64)$fatal(1,"NPU read exceeds reserved 64 beats");
                client_pending<=1;
            end
        end
    end
`endif
endmodule
