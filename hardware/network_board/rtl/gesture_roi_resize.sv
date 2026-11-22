// DDR-resident square ROI -> 224x224 C32 RGB input tensor.
// Input frame is tightly packed RGB888 at 640x360. Each output pixel is
// {R,G,B,29*zero_point}; with the current first-layer zero point (0), the
// 32-byte pixel is represented by two 128-bit DDR beats. Coordinates are
// signed pixel origins; out-of-frame samples replicate the nearest edge.
module gesture_roi_resize #(
    parameter int SRC_W=640,
    parameter int SRC_H=360,
    parameter int ROW_BYTES=SRC_W*3,
    parameter int OUT_SIZE=224,
    parameter int FIFO_ADDR_W=6,
    parameter int WATCHDOG_CYCLES=18_000_000,
    parameter logic [31:0] DEFAULT_FRAME0=32'h0300_0000,
    parameter logic [31:0] DEFAULT_FRAME1=32'h0310_0000,
    parameter logic [31:0] DEFAULT_INPUT=32'h0212_9000
) (
    input  logic                    clk,
    input  logic                    reset,
    input  wire demo_bus_pkg::csr_req_t csr_req,
    output demo_bus_pkg::csr_rsp_t  csr_rsp,
    input  logic                    frame_valid,
    input  logic                    published_slot,
    input  logic [30:0]             published_seq,
    input  logic                    capture_overflow,
    input  logic                    capture_error,
    input  logic                    capture_video_lost,
    output logic                    clear_capture_errors,
    output logic                    roi_lock,
    output logic                    roi_lock_slot,
    output logic [31:0]             frame0_base,
    output logic [31:0]             frame1_base,
    output demo_bus_pkg::axi_req_t  axi_req,
    input  wire demo_bus_pkg::axi_rsp_t axi_rsp,
    output logic                    busy,
    output logic                    done_sticky,
    output logic                    error_sticky,
    output logic [30:0]             selected_seq
);
    import demo_bus_pkg::*;
    localparam int SOURCE_BEATS = ROW_BYTES/16;
    localparam int SOURCE_WORD_AW = (SOURCE_BEATS<=2) ? 1 : $clog2(SOURCE_BEATS);
    localparam int OUTPUT_ROW_BYTES = OUT_SIZE*32;
    localparam int OUTPUT_BEATS = (OUT_SIZE*OUT_SIZE*32)/16;
    localparam logic [8:0] OUT_DIV = 9'(OUT_SIZE);

    logic signed [31:0] roi_x_reg, roi_y_reg;
    logic [15:0] roi_side_reg;
    logic [31:0] input_base_reg;
    logic signed [31:0] roi_x_q, roi_y_q;
    logic [15:0] roi_side_q;
    logic [15:0] side_whole;
    logic [8:0] side_rem;
    logic [15:0] x_whole, y_whole;
    logic [8:0] x_frac, y_frac;
    logic [7:0] out_x, out_y;
    logic [9:0] source_x;
    logic [8:0] source_y_q;
    logic [31:0] row_offset_q;
    logic [31:0] source_frame_base;
    logic [31:0] selected_base_q;
    logic [31:0] selected_word;
    logic [31:0] read_addr;
    logic [8:0] read_total_beats;
    logic [4:0] burst_beats;
    logic [4:0] burst_left;
    logic [31:0] write_addr;
    logic [16:0] write_beats_done;
    logic [4:0] write_burst_beat;
    // Two synchronous-read copies keep the scanline in block RAM: one copy
    // supplies the current 128-bit word and the other the adjacent word for
    // RGB triplets that straddle a 16-byte boundary.
    logic [127:0] line_buf_lo [0:SOURCE_BEATS-1];
    logic [127:0] line_buf_hi [0:SOURCE_BEATS-1];
    logic [127:0] line_word_lo_q, line_word_hi_q;
    logic [11:0] source_byte_index;
    logic [SOURCE_WORD_AW-1:0] source_word_index, source_word_next;
    logic [4:0] source_byte_lane;
    logic [255:0] source_window;

    logic out_fifo_wr, out_fifo_rd, out_fifo_full, out_fifo_empty;
    logic [127:0] out_fifo_wdata, out_fifo_rdata;
    logic [FIFO_ADDR_W:0] out_fifo_count;
    gesture_sync_fifo #(.DATA_W(128),.ADDR_W(FIFO_ADDR_W)) u_out_fifo (
        .clk(clk),.reset(reset),.wr_en(out_fifo_wr),.wr_data(out_fifo_wdata),
        .full(out_fifo_full),.rd_en(out_fifo_rd),.rd_data(out_fifo_rdata),
        .empty(out_fifo_empty),.count(out_fifo_count));

    typedef enum logic [3:0] {
        R_IDLE,R_ROW_CLAMP,R_ROW_OFFSET,R_ROW_BASE,R_ADDR,R_DATA,
        R_PREFETCH,R_FIRST,R_SECOND,R_DRAIN,R_FAIL_DRAIN
    } roi_state_t;
    typedef enum logic [1:0] {W_IDLE,W_DATA,W_RESP} write_state_t;
    roi_state_t state;
    write_state_t wstate;
    logic [23:0] rgb_sample;
    logic fail_pending;
    logic [24:0] progress_watchdog;
    logic timeout_seen;
    logic [31:0] csr_rdata;
    logic csr_error;
    logic roi_lock_slot_q;
    logic roi_start_accept;
    logic [8:0] page_beats;
    logic [4:0] next_burst;
    logic signed [31:0] x_unclamped;
    logic signed [31:0] row_unclamped;
    logic [8:0] row_clamped;

    assign source_frame_base = selected_base_q;
    assign x_unclamped = roi_x_q + $signed({16'd0,x_whole});
    always_comb begin
        if (x_unclamped < 0) source_x=0;
        else if (x_unclamped >= SRC_W) source_x=SRC_W-1;
        else source_x=x_unclamped[9:0];
        row_unclamped = roi_y_q + $signed({16'd0,y_whole});
        if (row_unclamped < 0) row_clamped=0;
        else if (row_unclamped >= SRC_H) row_clamped=SRC_H-1;
        else row_clamped=row_unclamped[8:0];
        source_byte_index=12'(source_x*3);
        source_word_index=source_byte_index[11:4];
        source_word_next=(source_word_index<SOURCE_BEATS-1) ?
                         source_word_index+1'b1 : source_word_index;
        source_byte_lane={1'b0,source_byte_index[3:0]};
        source_window={line_word_hi_q,line_word_lo_q};
        rgb_sample={source_window[(source_byte_lane*8)+:8],
                    source_window[((source_byte_lane+5'd1)*8)+:8],
                    source_window[((source_byte_lane+5'd2)*8)+:8]};
    end

    assign page_beats = 9'd256 - {1'b0,read_addr[11:4]};
    always_comb begin
        if (SOURCE_BEATS-read_total_beats >= 16) next_burst=5'd16;
        else next_burst=5'(SOURCE_BEATS-read_total_beats);
        if (page_beats < {4'd0,next_burst}) next_burst=5'(page_beats);
        burst_beats=next_burst;
    end

    // Single-cycle CSR interface. The parent decodes 0xf8102000 and routes
    // its 4 KiB window here through the existing APB CDC bridge.
    always_comb begin
        csr_error=1'b0;
        csr_rdata=32'hdead_beef;
        case(csr_req.address[7:0])
            8'h00: csr_rdata={31'd0,busy};
            8'h04: csr_rdata={25'd0,capture_video_lost,capture_error,capture_overflow,error_sticky,done_sticky,busy,frame_valid};
            8'h08: csr_rdata=frame0_base;
            8'h0c: csr_rdata=frame1_base;
            8'h10: csr_rdata={published_seq,published_slot};
            8'h14: csr_rdata=roi_x_reg;
            8'h18: csr_rdata=roi_y_reg;
            8'h1c: csr_rdata={16'd0,roi_side_reg};
            8'h20: csr_rdata=input_base_reg;
            8'h24: csr_rdata={selected_seq,roi_lock_slot_q};
            default: csr_error=csr_req.valid;
        endcase
        if(csr_req.write && (csr_req.address[7:0]==8'h10 ||
           csr_req.address[7:0]==8'h24)) csr_error=1'b1;
    end
    always_comb begin
        csr_rsp='0;
        csr_rsp.ready=1'b1;
        csr_rsp.error=csr_error;
        csr_rsp.rdata=csr_rdata;
    end
    always_comb begin
        roi_start_accept=csr_req.valid && csr_req.write &&
            csr_req.address[7:0]==8'h00 && csr_req.wdata[0] && !busy &&
            frame_valid && roi_side_reg!=0 && roi_side_reg<=1024 &&
            input_base_reg[11:0]==0 && frame0_base[11:0]==0 && frame1_base[11:0]==0;
        roi_lock=busy || roi_start_accept;
        roi_lock_slot=busy ? roi_lock_slot_q : published_slot;
    end

    logic [127:0] first_beat;
    always_comb begin
        first_beat='0;
        first_beat[7:0]=rgb_sample[23:16];
        first_beat[15:8]=rgb_sample[15:8];
        first_beat[23:16]=rgb_sample[7:0];
        out_fifo_wr=0;
        out_fifo_wdata='0;
        if(!out_fifo_full && out_fifo_count <= ((1<<FIFO_ADDR_W)-2)) begin
            if(state==R_FIRST) begin out_fifo_wr=1;out_fifo_wdata=first_beat;end
            else if(state==R_SECOND) begin out_fifo_wr=1;out_fifo_wdata='0;end
        end
        out_fifo_rd=((wstate==W_DATA) && !out_fifo_empty && axi_rsp.wready) ||
                    ((state==R_FAIL_DRAIN) && (wstate==W_IDLE) &&
                     (out_fifo_count<16) && !out_fifo_empty);
    end

    always_comb begin
        axi_req='0;
        axi_req.arid=4'd3;
        axi_req.araddr=read_addr;
        axi_req.arlen=8'(burst_beats-1'b1);
        axi_req.arsize=3'd4;
        axi_req.arburst=2'd1;
        axi_req.arvalid=(state==R_ADDR) && !fail_pending;
        axi_req.rready=(state==R_DATA);
        axi_req.awid=4'd3;
        axi_req.awaddr=write_addr;
        axi_req.awlen=8'd15;
        axi_req.awsize=3'd4;
        axi_req.awburst=2'd1;
        axi_req.awvalid=(wstate==W_IDLE) && (out_fifo_count>=16);
        axi_req.wdata=out_fifo_rdata;
        axi_req.wstrb=16'hffff;
        axi_req.wlast=(write_burst_beat==15);
        axi_req.wvalid=(wstate==W_DATA) && !out_fifo_empty;
        axi_req.bready=(wstate==W_RESP);
    end

    always_ff @(posedge clk) begin
        if(!reset && state==R_PREFETCH) begin
            line_word_lo_q<=line_buf_lo[source_word_index];
            line_word_hi_q<=line_buf_hi[source_word_next];
        end
        if(reset) begin
            frame0_base<=DEFAULT_FRAME0;frame1_base<=DEFAULT_FRAME1;
            roi_x_reg<=0;roi_y_reg<=0;roi_side_reg<=16'd320;
            input_base_reg<=DEFAULT_INPUT;
            roi_x_q<=0;roi_y_q<=0;roi_side_q<=0;source_y_q<=0;row_offset_q<=0;
            side_whole<=0;side_rem<=0;x_whole<=0;y_whole<=0;x_frac<=0;y_frac<=0;
            out_x<=0;out_y<=0;selected_base_q<=0;selected_seq<=0;roi_lock_slot_q<=0;
            read_addr<=0;read_total_beats<=0;burst_left<=0;
            write_addr<=0;write_beats_done<=0;write_burst_beat<=0;
            state<=R_IDLE;wstate<=W_IDLE;busy<=0;done_sticky<=0;error_sticky<=0;
            fail_pending<=0;clear_capture_errors<=0;progress_watchdog<=0;timeout_seen<=0;
        end else begin
            clear_capture_errors<=0;
            if(csr_req.valid && csr_rsp.ready && csr_req.write) begin
                case(csr_req.address[7:0])
                    8'h00: begin
                        if(csr_req.wdata[1]) begin done_sticky<=0;error_sticky<=0;clear_capture_errors<=1;end
                        if(csr_req.wdata[0] && !busy) begin
                            if(frame_valid && roi_side_reg!=0 && roi_side_reg<=1024 &&
                               input_base_reg[11:0]==0 && frame0_base[11:0]==0 && frame1_base[11:0]==0) begin
                                roi_x_q<=roi_x_reg;roi_y_q<=roi_y_reg;roi_side_q<=roi_side_reg;
                                roi_lock_slot_q<=published_slot;selected_seq<=published_seq;
                                selected_base_q<=published_slot ? frame1_base : frame0_base;
                                side_whole<=roi_side_reg/OUT_SIZE;side_rem<=roi_side_reg%OUT_SIZE;
                                x_whole<=0;y_whole<=0;x_frac<=0;y_frac<=0;out_x<=0;out_y<=0;
                                read_total_beats<=0;write_beats_done<=0;write_addr<=input_base_reg;
                                busy<=1;done_sticky<=0;fail_pending<=0;timeout_seen<=0;
                                // Row address is deliberately pipelined: clamp
                                // origin + accumulated source row, then form
                                // row byte offset, then add the selected frame
                                // base. This avoids out_y*side/OUT_SIZE in the
                                // AXI AR address path.
                                state<=R_ROW_CLAMP;
                            end else begin
                                error_sticky<=1;done_sticky<=1;
                            end
                        end
                    end
                    8'h08:frame0_base<=csr_req.wdata;
                    8'h0c:frame1_base<=csr_req.wdata;
                    8'h14:roi_x_reg<=csr_req.wdata;
                    8'h18:roi_y_reg<=csr_req.wdata;
                    8'h1c:roi_side_reg<=csr_req.wdata[15:0];
                    8'h20:input_base_reg<=csr_req.wdata;
                    default:;
                endcase
            end

            if(busy) begin
                if(progress_watchdog==25'(WATCHDOG_CYCLES)) begin
                    timeout_seen<=1;error_sticky<=1;fail_pending<=1;
                end else if(progress_watchdog!=25'h1ffffff)
                    progress_watchdog<=progress_watchdog+1'b1;
            end else progress_watchdog<=0;
            if(axi_req.arvalid && axi_rsp.arready) begin
                burst_left<=burst_beats;
                state<=R_DATA;
                progress_watchdog<=0;
            end
            if(state==R_DATA && axi_rsp.rvalid && axi_req.rready) begin
                if(read_total_beats<SOURCE_BEATS)
                    begin
                        line_buf_lo[read_total_beats] <= axi_rsp.rdata;
                        line_buf_hi[read_total_beats] <= axi_rsp.rdata;
                    end
                if(axi_rsp.rresp!=0) begin error_sticky<=1;fail_pending<=1;end
                if(read_total_beats<SOURCE_BEATS) read_total_beats<=read_total_beats+1'b1;
                burst_left<=burst_left-1'b1;
                progress_watchdog<=0;
                if(axi_rsp.rlast) begin
                    if(burst_left!=1) begin error_sticky<=1;fail_pending<=1;state<=R_FAIL_DRAIN;end
                    else if(read_total_beats+1==SOURCE_BEATS) begin
                        if(fail_pending || axi_rsp.rresp!=0) state<=R_FAIL_DRAIN;
                        else begin x_whole<=0;x_frac<=0;out_x<=0;state<=R_PREFETCH;end
                    end else begin
                        read_addr<=read_addr+32'(burst_beats*16);
                        state<=R_ADDR;
                    end
                end
                if(!axi_rsp.rlast && burst_left==1) begin
                    // Keep accepting until the actual RLAST so a malformed
                    // slave response cannot strand an outstanding AXI burst.
                    error_sticky<=1;fail_pending<=1;
                end
            end
            if(state==R_ADDR && fail_pending) state<=R_FAIL_DRAIN;
            if(state==R_DRAIN) begin
                if(axi_rsp.rvalid && axi_rsp.rlast && axi_req.rready) state<=R_FAIL_DRAIN;
            end

            if(state==R_ROW_CLAMP) begin
                source_y_q<=row_clamped;
                state<=R_ROW_OFFSET;
            end
            if(state==R_ROW_OFFSET) begin
                row_offset_q<=32'(source_y_q*ROW_BYTES);
                state<=R_ROW_BASE;
            end
            if(state==R_ROW_BASE) begin
                read_addr<=source_frame_base+row_offset_q;
                read_total_beats<=0;
                state<=R_ADDR;
            end

            if(state==R_PREFETCH) state<=R_FIRST;
            if(state==R_FIRST && out_fifo_wr) state<=R_SECOND;
            else if(state==R_SECOND && out_fifo_wr) begin
                progress_watchdog<=0;
                if(out_x==OUT_SIZE-1) begin
                    if(out_y==OUT_SIZE-1) state<=R_DRAIN;
                    else begin
                        out_x<=0;out_y<=out_y+1'b1;x_whole<=0;x_frac<=0;
                        if(y_frac+side_rem>=OUT_DIV) begin
                            y_frac<=y_frac+side_rem-OUT_DIV;
                            y_whole<=y_whole+side_whole+1'b1;
                        end else begin
                            y_frac<=y_frac+side_rem;
                            y_whole<=y_whole+side_whole;
                        end
                        read_total_beats<=0;
                        state<=R_ROW_CLAMP;
                    end
                end else begin
                    out_x<=out_x+1'b1;
                    if(x_frac+side_rem>=OUT_DIV) begin
                        x_frac<=x_frac+side_rem-OUT_DIV;
                        x_whole<=x_whole+side_whole+1'b1;
                    end else begin
                        x_frac<=x_frac+side_rem;
                        x_whole<=x_whole+side_whole;
                    end
                    state<=R_PREFETCH;
                end
            end
            if(fail_pending && (state==R_ROW_CLAMP || state==R_ROW_OFFSET ||
                                state==R_ROW_BASE || state==R_PREFETCH ||
                                state==R_FIRST || state==R_SECOND))
                state<=R_FAIL_DRAIN;

            case(wstate)
                W_IDLE: if(axi_req.awvalid && axi_rsp.awready) begin
                    write_burst_beat<=0;wstate<=W_DATA;progress_watchdog<=0;
                end
                W_DATA: if(axi_req.wvalid && axi_rsp.wready) begin
                    write_beats_done<=write_beats_done+1'b1;
                    write_burst_beat<=write_burst_beat+1'b1;
                    progress_watchdog<=0;
                    if(write_burst_beat==15) wstate<=W_RESP;
                end
                W_RESP: if(axi_rsp.bvalid && axi_req.bready) begin
                    if(axi_rsp.bresp!=0) begin error_sticky<=1;fail_pending<=1;end
                    write_addr<=write_addr+32'd256;wstate<=W_IDLE;progress_watchdog<=0;
                end
                default:wstate<=W_IDLE;
            endcase

            if((state==R_DRAIN || state==R_FAIL_DRAIN) && wstate==W_IDLE &&
               out_fifo_empty && (state==R_FAIL_DRAIN || write_beats_done==OUTPUT_BEATS)) begin
                busy<=0;state<=R_IDLE;
                if(!fail_pending && !timeout_seen &&
                   !(wstate==W_RESP && axi_rsp.bvalid && axi_req.bready && axi_rsp.bresp!=0) &&
                   progress_watchdog!=25'(WATCHDOG_CYCLES)) done_sticky<=1;
                else error_sticky<=1;
                fail_pending<=0;
            end
        end
    end

    // The frame owner remains locked from the CSR start handshake through the
    // last output B response, so capture cannot race the acquisition edge.

`ifdef SIM_ASSERT
    always @(posedge clk) if(!reset) begin
        if(axi_req.arvalid && axi_rsp.arready && axi_req.araddr[3:0]!=0)
            $fatal(1,"ROI issued unaligned source read");
        if(axi_req.awvalid && axi_rsp.awready && axi_req.awaddr[3:0]!=0)
            $fatal(1,"ROI issued unaligned C32 write");
        if(write_beats_done>OUTPUT_BEATS) $fatal(1,"ROI wrote beyond C32 image buffer");
    end
`endif
endmodule
