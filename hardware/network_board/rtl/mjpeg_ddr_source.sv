// HDMI is sampled into two DDR RGB888 frames. The JPEG reader pins one
// published slot until every pixel has been accepted, so encoder backpressure
// cannot drop HDMI pixels or allow capture to overwrite the selected frame.
module mjpeg_ddr_source #(
    parameter int SRC_W=1920, SRC_H=1080,
    parameter int FIFO_ADDR_W=11,
    parameter bit AUTO_INPUT_MODE=1'b0,
    parameter logic [31:0] FRAME0_BASE=32'h0340_0000,
    parameter logic [31:0] FRAME1_BASE=32'h0380_0000
)(
    input logic pclk,proc_clk,reset,request,
    input logic hdmi_vs,hdmi_de,
    input logic [7:0] hdmi_r,hdmi_g,hdmi_b,
    output logic [23:0] tdata,
    output logic tvalid,
    input logic tready,
    output logic tlast,tuser,
    output logic overflow_sticky,source_error_sticky,
    output logic frame_done_toggle,frame_available,
    output logic input_is_720p,input_mode_valid,
    output demo_bus_pkg::axi_req_t axi_req,
    input demo_bus_pkg::axi_rsp_t axi_rsp
);
    import demo_bus_pkg::*;
    // Fixed board path: 1080p input capture remains 2/3-sampled to 720p MJPEG.
    localparam int OUT_W=SRC_W*2/3, OUT_H=SRC_H*2/3;
    localparam int FRAME_BEATS=OUT_W*OUT_H*3/16;
    logic capture_valid,published_slot,capture_error,video_lost;
    logic [30:0] published_seq;
    logic frame_lock,locked_slot;
    axi_req_t capture_req;
    gesture_frame_capture #(
        .SRC_W(SRC_W),.SRC_H(SRC_H),.FIFO_ADDR_W(FIFO_ADDR_W),
        .KEEP_TWO_OF_THREE(1'b1),.FAST_PACK(1'b1),.AUTO_INPUT_MODE(AUTO_INPUT_MODE),.LOCK_SKIP_ERROR(1'b0),
        .WRITE_FIFO_AW(5),.WRITE_FIFO_REG_BITS(48)
    ) u_capture(
        .proc_clk(proc_clk),.pclk(pclk),.reset(reset),
        .hdmi_vs(hdmi_vs),.hdmi_de(hdmi_de),
        .hdmi_r(hdmi_r),.hdmi_g(hdmi_g),.hdmi_b(hdmi_b),
        .frame0_base(FRAME0_BASE),.frame1_base(FRAME1_BASE),
        .net_lock(frame_lock),.net_lock_slot(locked_slot),
        .roi_lock(1'b0),.roi_lock_slot(1'b0),.clear_errors(1'b0),
        .frame_valid(capture_valid),.published_slot(published_slot),.published_seq(published_seq),
        .overflow_sticky(overflow_sticky),.error_sticky(capture_error),.video_lost(video_lost),
        .input_is_720p(input_is_720p),.input_mode_valid(input_mode_valid),
        .axi_req(capture_req),.axi_rsp(axi_rsp));

    typedef enum logic [2:0] {IDLE,WAIT_FRAME,AR,DATA,DRAIN,FAILED} state_t;
    state_t state;
    logic slot_q;
    logic [31:0] read_addr;
    logic [19:0] beats_left;
    logic [4:0] burst_left;
    wire [4:0] next_burst=beats_left>=16 ? 5'd16 : 5'(beats_left);
    logic [127:0] word_q;
    logic word_valid;
    logic [3:0] byte_index;
    logic [1:0] component;
    logic [7:0] red_q,green_q;
    logic [15:0] ox,oy;
    logic final_pixel;
    // Reserve a complete burst locally before issuing AR. JPEG/network stalls
    // must never hold an accepted shared-DDR burst open and block other clients.
    wire [127:0] burst_data;
    wire [4:0] burst_count;
    wire burst_push=state==DATA && axi_rsp.rvalid && axi_req.rready;
    wire burst_pop=!word_valid && burst_count!=0;
    ddr_slim_fifo #(.W(128),.DEPTH(16)) u_read_burst(
        .clk(proc_clk),.rst(reset),.push(burst_push),.pop(burst_pop),
        .din(axi_rsp.rdata),.dout(burst_data),.count(burst_count));
    wire [7:0] byte_value=word_q[8*byte_index +:8];
    wire start_now=state==WAIT_FRAME && frame_available;
    assign frame_available=capture_valid && !video_lost;
    assign frame_done_toggle=published_seq[0];
    assign frame_lock=(state==AR || state==DATA || state==DRAIN) || start_now;
    assign locked_slot=start_now ? published_slot : slot_q;

    // The capture owns write channels; the reader owns read channels. They
    // share one existing DDR client without an additional AXI arbitration tier.
    always_comb begin
        axi_req=capture_req;
        axi_req.arid=4'd4;
        axi_req.araddr=read_addr;
        axi_req.arlen=8'(next_burst-1'b1);
        axi_req.arsize=3'd4;
        axi_req.arburst=2'd1;
        axi_req.arvalid=state==AR && burst_count==0;
        axi_req.rready=state==DATA && burst_count<16;
    end
    always_ff @(posedge proc_clk) begin
        if(reset) begin
            state<=IDLE;slot_q<=0;read_addr<=0;beats_left<=0;burst_left<=0;
            word_q<=0;word_valid<=0;byte_index<=0;component<=0;
            red_q<=0;green_q<=0;ox<=0;oy<=0;final_pixel<=0;
            tdata<=0;tvalid<=0;tlast<=0;tuser<=0;source_error_sticky<=0;
        end else begin
            if(burst_pop)begin word_q<=burst_data;word_valid<=1;byte_index<=0;end
            if(tvalid && tready) begin
                tvalid<=0;
                if(final_pixel) state<=IDLE;
            end
            // Serialize little-endian RGB bytes only when the AXI-video
            // output register can advance. Its payload and flags stay stable
            // through arbitrary encoder stalls, including across DDR words.
            if(word_valid && (!tvalid || tready)) begin
                if(byte_index==15) begin word_valid<=0;byte_index<=0;end
                else byte_index<=byte_index+1'b1;
                case(component)
                    0:begin red_q<=byte_value;component<=1;end
                    1:begin green_q<=byte_value;component<=2;end
                    2:begin
                        tdata<={red_q,green_q,byte_value};tvalid<=1;
                        tuser<=ox==0 && oy==0;tlast<=ox==16'(OUT_W-1);
                        final_pixel<=ox==16'(OUT_W-1) && oy==16'(OUT_H-1);
                        component<=0;
                        if(ox==16'(OUT_W-1)) begin ox<=0;oy<=oy+1'b1;end
                        else ox<=ox+1'b1;
                    end
                    default:component<=0;
                endcase
            end
            case(state)
                IDLE:if(request)state<=WAIT_FRAME;
                WAIT_FRAME:if(start_now) begin
                    slot_q<=published_slot;
                    read_addr<=published_slot ? FRAME1_BASE : FRAME0_BASE;
                    beats_left<=20'(FRAME_BEATS);burst_left<=0;
                    ox<=0;oy<=0;component<=0;byte_index<=0;
                    word_valid<=0;tvalid<=0;final_pixel<=0;
                    state<=AR;
                end
                AR:if(axi_req.arvalid && axi_rsp.arready)begin burst_left<=next_burst;state<=DATA;end
                DATA:if(axi_rsp.rvalid && axi_req.rready)begin
                    beats_left<=beats_left-1'b1;
                    if(burst_left!=0)burst_left<=burst_left-1'b1;
                    if(axi_rsp.rresp!=0 || axi_rsp.rlast!=(burst_left==1))
                        source_error_sticky<=1;
                    if(axi_rsp.rlast)begin
                        if(source_error_sticky || axi_rsp.rresp!=0 || burst_left!=1)state<=FAILED;
                        else if(beats_left==1)state<=DRAIN;
                        else begin read_addr<=read_addr+32'd256;state<=AR;end
                    end
                end
                default:;
            endcase
        end
    end
`ifdef SIM_ASSERT
    always @(posedge proc_clk)if(!reset)begin
        if(axi_req.arvalid && axi_rsp.arready && burst_count!=0)
            $fatal(1,"MJPEG read burst issued without complete return reservation");
        if(state==DATA && burst_count==16)
            $fatal(1,"MJPEG accepted burst exceeded local return reservation");
    end
    initial begin
        if(SRC_W%3!=0 || SRC_H%3!=0 || (OUT_W*OUT_H*3)%256!=0)
            $fatal(1,"MJPEG DDR frame must be an aligned 2/3 RGB888 image");
        if(FRAME0_BASE[11:0]!=0 || FRAME1_BASE[11:0]!=0)
            $fatal(1,"MJPEG DDR frame bases must be 4KiB aligned");
    end
`endif
endmodule
