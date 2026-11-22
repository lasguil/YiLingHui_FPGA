// Locked DDR RGB888 frame -> nearest-neighbour RGB565 -> asynchronous stream.
// A request and release use independent toggles. Accepted AXI bursts are always
// drained before cancelling; source ownership survives downstream backpressure.
module gesture_net_reader #(
    parameter int SRC_W=640, SRC_H=360, OUT_W=240, OUT_H=136,
    parameter int FIFO_AW=9
)(
    input logic proc_clk, net_clk, reset,
    input logic frame_valid, video_lost, published_slot,
    input logic [30:0] published_seq,
    input logic [31:0] frame0_base, frame1_base,
    output logic net_lock, net_lock_slot,
    output demo_bus_pkg::axi_req_t axi_req,
    input demo_bus_pkg::axi_rsp_t axi_rsp,
    input logic frame_begin, frame_end, pixel_pop,
    output logic available, busy, error,
    output logic [15:0] pixel_data,
    output logic pixel_valid,
    output logic [31:0] frame_count
);
    import demo_bus_pkg::*;
    (* async_reg="true" *) logic [1:0] proc_reset_pipe,net_reset_pipe;
    always_ff @(posedge proc_clk or posedge reset)
        if(reset)proc_reset_pipe<=2'b11;else proc_reset_pipe<={proc_reset_pipe[0],1'b0};
    always_ff @(posedge net_clk or posedge reset)
        if(reset)net_reset_pipe<=2'b11;else net_reset_pipe<={net_reset_pipe[0],1'b0};
    wire proc_reset=proc_reset_pipe[1],net_reset=net_reset_pipe[1];
    localparam int ROW_BYTES=SRC_W*3, ROW_BEATS=(ROW_BYTES+15)/16;
    localparam int ROW_AW=$clog2(ROW_BEATS+1);
    localparam int X_STEP=SRC_W/OUT_W, X_REM=SRC_W%OUT_W;
    localparam int Y_STEP=SRC_H/OUT_H, Y_REM=SRC_H%OUT_H;
    typedef enum logic [2:0] {IDLE,AR,DATA,PIX_ADDR,PIX_EMIT,FINISH} state_t;
    state_t state;
    logic req_toggle, end_toggle;
    (* async_reg="true" *) logic req_meta,req_sync,end_meta,end_sync;
    logic req_seen,end_seen,cancel;
    logic locked_slot,read_error;
    logic have_selected;
    logic [30:0] selected_seq;
    logic [31:0] row_base;
    logic [ROW_AW-1:0] word_offset;
    logic [4:0] beat,burst_beats;
    logic [15:0] ox,oy,x_phase,y_phase,byte_pos;
    logic [31:0] read_addr;
    logic [8:0] page_beats;
    logic [4:0] next_burst;
    logic fifo_full,fifo_empty,fifo_wr;
    logic [15:0] fifo_wdata;
    (* syn_ramstyle="block_ram" *) logic [127:0] row0[0:(1<<ROW_AW)-1];
    (* syn_ramstyle="block_ram" *) logic [127:0] row1[0:(1<<ROW_AW)-1];
    logic [127:0] q0,q1;
    wire [143:0] aligned_rgb={q1[15:0],q0} >> (8*byte_pos[3:0]);
    wire request_pending=req_sync!=req_seen;
    wire release_pending=end_sync!=end_seen;
    wire start_now=state==IDLE && request_pending && frame_valid;
    // The start-cycle lock protects a simultaneous capture SOF/slot choice.
    assign net_lock=(state!=IDLE && state!=FINISH) || start_now;
    assign net_lock_slot=state==IDLE ? published_slot : locked_slot;
    assign read_addr=row_base+32'(word_offset)*16;
    always_comb begin
        page_beats=9'((4096-{20'd0,read_addr[11:0]})>>4);
        next_burst=5'(ROW_BEATS-int'(word_offset));
        if(ROW_BEATS-int'(word_offset)>16)next_burst=16;
        if(page_beats<9'(next_burst))next_burst=5'(page_beats);
        axi_req='0;
        axi_req.araddr=read_addr;
        axi_req.arlen=8'(next_burst-1'b1);
        axi_req.arsize=3'd4;axi_req.arburst=2'd1;
        axi_req.arvalid=state==AR;
        axi_req.rready=state==DATA;
        fifo_wr=state==PIX_EMIT && !fifo_full && !cancel && !release_pending;
        fifo_wdata={aligned_rgb[7:3],aligned_rgb[15:10],aligned_rgb[23:19]};
    end
    // Two synchronous copies supply the adjacent word for a crossing RGB triplet.
    always_ff @(posedge proc_clk) begin
        if(state==DATA && axi_rsp.rvalid)begin
            row0[ROW_AW'(word_offset+beat)]<=axi_rsp.rdata;
            row1[ROW_AW'(word_offset+beat)]<=axi_rsp.rdata;
        end
        q0<=row0[ROW_AW'(byte_pos>>4)];
        q1<=row1[ROW_AW'((byte_pos>>4)+1)];
    end
    gesture_async_fifo #(.DATA_W(16),.ADDR_W(FIFO_AW)) u_pixels(
        .arst(reset),.wclk(proc_clk),.wr_en(fifo_wr),.wr_data(fifo_wdata),
        .full(fifo_full),.rclk(net_clk),.rd_en(pixel_pop),
        .rd_data(pixel_data),.empty(fifo_empty));
    assign pixel_valid=!fifo_empty;
    always_ff @(posedge net_clk or posedge net_reset)begin
        if(net_reset)begin req_toggle<=0;end_toggle<=0;end
        else begin
            if(frame_begin)req_toggle<=!req_toggle;
            if(frame_end)end_toggle<=!end_toggle;
        end
    end
    always_ff @(posedge proc_clk or posedge proc_reset)begin
        if(proc_reset)begin req_meta<=0;req_sync<=0;end_meta<=0;end_sync<=0;end
        else begin req_meta<=req_toggle;req_sync<=req_meta;end_meta<=end_toggle;end_sync<=end_meta;end
    end
    always_ff @(posedge proc_clk or posedge proc_reset)begin
        if(proc_reset)begin
            state<=IDLE;req_seen<=0;end_seen<=0;cancel<=0;read_error<=0;
            locked_slot<=0;have_selected<=0;selected_seq<=0;row_base<=0;word_offset<=0;beat<=0;burst_beats<=0;
            ox<=0;oy<=0;x_phase<=0;y_phase<=0;byte_pos<=0;
        end else begin
            if(release_pending)begin end_seen<=end_sync;cancel<=1;end
            case(state)
                IDLE:begin
                    read_error<=0;cancel<=0;
                    if(request_pending)begin
                        req_seen<=req_sync;locked_slot<=published_slot;
                        have_selected<=1;selected_seq<=published_seq;
                        row_base<=published_slot ? frame1_base:frame0_base;
                        word_offset<=0;ox<=0;oy<=0;x_phase<=0;y_phase<=0;byte_pos<=0;
                        if(frame_valid)state<=AR;
                        else begin read_error<=1;state<=FINISH;end
                    end
                end
                AR:if(axi_rsp.arready)begin beat<=0;burst_beats<=next_burst;state<=DATA;end
                DATA:if(axi_rsp.rvalid)begin
                    if(axi_rsp.rresp!=0 || axi_rsp.rlast!=(beat==burst_beats-1))read_error<=1;
                    if(axi_rsp.rlast)begin
                        if(cancel||release_pending)state<=IDLE;
                        else if(read_error||axi_rsp.rresp!=0||beat!=burst_beats-1)begin read_error<=1;state<=FINISH;end
                        else if(int'(word_offset)+int'(burst_beats)>=ROW_BEATS)state<=PIX_ADDR;
                        else begin word_offset<=word_offset+ROW_AW'(burst_beats);state<=AR;end
                    end else beat<=beat+1'b1;
                end
                PIX_ADDR:if(cancel||release_pending)state<=IDLE;else state<=PIX_EMIT;
                PIX_EMIT:if(cancel||release_pending)state<=IDLE;
                    else if(!fifo_full)begin
                        if(ox==OUT_W-1)begin
                            ox<=0;byte_pos<=0;x_phase<=0;word_offset<=0;
                            if(oy==OUT_H-1)state<=FINISH;
                            else begin
                                oy<=oy+1'b1;
                                if(int'(y_phase)+Y_REM>=OUT_H)begin
                                    y_phase<=16'(int'(y_phase)+Y_REM-OUT_H);
                                    row_base<=row_base+32'(ROW_BYTES*(Y_STEP+1));
                                end else begin y_phase<=y_phase+16'(Y_REM);row_base<=row_base+32'(ROW_BYTES*Y_STEP);end
                                state<=AR;
                            end
                        end else begin
                            ox<=ox+1'b1;
                            if(int'(x_phase)+X_REM>=OUT_W)begin
                                x_phase<=16'(int'(x_phase)+X_REM-OUT_W);byte_pos<=byte_pos+16'(3*(X_STEP+1));
                            end else begin x_phase<=x_phase+16'(X_REM);byte_pos<=byte_pos+16'(3*X_STEP);end
                            state<=PIX_ADDR;
                        end
                    end
                FINISH:if(cancel||release_pending)state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
    (* async_reg="true" *) logic available_meta,available_sync,busy_meta,busy_sync,error_meta,error_sync;
    (* async_reg="true" *) logic [30:0] seq_meta,seq_sync;
    logic [30:0] seq_gray;
    always_ff @(posedge proc_clk or posedge proc_reset)
        if(proc_reset)seq_gray<=0;else seq_gray<=published_seq^(published_seq>>1);
    always_ff @(posedge net_clk or posedge net_reset)begin
        if(net_reset)begin
            available_meta<=0;available_sync<=0;busy_meta<=0;busy_sync<=0;
            error_meta<=0;error_sync<=0;seq_meta<=0;seq_sync<=0;
        end else begin
            available_meta<=frame_valid&&!video_lost&&(!have_selected||published_seq!=selected_seq);available_sync<=available_meta;
            busy_meta<=state!=IDLE;busy_sync<=busy_meta;
            error_meta<=read_error;error_sync<=error_meta;
            seq_meta<=seq_gray;seq_sync<=seq_meta;
        end
    end
    assign available=available_sync&&!busy_sync&&!error_sync;
    assign busy=busy_sync;assign error=error_sync;
    always_comb begin
        frame_count='0;
        for(integer i=30;i>=0;i=i-1)frame_count[i]=^ (seq_sync>>i);
    end
endmodule
