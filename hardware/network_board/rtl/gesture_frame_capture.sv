// 1080p HDMI RGB tap -> 640x360 RGB888 double-buffered DDR frames.
// The receiver pixel clock has no backpressure, so sampling happens before a
// Gray-pointer FIFO; the proc_clk side drains pixels and writes 16-beat AXI
// bursts. A frame becomes visible only after every write response completes.
module gesture_frame_capture #(
    parameter int SRC_W = 1920,
    parameter int SRC_H = 1080,
    parameter int DECIM = 3,
    parameter int FIFO_ADDR_W = 9,
    parameter bit KEEP_TWO_OF_THREE = 1'b0,
    parameter bit FAST_PACK = 1'b0,
    parameter bit AUTO_INPUT_MODE = 1'b0,
    parameter bit LOCK_SKIP_ERROR = 1'b1,
    parameter int WRITE_FIFO_AW = 8,
    parameter int WRITE_FIFO_REG_BITS = 0
) (
    input  logic                     proc_clk,
    input  logic                     pclk,
    input  logic                     reset,
    input  logic                     hdmi_vs,      // active high
    input  logic                     hdmi_de,
    input  logic [7:0]               hdmi_r,
    input  logic [7:0]               hdmi_g,
    input  logic [7:0]               hdmi_b,
    input  logic [31:0]              frame0_base,
    input  logic [31:0]              frame1_base,
    input  logic                     net_lock,
    input  logic                     net_lock_slot,
    input  logic                     roi_lock,
    input  logic                     roi_lock_slot,
    input  logic                     clear_errors,
    output logic                     frame_valid,
    output logic                     published_slot,
    output logic [30:0]              published_seq,
    output logic                     overflow_sticky,
    output logic                     error_sticky,
    output logic                     video_lost,
    output logic                     input_is_720p,
    output logic                     input_mode_valid,
    output demo_bus_pkg::axi_req_t   axi_req,
    input  wire demo_bus_pkg::axi_rsp_t axi_rsp
);
    import demo_bus_pkg::*;
    localparam int OUT_W = KEEP_TWO_OF_THREE ? SRC_W*2/3 : SRC_W / DECIM;
    localparam int OUT_H = KEEP_TWO_OF_THREE ? SRC_H*2/3 : SRC_H / DECIM;
    localparam int FRAME_PIXELS = OUT_W * OUT_H;

    logic [24:0] pix_fifo_data;
    logic pix_fifo_full, pix_fifo_empty;
    logic pix_fifo_wr, pix_fifo_rd;
    logic [24:0] pix_fifo_wdata;
    logic [10:0] src_x;
    logic [10:0] src_y;
    // Modulo-three phases follow the coordinate counters, including their
    // saturation behavior on malformed overlong rows/frames.
    logic [1:0] src_x_phase3;
    logic [1:0] src_y_phase3;
    logic p_vs_d, p_de_d;
    logic src_bad;
    logic p_frame_seen;
    logic [10:0] measured_width;
    logic timing_bad;
    wire [10:0] expected_width = AUTO_INPUT_MODE && input_is_720p ? 11'(SRC_W*2/3) : 11'(SRC_W);
    wire [10:0] expected_height = AUTO_INPUT_MODE && input_is_720p ? 11'(SRC_H*2/3) : 11'(SRC_H);
    wire observed_high = !timing_bad && measured_width==SRC_W && src_y==SRC_H;
    wire observed_low = !timing_bad && measured_width==SRC_W*2/3 && src_y==SRC_H*2/3;
    logic bad_toggle;
    (* async_reg = "true" *) logic bad_sync1, bad_sync2;
    logic bad_seen;

    // proc_reset is generated in proc_clk. Assert this local reset
    // asynchronously, then release it only after two pclk edges.
    (* async_reg = "true" *) logic [1:0] pclk_reset_pipe;
    always_ff @(posedge pclk or posedge reset) begin
        if (reset) pclk_reset_pipe <= '0;
        else       pclk_reset_pipe <= {pclk_reset_pipe[0], 1'b1};
    end
    wire pclk_reset = !pclk_reset_pipe[1];

    wire vs_rise = hdmi_vs && !p_vs_d;
    // Decide once per completed input frame. A changed mode is not trusted
    // until its full active geometry has been measured; partial transition
    // frames are rejected by the existing bad-frame toggle and SOF counts.
    wire sample_phase = AUTO_INPUT_MODE && input_is_720p ?
        (KEEP_TWO_OF_THREE || (src_x[0] && src_y[0])) :
        ((DECIM==3) ?
            (KEEP_TWO_OF_THREE ? (src_x_phase3!=2 && src_y_phase3!=2) :
                                 (src_x_phase3==1 && src_y_phase3==1)) :
            (KEEP_TWO_OF_THREE ? ((src_x % 3 != 2) && (src_y % 3 != 2)) :
                                 ((src_x % DECIM == DECIM/2) &&
                                  (src_y % DECIM == DECIM/2))));
    wire sample_pixel = hdmi_de && (!AUTO_INPUT_MODE || input_mode_valid) &&
                        src_x<expected_width && src_y<expected_height && sample_phase;
    assign pix_fifo_wr = sample_pixel;
    assign pix_fifo_wdata = {(KEEP_TWO_OF_THREE ? (src_y==0 && src_x==0) :
                             (src_y == DECIM/2 && src_x == DECIM/2)),
                             hdmi_r, hdmi_g, hdmi_b};

    gesture_async_fifo #(.DATA_W(25), .ADDR_W(FIFO_ADDR_W)) u_pixel_fifo (
        .arst(reset), .wclk(pclk), .wr_en(pix_fifo_wr), .wr_data(pix_fifo_wdata),
        .full(pix_fifo_full), .rclk(proc_clk), .rd_en(pix_fifo_rd),
        .rd_data(pix_fifo_data), .empty(pix_fifo_empty));

    // Source timing validation and frame-local overflow accounting stay in
    // pclk. One toggle per bad frame crosses safely even if proc_clk is busy.
    always_ff @(posedge pclk) begin
        if (pclk_reset) begin
            p_vs_d <= 1'b0;
            p_de_d <= 1'b0;
            src_x <= '0;
            src_y <= '0;
            src_x_phase3 <= '0;
            src_y_phase3 <= '0;
            src_bad <= 1'b0;
            p_frame_seen <= 1'b0;
            measured_width <= '0;
            timing_bad <= 1'b0;
            input_is_720p <= 1'b0;
            input_mode_valid <= !AUTO_INPUT_MODE;
            bad_toggle <= 1'b0;
        end else begin
            p_vs_d <= hdmi_vs;
            p_de_d <= hdmi_de;
            if (vs_rise) begin
                if (p_frame_seen && (!AUTO_INPUT_MODE || input_mode_valid) &&
                    (src_bad || timing_bad || src_y != expected_height))
                    bad_toggle <= ~bad_toggle;
                p_frame_seen <= 1'b1;
                if (AUTO_INPUT_MODE) begin
                    input_mode_valid <= p_frame_seen && (observed_high || observed_low);
                    if (observed_high || observed_low) input_is_720p <= observed_low;
                end
                measured_width <= '0;
                timing_bad <= 1'b0;
                src_x <= '0;
                src_y <= '0;
                src_x_phase3 <= '0;
                src_y_phase3 <= '0;
                src_bad <= 1'b0;
            end else begin
                if (hdmi_de) begin
                    if (src_x <= SRC_W) begin
                        src_x <= src_x + 1'b1;
                        src_x_phase3 <= (src_x_phase3==2'd2) ? 2'd0 : src_x_phase3+2'd1;
                    end else begin src_bad <= 1'b1; timing_bad <= 1'b1; end
                end
                if (p_de_d && !hdmi_de) begin
                    if (src_x != expected_width) src_bad <= 1'b1;
                    if (src_y==0) measured_width <= src_x;
                    else if (src_x != measured_width) timing_bad <= 1'b1;
                    src_x <= '0;
                    src_x_phase3 <= '0;
                    if (src_y <= SRC_H) begin
                        src_y <= src_y + 1'b1;
                        src_y_phase3 <= (src_y_phase3==2'd2) ? 2'd0 : src_y_phase3+2'd1;
                    end else begin src_bad <= 1'b1; timing_bad <= 1'b1; end
                end
                if (sample_pixel && pix_fifo_full) src_bad <= 1'b1;
            end
        end
    end

    (* async_reg = "true" *) logic [2:0] reset_sync;
    always_ff @(posedge proc_clk or posedge reset) begin
        if (reset) begin
            reset_sync <= '0;
            bad_sync1 <= 1'b0;
            bad_sync2 <= 1'b0;
        end else begin
            reset_sync <= {reset_sync[1:0],1'b1};
            bad_sync1 <= bad_toggle;
            bad_sync2 <= bad_sync1;
        end
    end
    wire proc_reset = !reset_sync[2];

    typedef enum logic [1:0] {PIX_IDLE, PIX_R, PIX_G, PIX_B} pix_state_t;
    pix_state_t pix_state;
    logic [23:0] held_pixel;
    logic [127:0] pack_word;
    logic [3:0] pack_count;
    logic [127:0] beat_data;
    logic beat_wr;
    logic beat_full, beat_empty;
    logic [WRITE_FIFO_AW:0] beat_count;
    logic beat_rd;
    logic [127:0] beat_head;
    logic discard_tail;

    gesture_sync_fifo #(.DATA_W(128), .ADDR_W(WRITE_FIFO_AW),
                       .REGISTER_BITS(WRITE_FIFO_REG_BITS)) u_write_fifo (
        .clk(proc_clk), .reset(proc_reset || discard_tail), .wr_en(beat_wr), .wr_data(beat_data),
        .full(beat_full), .rd_en(beat_rd), .rd_data(beat_head),
        .empty(beat_empty), .count(beat_count));

    logic cap_active, cap_slot;
    logic frame_bad;
    logic [31:0] sampled_pixels;
    logic publish_pending, publish_slot_q;
    logic [31:0] write_addr;
    typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} write_state_t;
    write_state_t wstate;
    // Never overwrite the currently published slot. The ROI engine raises
    // roi_lock combinationally on its CSR start handshake, so this test also
    // covers a simultaneous SOF and software start.
    wire complete_sof = pix_fifo_rd && pix_fifo_data[24] && cap_active &&
        sampled_pixels==FRAME_PIXELS && !frame_bad && bad_sync2==bad_seen;
    wire publish_at_sof = complete_sof && wstate==W_IDLE && beat_empty && pack_count==0;
    wire candidate_slot = publish_at_sof ? !cap_slot : (frame_valid ? !published_slot : !cap_slot);
    wire [31:0] candidate_base = candidate_slot ? frame1_base : frame0_base;
    wire sof_publish_due = pix_fifo_rd && pix_fifo_data[24] &&
        (publish_pending || (cap_active && sampled_pixels==FRAME_PIXELS && !frame_bad));
    logic [15:0] burst_beat;
    logic [4:0] burst_len;
    logic [8:0] page_beats;
    always_comb begin
        page_beats = 9'd256 - {1'b0,write_addr[11:4]};
        burst_len = (page_beats < 16) ? 5'(page_beats) : 5'd16;
    end
    // An interrupted frame may leave a partial RGB word or fewer than one
    // AXI burst in the queue. Those bytes cannot be carried into a new frame.
    // Drain all complete bursts (including an AW waiting for READY) and its B
    // response first, then discard only the unissued tail. A good pending
    // publication keeps its complete frame until every write has finished.
    assign discard_tail = !cap_active && !publish_pending &&
                          wstate==W_IDLE && beat_count<16;
    logic [26:0] no_pixel_watchdog;
    logic [20:0] bus_watchdog;

    assign pix_fifo_rd = !proc_reset && !pix_fifo_empty && pix_state==PIX_IDLE &&
                         !(FAST_PACK && cap_active && beat_full && pack_count==15);
    wire fast_red = FAST_PACK && pix_fifo_rd && !pix_fifo_data[24] && cap_active;

    // Serializer and RGB byte packer. Rows are 1920 bytes, so the complete
    // frame is exactly 43,200 aligned 128-bit beats.
    always_comb begin
        beat_wr = 1'b0;
        beat_data = pack_word;
        if (cap_active && (pix_state!=PIX_IDLE || fast_red) && !beat_full) begin
            if (fast_red) beat_data[8*pack_count +: 8] = pix_fifo_data[23:16];
            else case (pix_state)
                PIX_R: beat_data[8*pack_count +: 8] = held_pixel[23:16];
                PIX_G: beat_data[8*pack_count +: 8] = held_pixel[15:8];
                PIX_B: beat_data[8*pack_count +: 8] = held_pixel[7:0];
                default: ;
            endcase
            if (pack_count==15) beat_wr=1'b1;
        end
    end

    // DDR writer: never changes address/data while VALID is waiting. The
    // capture FIFO absorbs bounded DDR arbitration stalls; if it fills, the
    // serializer waits and the asynchronously clocked input FIFO reports the
    // frame as bad instead of silently publishing a torn image.
    always_comb begin
        axi_req='0;
        axi_req.awid=4'd2;
        axi_req.awaddr=write_addr;
        axi_req.awlen=8'(burst_len-1'b1);
        axi_req.awsize=3'd4;
        axi_req.awburst=2'd1;
        axi_req.awvalid=(wstate==W_IDLE) && (beat_count>=16);
        axi_req.wdata=beat_head;
        axi_req.wstrb=16'hffff;
        axi_req.wlast=(burst_beat==burst_len-1'b1);
        axi_req.wvalid=(wstate==W_DATA) && !beat_empty;
        axi_req.bready=(wstate==W_RESP);
        beat_rd=axi_req.wvalid && axi_rsp.wready;
    end

    always_ff @(posedge proc_clk) begin
        if (proc_reset) begin
            pix_state<=PIX_IDLE; held_pixel<='0; pack_word<='0; pack_count<='0;
            frame_valid<=1'b0; published_slot<=1'b0; published_seq<='0;
            overflow_sticky<=1'b0; error_sticky<=1'b0; video_lost<=1'b0;
            bad_seen<=1'b0; cap_active<=1'b0; cap_slot<=1'b1; frame_bad<=1'b0;
            sampled_pixels<='0; publish_pending<=1'b0; publish_slot_q<=1'b0;
            write_addr<='0; burst_beat<='0; wstate<=W_IDLE;
            no_pixel_watchdog<='0; bus_watchdog<='0;
        end else begin
            if (clear_errors) begin
                overflow_sticky<=1'b0;
                error_sticky<=1'b0;
            end
            if (bad_sync2 != bad_seen) begin
                bad_seen<=bad_sync2;
                frame_bad<=1'b1;
                overflow_sticky<=1'b1;
            end

            if (!pix_fifo_empty) begin
                no_pixel_watchdog<='0;
                video_lost<=1'b0;
            end else if (!(&no_pixel_watchdog)) begin
                no_pixel_watchdog<=no_pixel_watchdog+1'b1;
                if (&no_pixel_watchdog[25:0]) video_lost<=1'b1;
            end

            if (pix_fifo_rd) begin
                held_pixel<=pix_fifo_data[23:0];
                if (pix_fifo_data[24]) begin
                    // The preceding bank is published only after its last B
                    // response; capture skips a frame if it still owns DDR.
                    if (complete_sof && !publish_at_sof)
                        begin publish_pending<=1'b1; publish_slot_q<=cap_slot; end
                    else if (cap_active && !complete_sof) error_sticky<=1'b1;

                    if (publish_at_sof) begin
                        published_slot<=cap_slot;published_seq<=published_seq+1'b1;
                        frame_valid<=1'b1;publish_pending<=1'b0;
                    end
                    if (sof_publish_due && !publish_at_sof) begin
                        // The just-finished image is being published at this
                        // boundary. Wait one source frame so the new slot
                        // owner is visible before selecting the next bank.
                        cap_active<=1'b0;
                    end else if (wstate==W_IDLE && beat_empty && pack_count==0) begin
                        // Bank choice is made against the published and ROI
                        // locked owners. Both frame bases must be word aligned.
                        if (!(roi_lock && roi_lock_slot==candidate_slot) &&
                            !(net_lock && net_lock_slot==candidate_slot) &&
                            candidate_base[11:0]==12'd0) begin
                            cap_slot<=candidate_slot;
                            write_addr<=candidate_base;
                            cap_active<=1'b1;
                        end else begin
                            cap_active<=1'b0;
                            if (LOCK_SKIP_ERROR || candidate_base[11:0]!=0)
                                overflow_sticky<=1'b1;
                        end
                    end else begin
                        cap_active<=1'b0;
                        overflow_sticky<=1'b1;
                    end
                    sampled_pixels<='0;
                    frame_bad<=1'b0;
                    pix_state<=PIX_R;
                end else begin
                    if (cap_active) begin
                        if (FAST_PACK) begin
                            pack_word[8*pack_count +:8]<=pix_fifo_data[23:16];
                            pack_count<=pack_count+1'b1;
                            pix_state<=PIX_G;
                        end else pix_state<=PIX_R;
                    end else pix_state<=PIX_IDLE;
                end
            end else if (pix_state!=PIX_IDLE && cap_active) begin
                if (beat_full && pack_count==15) begin
                    // Hold the component and state until a complete word fits.
                end else begin
                    case (pix_state)
                        PIX_R: begin pack_word[8*pack_count +:8]<=held_pixel[23:16];
                                     pack_count<=pack_count+1'b1;pix_state<=PIX_G;end
                        PIX_G: begin pack_word[8*pack_count +:8]<=held_pixel[15:8];
                                     pack_count<=pack_count+1'b1;pix_state<=PIX_B;end
                        PIX_B: begin
                            pack_word[8*pack_count +:8]<=held_pixel[7:0];
                            if (pack_count==15) begin pack_count<=0;pack_word<=0;end
                            else pack_count<=pack_count+1'b1;
                            pix_state<=PIX_IDLE;
                            sampled_pixels<=sampled_pixels+1'b1;
                        end
                        default: pix_state<=PIX_IDLE;
                    endcase
                end
            end else pix_state<=PIX_IDLE;

            if (discard_tail) begin
                pack_word<='0;
                pack_count<='0;
            end

            if (publish_pending && wstate==W_IDLE && beat_empty && pix_state==PIX_IDLE && !pix_fifo_rd) begin
                published_slot<=publish_slot_q;
                published_seq<=published_seq+1'b1;
                frame_valid<=1'b1;
                publish_pending<=1'b0;
            end

            case (wstate)
                W_IDLE: if (axi_req.awvalid && axi_rsp.awready) begin
                    burst_beat<=0;
                    wstate<=W_DATA;
                    bus_watchdog<=0;
                end
                W_DATA: if (axi_req.wvalid && axi_rsp.wready) begin
                    burst_beat<=burst_beat+1'b1;
                    bus_watchdog<=0;
                    if (burst_beat==burst_len-1'b1) wstate<=W_RESP;
                end
                W_RESP: if (axi_rsp.bvalid && axi_req.bready) begin
                    if (axi_rsp.bresp!=0) begin
                        error_sticky<=1'b1; frame_bad<=1'b1; publish_pending<=1'b0;
                    end
                    write_addr<=write_addr+32'd256;
                    bus_watchdog<=0;
                    wstate<=W_IDLE;
                end
                default: wstate<=W_IDLE;
            endcase
            if((wstate!=W_IDLE || axi_req.awvalid) &&
               !(axi_req.awvalid && axi_rsp.awready) &&
               !(axi_req.wvalid && axi_rsp.wready) &&
               !(axi_rsp.bvalid && axi_req.bready) && bus_watchdog<21'd1_800_000) begin
                bus_watchdog<=bus_watchdog+1'b1;
                if(bus_watchdog==21'd1_799_999) begin
                    error_sticky<=1'b1;frame_bad<=1'b1;overflow_sticky<=1'b1;
                end
            end
        end
    end

`ifdef SIM_ASSERT
    always @(posedge proc_clk) if (!proc_reset) begin
        if (axi_req.awvalid && axi_rsp.awready &&
            axi_req.awaddr[3:0]!=0)
            $fatal(1,"capture emitted unaligned or 4KiB-crossing burst");
        if (sampled_pixels>FRAME_PIXELS) $fatal(1,"capture pixel count overflow");
        if (axi_req.awvalid && axi_rsp.awready && net_lock && cap_slot==net_lock_slot)
            $fatal(1,"capture wrote a frame slot locked by network");
        if (axi_req.awvalid && axi_rsp.awready && roi_lock && cap_slot==roi_lock_slot)
            $fatal(1,"capture wrote a frame slot locked by ROI");
        if (axi_req.awvalid && axi_rsp.awready && frame_valid && cap_slot==published_slot)
            $fatal(1,"capture wrote the currently published frame slot");
    end
`endif
endmodule
