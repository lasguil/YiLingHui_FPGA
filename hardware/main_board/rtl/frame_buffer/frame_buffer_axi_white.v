`timescale 1ns/1ps

//
// Stand-alone AXI4 frame buffer bring-up module.
//
// Camera RAW10 input is captured through an asynchronous FIFO.  Each 10-bit
// sample is carried in a 16-bit container (upper six bits are zero), then
// packed into AXI4 128-bit incrementing bursts, written to DDR3, read back
// with AXI4 incrementing bursts, and emitted as two 16-bit samples per video
// clock.  Keeping the samples 16-bit aligned avoids packing across AXI/DDR
// beats while preserving all ten sensor bits.
//
// AXI addresses are byte addresses.  The default project configuration is
// 128-bit AXI data, so one beat is 16 bytes and AWSIZE/ARSIZE is 4.
//
module frame_buffer_axi_white #(
    parameter I_VID_WIDTH       = 32,
    parameter O_VID_WIDTH       = 16,
    parameter AXI_DATA_WIDTH    = 128,
    parameter AXI_ADDR_WIDTH    = 32,
    parameter AXI_ID_WIDTH      = 4,
    parameter WR_FIFO_DEPTH     = 1024,
    parameter RD_FIFO_DEPTH     = 1024,
    parameter START_ADDR        = 32'h0000_0000,
    parameter BURST_LEN         = 127,
    parameter FB_NUM             = 3,
    parameter MAX_VID_WIDTH     = 960,
    parameter MAX_VID_HIGHT     = 1080,
    parameter DISPLAY_LOCK_ENABLE = 0
) (
    input wire                         axi_clk,
    input wire                         rst_n,
    input wire                         ddr_init_done,
    input wire                         npu_lock,
    input wire [1:0]                   npu_locked_bank,
    input wire                         display_lock,
    input wire [1:0]                   display_locked_bank,
    input wire                         pending_display_lock,
    input wire [1:0]                   pending_display_locked_bank,
    output reg [15:0]                  capture_sequence,
    output wire [31:0]                 capture_base,
    output reg [1:0]                   capture_mode,
    input wire                         final_valid,
    input wire [31:0]                  final_base,
    input wire [1:0]                   final_mode,
    output reg [31:0]                  active_final_base,
    output wire                        display_urgent,
    output wire                        capture_urgent,

    // Kept for drop-in compatibility with the old frame_buffer instance.
    input wire                         i_clk,
    input wire                         i_vs,
    input wire                         i_de,
    input wire [I_VID_WIDTH-1:0]       vin,
    // 0=1920x1080, 1=1280x720, 2=854x480 (864 stride). Latched on camera VS.
    input wire [1:0]                   i_store_mode,
    input wire                         i_cam_60,

    input wire                         o_clk,
    output reg                         o_hs,
    output reg                         o_vs,
    output reg                         o_de,
    output reg [O_VID_WIDTH-1:0]       vout,

    input wire [12:0]                  H_FRONT_PORCH,
    input wire [12:0]                  H_SYNC,
    input wire [12:0]                  H_VALID,
    input wire [12:0]                  H_BACK_PORCH,
    input wire [12:0]                  V_FRONT_PORCH,
    input wire [12:0]                  V_SYNC,
    input wire [12:0]                  V_VALID,
    input wire [12:0]                  V_BACK_PORCH,

    // AXI4 write address channel.
    output reg [AXI_ID_WIDTH-1:0]      awid,
    output reg [AXI_ADDR_WIDTH-1:0]    awaddr,
    output reg [7:0]                   awlen,
    output reg [2:0]                   awsize,
    output reg [1:0]                   awburst,
    output reg [3:0]                   awcache,
    output reg [2:0]                   awprot,
    output reg                         awlock,
    output reg [3:0]                   awqos,
    output reg                         awvalid,
    input wire                         awready,

    // AXI4 write data channel.
    output reg [AXI_DATA_WIDTH-1:0]    wdata,
    output reg [AXI_DATA_WIDTH/8-1:0]  wstrb,
    output reg                         wlast,
    output reg                         wvalid,
    input wire                         wready,

    // AXI4 write response channel.
    input wire [AXI_ID_WIDTH-1:0]      bid,
    input wire [1:0]                   bresp,
    input wire                         bvalid,
    output reg                         bready,

    // AXI4 read address channel.
    output reg [AXI_ID_WIDTH-1:0]      arid,
    output reg [AXI_ADDR_WIDTH-1:0]    araddr,
    output reg [7:0]                   arlen,
    output reg [2:0]                   arsize,
    output reg [1:0]                   arburst,
    output reg [3:0]                   arcache,
    output reg [2:0]                   arprot,
    output reg                         arlock,
    output reg [3:0]                   arqos,
    output reg                         arvalid,
    input wire                         arready,

    // AXI4 read data channel.
    input wire [AXI_ID_WIDTH-1:0]      rid,
    input wire [AXI_DATA_WIDTH-1:0]    rdata,
    input wire [1:0]                   rresp,
    input wire                         rlast,
    input wire                         rvalid,
    output reg                         rready,

    // Compatibility/debug outputs retained from the original wrapper.
    output wire [31:0]                 test_rd_fifo_rddata,
    output wire [31:0]                 test_wdata,
    output wire [31:0]                 test_rdata,
    output wire                         axi_error,

    // Latched FIFO diagnostics.  cap_fifo_overflow means that an input
    // camera word was presented while the capture FIFO was full and was
    // therefore discarded.  rd_fifo_full_seen means that the read FIFO
    // reached full while AXI was presenting data; AXI backpressure prevents
    // data loss in that FIFO, so this is a pressure indicator rather than an
    // overflow indication.  rd_fifo_empty_seen means that the video side
    // needed a pixel while the read FIFO was empty (a latched underflow).
    output wire                         cap_fifo_overflow,
    output wire                         rd_fifo_full_seen,
    output wire                         rd_fifo_empty_seen,

    // Read-only bring-up observability.
    output wire [2:0]                   dbg_wstate,
    output wire [1:0]                   dbg_rstate,
    output wire [3:0]                   dbg_cam_frame_start,
    output wire [3:0]                   dbg_cam_frame_end,
    output wire [11:0]                  dbg_cap_used,
    output wire [1:0]                   dbg_display_bank,
    output wire [1:0]                   dbg_rd_bank,
    output wire                         dbg_write_done,
    output wire                         dbg_video_started
);


    localparam integer PIXELS_PER_WORD = AXI_DATA_WIDTH / O_VID_WIDTH;
    // Elitestek sequential AXI: keep every beat, advance by the full
    // burst. Drop-first / unique-stride / line-rotate were Efinity PHY
    // workarounds; on this controller they sheared lines.
    localparam integer BYTES_PER_BEAT = AXI_DATA_WIDTH / 8;
    localparam integer PIXEL_BYTES    = O_VID_WIDTH / 8;
    localparam integer FRAME_PIXELS   = MAX_VID_WIDTH * MAX_VID_HIGHT;
    localparam integer FRAME_BYTES    = FRAME_PIXELS * PIXEL_BYTES;
    localparam integer FRAME_WORDS    = (FRAME_BYTES + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
    // AXI4 bursts must not cross a 4-KB boundary.  With two-byte containers
    // per pixel, the RAW10 frame payload is 0x3F4800 bytes.  Round the bank
    // stride up so every frame bank starts on a 4-KB boundary.
    localparam integer FRAME_PAYLOAD_BYTES = FRAME_WORDS * BYTES_PER_BEAT;
    localparam integer FRAME_STRIDE_BYTES =
        ((FRAME_PAYLOAD_BYTES + 4095) / 4096) * 4096;
    localparam integer BURST_BEATS    = BURST_LEN + 1;
    localparam integer FIFO_ADDR_W    = $clog2(RD_FIFO_DEPTH);
    localparam integer FIFO_PTR_W     = FIFO_ADDR_W + 1;
    localparam integer BEAT_CNT_W     = (BURST_BEATS <= 1) ? 1 : $clog2(BURST_BEATS + 1);
    localparam integer CAP_FIFO_DEPTH = WR_FIFO_DEPTH;
    localparam integer CAP_ADDR_W     = $clog2(CAP_FIFO_DEPTH);
    localparam integer CAP_PTR_W      = CAP_ADDR_W + 1;
    localparam integer CAP_WORDS_PER_BEAT = AXI_DATA_WIDTH / I_VID_WIDTH;
    localparam [CAP_PTR_W-1:0] CAP_WORDS_PER_BEAT_PTR = CAP_WORDS_PER_BEAT;
    localparam integer FRAME_EVENT_W = 4;
    localparam [FRAME_EVENT_W-1:0] FRAME_EVENT_HALF = {1'b1,{(FRAME_EVENT_W-1){1'b0}}};
    // This trial writes and previews 480p at 60 fps: one read burst per
    // write burst. Reserve half the capture FIFO for incoming line bursts.
    localparam integer CAP_FRAME_WORDS = (MAX_VID_WIDTH * MAX_VID_HIGHT * O_VID_WIDTH) / I_VID_WIDTH;
    localparam integer CAP_CRITICAL_LEVEL = (CAP_FIFO_DEPTH / 2);

    // Cross-section signals: declare before write arbitration uses them.
    // Assert all domains together; release only on each domain's own clock.
    (* async_reg = "true" *) reg [1:0] input_reset_pipe,output_reset_pipe;
    always @(posedge i_clk or negedge rst_n)
        if(!rst_n)input_reset_pipe<=0;else input_reset_pipe<={input_reset_pipe[0],1'b1};
    always @(posedge o_clk or negedge rst_n)
        if(!rst_n)output_reset_pipe<=0;else output_reset_pipe<={output_reset_pipe[0],1'b1};
    wire input_rst_n=input_reset_pipe[1],output_rst_n=output_reset_pipe[1];
    localparam R_WAIT = 2'd0;
    localparam R_AR   = 2'd1;
    localparam R_DATA = 2'd2;
    reg [1:0] rstate;
    (* async_reg = "true" *) reg       resync_req_axi;
    reg       resync_ack;
    reg rd_fifo_empty_latched;
    reg resync_req;
    wire [FIFO_PTR_W-1:0] fifo_used;
    wire rbeat_is_last;
    wire fifo_can_accept_burst;

    function [FIFO_PTR_W-1:0] bin_to_gray;
        input [FIFO_PTR_W-1:0] value;
        begin
            bin_to_gray = (value >> 1) ^ value;
        end
    endfunction

    function [FIFO_PTR_W-1:0] gray_to_bin;
        input [FIFO_PTR_W-1:0] value;
        integer k;
        begin
            gray_to_bin[FIFO_PTR_W-1] = value[FIFO_PTR_W-1];
            for (k = FIFO_PTR_W-2; k >= 0; k = k - 1)
                gray_to_bin[k] = gray_to_bin[k+1] ^ value[k];
        end
    endfunction

    function [CAP_PTR_W-1:0] cap_bin_to_gray;
        input [CAP_PTR_W-1:0] value;
        begin
            cap_bin_to_gray = (value >> 1) ^ value;
        end
    endfunction

    function [CAP_PTR_W-1:0] cap_gray_to_bin;
        input [CAP_PTR_W-1:0] value;
        integer k;
        begin
            cap_gray_to_bin[CAP_PTR_W-1] = value[CAP_PTR_W-1];
            for (k = CAP_PTR_W-2; k >= 0; k = k - 1)
                cap_gray_to_bin[k] = cap_gray_to_bin[k+1] ^ value[k];
        end
    endfunction

    function [AXI_ADDR_WIDTH-1:0] frame_bank_base;
        input [1:0] bank;
        begin
            // Bank 0/1 are the HDMI ping-pong pair; bank 2 is the capture
            // bank.  Each bank needs its own stride, otherwise a capture
            // would land on top of the bank HDMI is currently displaying.
            frame_bank_base = START_ADDR + bank * FRAME_STRIDE_BYTES;
        end
    endfunction

    function [FRAME_EVENT_W-1:0] event_bin_to_gray;
        input [FRAME_EVENT_W-1:0] value;
        begin
            event_bin_to_gray = (value >> 1) ^ value;
        end
    endfunction

    function [FRAME_EVENT_W-1:0] event_gray_to_bin;
        input [FRAME_EVENT_W-1:0] value;
        integer k;
        begin
            event_gray_to_bin[FRAME_EVENT_W-1] = value[FRAME_EVENT_W-1];
            for (k = FRAME_EVENT_W-2; k >= 0; k = k - 1)
                event_gray_to_bin[k] = event_gray_to_bin[k+1] ^ value[k];
        end
    endfunction

    function [FRAME_EVENT_W-1:0] event_gray_delta;
        input [FRAME_EVENT_W-1:0] observed;
        input [FRAME_EVENT_W-1:0] expected;
        begin
            event_gray_delta = event_gray_to_bin(observed) - event_gray_to_bin(expected);
        end
    endfunction

    // Packed RGB565: 4 px / 64-bit capture word, 8 px / 128-bit AXI beat.
    // 1920x1080 / 1280x720 / 720x480 are all multiples of 8 and of BURST=32.
    function [19:0] cap_words_for;
        input [1:0] m;
        begin
            case (m)
                2'd1: cap_words_for = 20'd230400; // 1280*720/4
                2'd2: cap_words_for = 20'd103680; // 864*480/4, 854 active + 10 pad
                default: cap_words_for = 20'd518400; // 1920*1080/4
            endcase
        end
    endfunction

    function [31:0] axi_words_for;
        input [1:0] m;
        begin
            case (m)
                2'd1: axi_words_for = 32'd115200; // 1280*720/8
                2'd2: axi_words_for = 32'd51840; // 864*480/8
                default: axi_words_for = 32'd259200; // 1920*1080/8
            endcase
        end
    endfunction

    // ---------------------------------------------------------------------
    // Camera-side asynchronous FIFO.  The CSI output is four RAW10 samples
    // per valid clock, represented as four 16-bit containers; two FIFO
    // entries form one 128-bit AXI write beat.
    // ---------------------------------------------------------------------
    reg [CAP_PTR_W-1:0] cap_wr_bin;
    reg [CAP_PTR_W-1:0] cap_wr_gray;
    reg [CAP_PTR_W-1:0] cap_rd_bin;
    reg [CAP_PTR_W-1:0] cap_rd_gray;
    (* async_reg = "true" *) reg [CAP_PTR_W-1:0] cap_rd_gray_sync1;
    (* async_reg = "true" *) reg [CAP_PTR_W-1:0] cap_rd_gray_sync2;
    (* async_reg = "true" *) reg [CAP_PTR_W-1:0] cap_wr_gray_sync1;
    (* async_reg = "true" *) reg [CAP_PTR_W-1:0] cap_wr_gray_sync2;
    reg cam_vs_d;
    reg cam_frame_active;
    reg cap_frame_good, cap_frame_dropped;
    (* async_reg = "true" *) reg cap_good_meta, cap_good_axi;
    (* async_reg = "true" *) reg cam60_meta, cam60_axi;
    // i_vs stays high for the whole camera frame.  Reset often releases
    // in the middle of that level; treating it as a rising edge stores
    // the frame from a random line.  A real edge follows a low sample.
    reg vs_armed;
    reg [19:0] cap_kept;
    reg [CAP_PTR_W-1:0] origin_bin;
    reg origin_arm;
    reg [3:0] origin_wait;
    reg origin_tog;
    reg [FRAME_EVENT_W-1:0] cam_frame_start_bin;
    reg [FRAME_EVENT_W-1:0] cam_frame_end_bin;
    reg [FRAME_EVENT_W-1:0] cam_frame_start_gray;
    reg [FRAME_EVENT_W-1:0] cam_frame_end_gray;
    (* async_reg = "true" *) reg [FRAME_EVENT_W-1:0] cam_frame_start_meta;
    (* async_reg = "true" *) reg [FRAME_EVENT_W-1:0] cam_frame_start_axi;
    (* async_reg = "true" *) reg [FRAME_EVENT_W-1:0] cam_frame_end_meta;
    (* async_reg = "true" *) reg [FRAME_EVENT_W-1:0] cam_frame_end_axi;
    (* async_reg = "true" *) reg origin_tog_meta;
    (* async_reg = "true" *) reg origin_tog_axi;
    reg origin_tog_axi_d;
    reg [CAP_PTR_W-1:0] origin_bin_axi;
    reg [1:0] origin_mode_axi;
    reg [1:0] origin_format_axi,origin_format;
    reg cap_overflow_latched;
    (* async_reg = "true" *) reg cap_overflow_axi_meta;
    (* async_reg = "true" *) reg cap_overflow_axi;

    wire [CAP_PTR_W-1:0] cap_wr_bin_next = cap_wr_bin + 1'b1;
    wire [CAP_PTR_W-1:0] cap_wr_gray_next = cap_bin_to_gray(cap_wr_bin_next);
    wire [CAP_PTR_W-1:0] cap_wr_bin_sync = cap_gray_to_bin(cap_wr_gray_sync2);
    wire [CAP_PTR_W-1:0] cap_used = cap_wr_bin_sync - cap_rd_bin;
    reg [1:0] cap_mode;
    reg [1:0] origin_mode;
    wire cap_frame_full = (cap_kept >= cap_words_for(cap_mode));
    wire cap_full = (cap_wr_gray_next ==
                     {~cap_rd_gray_sync2[CAP_PTR_W-1:CAP_PTR_W-2],
                       cap_rd_gray_sync2[CAP_PTR_W-3:0]});
    // One camera frame only.  Extra pixels would be the head of the next
    // frame and show up as the band at the bottom of the picture.
    wire cap_mem_we = i_de && cam_frame_active && !cap_full && !cap_frame_full;
    wire cap_mem_re;
    wire [I_VID_WIDTH-1:0] cap_mem_rdata;

    always @(posedge i_clk or negedge input_rst_n) begin
        if (!input_rst_n) begin
            cap_wr_bin       <= {CAP_PTR_W{1'b0}};
            cap_wr_gray      <= {CAP_PTR_W{1'b0}};
            cap_rd_gray_sync1<= {CAP_PTR_W{1'b0}};
            cap_rd_gray_sync2<= {CAP_PTR_W{1'b0}};
            cam_vs_d               <= 1'b0;
            cam_frame_active       <= 1'b0;
            cap_frame_good <= 1'b0; cap_frame_dropped <= 1'b0;
            vs_armed               <= 1'b0;
            cap_kept               <= 20'd0;
            cap_mode               <= 2'd0;
            origin_mode            <= 2'd0;
            origin_format<=0;
            origin_bin             <= {CAP_PTR_W{1'b0}};
            origin_arm             <= 1'b0;
            origin_wait            <= 4'd0;
            origin_tog             <= 1'b0;
            cam_frame_start_bin   <= {FRAME_EVENT_W{1'b0}};
            cam_frame_end_bin     <= {FRAME_EVENT_W{1'b0}};
            cam_frame_start_gray  <= {FRAME_EVENT_W{1'b0}};
            cam_frame_end_gray    <= {FRAME_EVENT_W{1'b0}};
            cap_overflow_latched <= 1'b0;
        end else begin
            cap_rd_gray_sync1 <= cap_rd_gray;
            cap_rd_gray_sync2 <= cap_rd_gray_sync1;
            cam_vs_d          <= i_vs;
            if (!i_vs)
                vs_armed <= 1'b1;

            // The stored frame starts at a rising edge that followed a low
            // sample, and it stops after exactly one 1080p frame.  origin_bin
            // is that edge's write pointer; the start event follows it so
            // the AXI side can skip anything older without a pointer jump.
            if (vs_armed && !cam_vs_d && i_vs) begin
                cam_frame_active <= 1'b1;
                cap_frame_dropped <= 1'b0;
                cap_kept         <= 20'd0;
                cap_mode         <= i_store_mode;
                origin_mode      <= i_store_mode;
                origin_format<=i_cam_60 ? 2'd3 : i_store_mode;
                origin_bin       <= cap_wr_bin;
                origin_arm       <= 1'b1;
            end else if (origin_arm) begin
                origin_tog       <= ~origin_tog;
                origin_arm       <= 1'b0;
                origin_wait      <= 4'd8;
            end else if (origin_wait != 4'd0) begin
                if (origin_wait == 4'd1) begin
                    cam_frame_start_bin  <= cam_frame_start_bin + 1'b1;
                    cam_frame_start_gray <= event_bin_to_gray(cam_frame_start_bin + 1'b1);
                end
                origin_wait      <= origin_wait - 4'd1;
            end else if (cam_frame_active && cam_vs_d && !i_vs) begin
                cam_frame_active    <= 1'b0;
                cap_frame_good <= (cap_kept == cap_words_for(cap_mode)) && !cap_frame_dropped;
                cam_frame_end_bin   <= cam_frame_end_bin + 1'b1;
                cam_frame_end_gray  <= event_bin_to_gray(cam_frame_end_bin + 1'b1);
            end

            if (cap_mem_we) begin
                cap_wr_bin  <= cap_wr_bin_next;
                cap_wr_gray <= cap_wr_gray_next;
                cap_kept    <= cap_kept + 20'd1;
            end

            // cap_mem_we is intentionally suppressed when cap_full is true.
            // Keep a sticky diagnostic so a short overflow pulse remains
            // visible until the video-path reset is asserted.
            if (i_de && cam_frame_active && cap_full && !cap_frame_full) begin
                cap_overflow_latched <= 1'b1;
                cap_frame_dropped <= 1'b1;
            end
        end
    end

    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            cap_wr_gray_sync1 <= {CAP_PTR_W{1'b0}};
            cap_wr_gray_sync2 <= {CAP_PTR_W{1'b0}};
            cam_frame_start_meta <= 1'b0;
            cam_frame_start_axi  <= 1'b0;
            cam_frame_end_meta   <= 1'b0;
            cam_frame_end_axi    <= 1'b0;
            origin_tog_meta      <= 1'b0;
            origin_tog_axi       <= 1'b0;
            origin_tog_axi_d     <= 1'b0;
            origin_bin_axi       <= {CAP_PTR_W{1'b0}};
            origin_mode_axi      <= 2'd0;
            origin_format_axi<=0;
            cap_overflow_axi_meta<= 1'b0;
            cap_overflow_axi     <= 1'b0;
            cap_good_meta<=0; cap_good_axi<=0; cam60_meta<=0; cam60_axi<=0;
        end else begin
            cap_wr_gray_sync1 <= cap_wr_gray;
            cap_wr_gray_sync2 <= cap_wr_gray_sync1;
            cam_frame_start_meta <= cam_frame_start_gray;
            cam_frame_start_axi  <= cam_frame_start_meta;
            cam_frame_end_meta   <= cam_frame_end_gray;
            cam_frame_end_axi    <= cam_frame_end_meta;
            origin_tog_meta      <= origin_tog;
            origin_tog_axi       <= origin_tog_meta;
            origin_tog_axi_d     <= origin_tog_axi;
            if (origin_tog_axi != origin_tog_axi_d) begin
                origin_bin_axi  <= origin_bin;
                origin_mode_axi <= origin_mode;
                origin_format_axi<=origin_format;
            end
            cap_overflow_axi_meta<= cap_overflow_latched;
            cap_overflow_axi     <= cap_overflow_axi_meta;
            cap_good_meta<=cap_frame_good; cap_good_axi<=cap_good_meta;
            cam60_meta<=i_cam_60; cam60_axi<=cam60_meta;
        end
    end

    assign cap_fifo_overflow = cap_overflow_axi;


    // ---------------------------------------------------------------------
    // AXI write path: one in-flight incrementing burst at a time.
    // ---------------------------------------------------------------------
    localparam W_IDLE = 3'd0;
    localparam W_AW   = 3'd1;
    localparam W_DATA = 3'd2;
    localparam W_RESP = 3'd3;
    localparam W_DONE = 3'd4;
    localparam W_LOAD = 3'd5;
    localparam W_STORE= 3'd6;
    localparam W_WAIT_COMMIT = 3'd7;

    reg [2:0] wstate;
    reg [AXI_ADDR_WIDTH-1:0] wr_addr;
    reg [31:0] wr_words_left;
    reg [BEAT_CNT_W-1:0] wr_burst_beats;
    reg [BEAT_CNT_W-1:0] wr_beat;
    reg [AXI_DATA_WIDTH-1:0] wdata_reg;
    reg [2:0] cap_load_index;
    reg [CAP_PTR_W-1:0] cap_load_ptr;
    reg write_done;
    reg [FRAME_EVENT_W-1:0] frame_start_seen;
    reg [FRAME_EVENT_W-1:0] frame_end_seen;
    reg [FRAME_EVENT_W-1:0] pending_start_event;
    reg [FRAME_EVENT_W-1:0] wr_expected_end;
    // Sticky per-writer poison: padding state is intentionally cleared after
    // the final response, so it cannot also serve as publication history.
    reg wr_frame_invalid;
    reg [1:0] pending_origin_mode,pending_origin_format;
    reg [1:0] wr_bank;
    reg [1:0] wr_mode,wr_format;
    reg [1:0] display_bank;
    // Camera is 1080p30, HDMI is 1080p60, so a bank is displayed twice.
    // Two-bank ping-pong then writes back onto the bank HDMI is still
    // reading (~33 ms hold).  Rotate through three banks and never pick
    // the live display bank.
    // Latest completed camera bank and NPU-owned bank must not be overwritten.
    reg [1:0] next_wr_bank;
    reg bank_found;
    integer bank_offset,bank_candidate;
    // If every non-display bank is owned by the NPU, active display, or
    // pending display handoff, bank_found stays low.  The write FSM waits
    // for a safe slot instead of falling back onto display_bank.
    always @* begin
        next_wr_bank=display_bank;bank_found=0;bank_candidate=0;
        for(bank_offset=1;bank_offset<FB_NUM;bank_offset=bank_offset+1) begin
            bank_candidate=display_bank+bank_offset;
            if(bank_candidate>=FB_NUM)bank_candidate=bank_candidate-FB_NUM;
            if(!bank_found && !(npu_lock && bank_candidate==npu_locked_bank) &&
               !(DISPLAY_LOCK_ENABLE && display_lock && bank_candidate==display_locked_bank) &&
               !(DISPLAY_LOCK_ENABLE && pending_display_lock && bank_candidate==pending_display_locked_bank)) begin
                next_wr_bank=bank_candidate[1:0];bank_found=1;
            end
        end
    end
    wire wr_bank_reserved = (wr_bank==display_bank) ||
        (npu_lock && wr_bank==npu_locked_bank) ||
        (DISPLAY_LOCK_ENABLE && display_lock && wr_bank==display_locked_bank) ||
        (DISPLAY_LOCK_ENABLE && pending_display_lock && wr_bank==pending_display_locked_bank);
`ifndef SYNTHESIS
    reg aw_stalled_q;
    reg [AXI_ADDR_WIDTH-1:0] aw_stalled_addr_q;
    always @(posedge axi_clk or negedge rst_n) begin
        if(!rst_n)begin aw_stalled_q<=1'b0;aw_stalled_addr_q<={AXI_ADDR_WIDTH{1'b0}};end
        else begin
            if(wstate==W_AW && wr_bank_reserved)
                $fatal(1,"camera writer selected a bank owned by display/NPU");
            if(aw_stalled_q && (!awvalid || awaddr!=aw_stalled_addr_q))
                $fatal(1,"camera AWVALID/address changed before AWREADY");
            aw_stalled_q<=awvalid && !awready;
            if(awvalid && !awready)aw_stalled_addr_q<=awaddr;
        end
    end
`endif
    assign capture_base = frame_bank_base(display_bank);
    reg axi_error_w;
    reg frame_pad;
    reg discarding;
    reg discard_ready;
    reg [CAP_PTR_W-1:0] discard_target;
    reg axi_error_rd;
    reg rd_fifo_full_latched;
    reg [1:0] rd_tokens;

    wire [FRAME_EVENT_W-1:0] wr_end_delta = event_gray_delta(cam_frame_end_axi,wr_expected_end);
    wire wr_end_exact = (wr_end_delta == {FRAME_EVENT_W{1'b0}});
    // Modular ordering is valid inside the half-range. Exactly half-range is
    // ambiguous, so handle it as an overrun and never publish that writer.
    wire wr_end_reached = !wr_end_delta[FRAME_EVENT_W-1] ||
                          (wr_end_delta == FRAME_EVENT_HALF);

    // simple_dual_port_ram has a synchronous read port.  W_LOAD issues the
    // address and W_STORE consumes the registered result on the next clock.
    assign cap_mem_re = (wstate == W_LOAD) &&
                        (cap_used >= CAP_WORDS_PER_BEAT);

    simple_dual_port_ram #(
        .DATA_WIDTH(I_VID_WIDTH),
        .ADDR_WIDTH(CAP_ADDR_W),
        .OUTPUT_REG("FALSE"),
        .RAM_INIT_FILE("")
    ) cap_mem_inst (
        .wdata(vin),
        .waddr(cap_wr_bin[CAP_ADDR_W-1:0]),
        .raddr(cap_load_ptr[CAP_ADDR_W-1:0]),
        .we(cap_mem_we),
        .wclk(i_clk),
        .re(cap_mem_re),
        .rclk(axi_clk),
        .rdata(cap_mem_rdata)
    );

    wire [BEAT_CNT_W-1:0] wr_next_burst_beats =
        (wr_words_left > BURST_BEATS) ? BURST_BEATS[BEAT_CNT_W-1:0]
                                      : wr_words_left[BEAT_CNT_W-1:0];
    // Last-beat write replay did not remove the stripes; leave writes sequential.

    // HDMI needs the read FIFO ahead of the raster, but a full "reads
    // always win" hold starved camera writes: dropped CSI words shear
    // the picture into the diagonal streaks in the last photo. Keep
    // two lines of HDMI cushion; above that, the 1:1 token lets writes
    // through. Still require a full burst in the capture FIFO before AW
    // so W_LOAD cannot sit on the bus.
    wire cap_critical = (cap_used >= CAP_CRITICAL_LEVEL);
    wire [CAP_PTR_W-1:0] wr_need_cap = wr_next_burst_beats * CAP_WORDS_PER_BEAT_PTR;
    wire wr_data_ready = frame_pad || (cap_used >= wr_need_cap);
    wire fifo_low = (fifo_used < 12'd480);
    // Reserve a complete burst before exposing AW. No FIFO pops occur in W_AW,
    // so readiness is monotonic until its address handshake.
    reg wr_aw_ready_q;
    always @(posedge axi_clk or negedge rst_n) begin
        if(!rst_n)wr_aw_ready_q <= 1'b0;
        else if(wstate != W_AW)wr_aw_ready_q <= 1'b0;
        else wr_aw_ready_q <= wr_aw_ready_q || wr_data_ready;
    end
    // Global arbiter handles service priority. AW stays stable once offered.
    wire wr_hold = 1'b0;
    assign capture_urgent = cap_critical;
    assign display_urgent = fifo_used < 12'd256;

    always @(*) begin
        awid    = {AXI_ID_WIDTH{1'b0}};
        awaddr  = wr_addr;
        awlen   = (wstate == W_AW) ? ((wr_next_burst_beats == 0) ? 8'd0 : wr_next_burst_beats - 1'b1) :
                  ((wr_burst_beats == 0) ? 8'd0 : wr_burst_beats - 1'b1);
        awsize  = $clog2(BYTES_PER_BEAT);
        awburst = 2'b01; // INCR
        awcache = 4'b0011;
        awprot  = 3'b010;
        awlock  = 1'b0;
        awqos   = 4'b0000;
        awvalid = (wstate == W_AW) && !wr_hold && wr_aw_ready_q;

        wdata   = wdata_reg;
        wstrb   = {AXI_DATA_WIDTH/8{1'b1}};
        wlast   = (wstate == W_DATA) && (wr_beat == wr_burst_beats - 1'b1);
        wvalid  = (wstate == W_DATA);
        bready  = (wstate == W_RESP);
    end

    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate        <= W_IDLE;
            wr_addr       <= START_ADDR;
            wr_words_left <= 32'd0;
            wr_burst_beats<= {BEAT_CNT_W{1'b0}};
            wr_beat       <= {BEAT_CNT_W{1'b0}};
            wdata_reg     <= {AXI_DATA_WIDTH{1'b0}};
            cap_load_index<= 3'd0;
            cap_load_ptr  <= {CAP_PTR_W{1'b0}};
            cap_rd_bin    <= {CAP_PTR_W{1'b0}};
            cap_rd_gray   <= {CAP_PTR_W{1'b0}};
            write_done    <= 1'b0;
            capture_sequence <= 0;capture_mode<=2;wr_format<=2;
            frame_start_seen <= {FRAME_EVENT_W{1'b0}};
            frame_end_seen   <= {FRAME_EVENT_W{1'b0}};
            pending_start_event <= {FRAME_EVENT_W{1'b0}};
            wr_expected_end <= {FRAME_EVENT_W{1'b0}};
            wr_frame_invalid <= 1'b0;
            pending_origin_mode <= 2'd0;
            pending_origin_format <= 2'd0;
            wr_bank          <= 2'd0;
            wr_mode          <= 2'd0;
            display_bank     <= 2'd0;
            axi_error_w   <= 1'b0;
            rd_tokens     <= 2'd0;
            frame_pad     <= 1'b0;
            discarding    <= 1'b0;
            discard_ready <= 1'b0;
            discard_target<= {CAP_PTR_W{1'b0}};
        end else begin
            // A finished HDMI read pays back one token.  The write-response
            // arm below overrides this in the same cycle.
            if ((rstate == R_DATA) && rvalid && rready &&
                (rbeat_is_last || rlast) && (rd_tokens != 2'd0) &&
                (wstate != W_RESP))
                rd_tokens <= rd_tokens - 2'd1;

            // VS ending does NOT mean the capture FIFO has been drained.
            // A complete frame still owns its queued tail: write it normally.
            // Only an incomplete/rejected frame may pad and be discarded.
            if ((wstate != W_IDLE) && (wstate != W_DONE) &&
                (wstate != W_WAIT_COMMIT) &&
                wr_end_reached && (!wr_end_exact || !cap_good_axi)) begin
                frame_pad <= 1'b1;
                wr_frame_invalid <= 1'b1;
            end

            case (wstate)
                W_IDLE: begin
                    if (discarding) begin
                        if (cap_rd_bin != discard_target) begin
                            cap_rd_bin  <= cap_rd_bin + 1'b1;
                            cap_rd_gray <= cap_bin_to_gray(cap_rd_bin + 1'b1);
                        end else
                            discarding <= 1'b0;
                    end else if (!discard_ready && ddr_init_done &&
                                 (cam_frame_start_axi != frame_start_seen)) begin
                        frame_start_seen <= cam_frame_start_axi;
                        pending_start_event <= cam_frame_start_axi;
                        pending_origin_mode <= origin_mode_axi;
                        pending_origin_format <= origin_format_axi;
                        discard_target   <= origin_bin_axi;
                        discarding       <= 1'b1;
                        discard_ready    <= 1'b1;
                    end else if (discard_ready && !bank_found) begin
                        // Drop this frame. Wait for the next frame_start and
                        // realign cap_rd_bin before accepting a newer payload.
                        discard_ready <= 1'b0;
                    end else if (discard_ready && bank_found &&
                                 (cap_used >= CAP_WORDS_PER_BEAT)) begin
                        discard_ready    <= 1'b0;
                        wr_bank          <= next_wr_bank;
                        wr_mode          <= pending_origin_mode;
                        wr_format<=pending_origin_format;
                        wr_addr          <= frame_bank_base(next_wr_bank);
                        wr_words_left    <= axi_words_for(pending_origin_mode);
                        wr_expected_end  <= pending_start_event;
                        frame_pad        <= 1'b0;
                        wr_frame_invalid <= 1'b0;
                        wstate           <= W_AW;
                    end
                end

                W_AW: begin
                    if (awvalid && awready) begin
                        wr_beat <= {BEAT_CNT_W{1'b0}};
                        wr_burst_beats <= wr_next_burst_beats;
                        cap_load_index <= 3'd0;
                        cap_load_ptr   <= cap_rd_bin;
                        wstate         <= W_LOAD;
                    end
                end

                W_LOAD: begin
                    if (frame_pad) begin
                        wdata_reg <= {AXI_DATA_WIDTH{1'b0}};
                        wstate    <= W_DATA;
                    end else if (cap_used >= CAP_WORDS_PER_BEAT) begin
                        wstate <= W_STORE;
                    end
                end

                W_STORE: begin
                    // Camera words arrive as {p0,p1,p2,p3}, high lane first.
                    // DDR RGB565 uses increasing x in increasing byte addresses:
                    // p0 at AXI[15:0], p7 at AXI[127:112]. Reverse the four
                    // 16-bit lanes and store the first word in the low half.
                    // Pixel bytes/colour fields are unchanged; this is wiring.
                    // The legacy HDMI reader still consumes high lanes first.
                    case (cap_load_index)
                        3'd0: wdata_reg[63:0] <=
                            {cap_mem_rdata[15:0], cap_mem_rdata[31:16],
                             cap_mem_rdata[47:32], cap_mem_rdata[63:48]};
                        default: wdata_reg[127:64] <=
                            {cap_mem_rdata[15:0], cap_mem_rdata[31:16],
                             cap_mem_rdata[47:32], cap_mem_rdata[63:48]};
                    endcase

                    cap_load_ptr <= cap_load_ptr + 1'b1;
                    if (cap_load_index == CAP_WORDS_PER_BEAT - 1) begin
                        cap_rd_bin  <= cap_rd_bin + CAP_WORDS_PER_BEAT_PTR;
                        cap_rd_gray <= cap_bin_to_gray(cap_rd_bin + CAP_WORDS_PER_BEAT_PTR);
                        cap_load_index <= 3'd0;
                        wstate <= W_DATA;
                    end else begin
                        cap_load_index <= cap_load_index + 1'b1;
                        wstate <= W_LOAD;
                    end
                end

                W_DATA: begin
                    if (wvalid && wready) begin
                        if (wlast) begin
                            wstate <= W_RESP;
                        end else begin
                            wr_beat <= wr_beat + 1'b1;
                            cap_load_index <= 3'd0;
                            cap_load_ptr <= cap_rd_bin;
                            wstate <= W_LOAD;
                        end
                    end
                end

                W_RESP: begin
                    if (bvalid && bready) begin
                        if (bresp != 2'b00)
                            axi_error_w <= 1'b1;

                        if (wr_words_left <= wr_burst_beats) begin
                            wr_words_left <= 32'd0;
                            rd_tokens     <= 2'd0;
                            frame_pad     <= 1'b0;
                            wstate        <= W_WAIT_COMMIT;
                        end else begin
                            wr_words_left <= wr_words_left - wr_burst_beats;
                            wr_addr       <= wr_addr + wr_burst_beats * BYTES_PER_BEAT;
                            rd_tokens     <= cam60_axi ? 2'd1 : 2'd2;
                            wstate        <= W_AW;
                        end
                    end
                end

                W_WAIT_COMMIT: begin
                    // The fixed-size stream has finished writing this
                    // frame. Only its matching end event may publish it. A
                    // later event means this writer missed its frame and is
                    // drained without exposing unrelated camera data.
                    if (wr_frame_invalid || wr_end_reached) begin
                        frame_end_seen <= cam_frame_end_axi;
                        if (!wr_end_exact || !cap_good_axi || frame_pad)
                            wr_frame_invalid <= 1'b1;
                        if (wr_end_exact && cap_good_axi && !frame_pad && !wr_frame_invalid) begin
                            display_bank   <= wr_bank;
                            write_done     <= 1'b1;
                            capture_sequence <= capture_sequence + 1'b1;
                            capture_mode<=wr_format;
                        end
                        wstate         <= W_DONE;
                    end
                end

                W_DONE: begin
                    // Skip leftover words from the previous frame one step
                    // at a time, then write the next bank.
                    if (discarding) begin
                        if (cap_rd_bin != discard_target) begin
                            cap_rd_bin  <= cap_rd_bin + 1'b1;
                            cap_rd_gray <= cap_bin_to_gray(cap_rd_bin + 1'b1);
                        end else
                            discarding <= 1'b0;
                    end else if (!discard_ready && ddr_init_done &&
                                 (cam_frame_start_axi != frame_start_seen)) begin
                        frame_start_seen <= cam_frame_start_axi;
                        pending_start_event <= cam_frame_start_axi;
                        pending_origin_mode <= origin_mode_axi;
                        pending_origin_format <= origin_format_axi;
                        discard_target   <= origin_bin_axi;
                        discarding       <= 1'b1;
                        discard_ready    <= 1'b1;
                    end else if (discard_ready && !bank_found) begin
                        discard_ready <= 1'b0;
                    end else if (discard_ready && bank_found &&
                                 (cap_used >= CAP_WORDS_PER_BEAT)) begin
                        discard_ready    <= 1'b0;
                        wr_bank          <= next_wr_bank;
                        wr_mode          <= pending_origin_mode;
                        wr_format<=pending_origin_format;
                        wr_addr          <= frame_bank_base(next_wr_bank);
                        wr_words_left    <= axi_words_for(pending_origin_mode);
                        wr_expected_end  <= pending_start_event;
                        frame_pad        <= 1'b0;
                        wr_frame_invalid <= 1'b0;
                        wstate           <= W_AW;
                    end
                end

                default: wstate <= W_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // Asynchronous 128-bit read FIFO.  AXI R beats are written in axi_clk;
    // the video clock consumes one 16-bit RAW10 container at a time.
    // ---------------------------------------------------------------------
    // The video-side read port is synchronous so Efinity can infer a true
    // dual-port block RAM instead of expanding this CDC FIFO into logic.
    reg [FIFO_PTR_W-1:0] fifo_wr_bin;
    reg [FIFO_PTR_W-1:0] fifo_wr_gray;
    reg [FIFO_PTR_W-1:0] fifo_rd_bin;
    reg [FIFO_PTR_W-1:0] fifo_rd_gray;
    (* async_reg = "true" *) reg [FIFO_PTR_W-1:0] fifo_rd_gray_sync1;
    (* async_reg = "true" *) reg [FIFO_PTR_W-1:0] fifo_rd_gray_sync2;
    (* async_reg = "true" *) reg [FIFO_PTR_W-1:0] fifo_wr_gray_sync1;
    (* async_reg = "true" *) reg [FIFO_PTR_W-1:0] fifo_wr_gray_sync2;
    wire [FIFO_PTR_W-1:0] fifo_rd_bin_sync = gray_to_bin(fifo_rd_gray_sync2);
    assign fifo_used = fifo_wr_bin - fifo_rd_bin_sync;
    wire [FIFO_PTR_W-1:0] fifo_wr_bin_next = fifo_wr_bin + 1'b1;
    wire [FIFO_PTR_W-1:0] fifo_wr_gray_next = bin_to_gray(fifo_wr_bin_next);
    wire fifo_full = (fifo_wr_gray_next ==
                      {~fifo_rd_gray_sync2[FIFO_PTR_W-1:FIFO_PTR_W-2],
                        fifo_rd_gray_sync2[FIFO_PTR_W-3:0]});
    wire fifo_empty = (fifo_rd_gray == fifo_wr_gray_sync2);

    reg [BEAT_CNT_W-1:0] rd_beat;
    reg [BEAT_CNT_W-1:0] rd_burst_beats;

    wire fifo_mem_we =
        ((rstate == R_DATA) && rvalid && rready && !fifo_full);
    wire fifo_mem_re;
    wire [AXI_DATA_WIDTH-1:0] fifo_mem_rdata;
    reg fifo_rd_pending;

    simple_dual_port_ram #(
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ADDR_WIDTH(FIFO_ADDR_W),
        .OUTPUT_REG("FALSE"),
        .RAM_INIT_FILE("")
    ) fifo_mem_inst (
        .wdata(rdata),
        .waddr(fifo_wr_bin[FIFO_ADDR_W-1:0]),
        .raddr(fifo_rd_bin[FIFO_ADDR_W-1:0]),
        .we(fifo_mem_we),
        .wclk(axi_clk),
        .re(fifo_mem_re),
        .rclk(o_clk),
        .rdata(fifo_mem_rdata)
    );

    wire [AXI_DATA_WIDTH-1:0] fifo_rd_data = fifo_mem_rdata;

    // Read FIFO write side and synchronization of the read pointer.
    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_bin      <= {FIFO_PTR_W{1'b0}};
            fifo_wr_gray     <= {FIFO_PTR_W{1'b0}};
            fifo_rd_gray_sync1 <= {FIFO_PTR_W{1'b0}};
            fifo_rd_gray_sync2 <= {FIFO_PTR_W{1'b0}};
            rd_fifo_full_latched <= 1'b0;
        end else begin
            fifo_rd_gray_sync1 <= fifo_rd_gray;
            fifo_rd_gray_sync2 <= fifo_rd_gray_sync1;

            // Drop stale beats once the read address is back at pixel 0.
            // This only happens in R_WAIT, so it cannot collide with a beat.
            if (resync_req_axi && !resync_ack && (rstate == R_WAIT)) begin
                fifo_wr_bin  <= {FIFO_PTR_W{1'b0}};
                fifo_wr_gray <= {FIFO_PTR_W{1'b0}};
            end else if ((rstate == R_DATA) && rvalid && rready && !fifo_full &&
                         !resync_req_axi) begin
                fifo_wr_bin  <= fifo_wr_bin_next;
                fifo_wr_gray <= fifo_wr_gray_next;
            end

            // rready is deasserted while fifo_full, so this condition does
            // not indicate dropped AXI data.  It records that the read FIFO
            // reached its capacity and applied backpressure.
            if ((rstate == R_DATA) && rvalid && fifo_full)
                rd_fifo_full_latched <= 1'b1;
        end
    end

    assign rd_fifo_full_seen = rd_fifo_full_latched;
    assign rd_fifo_empty_seen = rd_fifo_empty_latched;

    // ---------------------------------------------------------------------
    // AXI read path: issue a burst only when the asynchronous FIFO has room
    // for the whole burst.  The address advances through the committed
    // display bank and switches banks only at a complete frame boundary.
    // ---------------------------------------------------------------------
    reg display_initialized;
    reg [1:0] active_final_mode;
    reg [AXI_ADDR_WIDTH-1:0] rd_addr;
    reg [31:0] rd_words_left;
    reg [1:0] rd_bank;
    reg       rd_hold;
    (* async_reg = "true" *) reg       resync_req_meta;

    wire [BEAT_CNT_W-1:0] rd_next_burst_beats =
        (rd_words_left > BURST_BEATS) ? BURST_BEATS[BEAT_CNT_W-1:0]
                                      : rd_words_left[BEAT_CNT_W-1:0];
    assign rbeat_is_last = (rd_beat == rd_burst_beats - 1'b1);
    assign fifo_can_accept_burst =
        (rd_next_burst_beats != 0) &&
        (fifo_used <= (RD_FIFO_DEPTH - rd_next_burst_beats));

    always @(*) begin
        arid    = {{(AXI_ID_WIDTH-1){1'b0}}, 1'b1};
        araddr  = rd_addr;
        arlen   = (rstate == R_AR) ? ((rd_next_burst_beats == 0) ? 8'd0 : rd_next_burst_beats - 1'b1) :
                  ((rd_burst_beats == 0) ? 8'd0 : rd_burst_beats - 1'b1);
        arsize  = $clog2(BYTES_PER_BEAT);
        arburst = 2'b01; // INCR
        arcache = 4'b0011;
        arprot  = 3'b010;
        arlock  = 1'b0;
        arqos   = 4'b0000;
        arvalid = (rstate == R_AR);
        // During a vsync restart, finish the open burst even if the FIFO
        // is full.  Those beats are dropped instead of stored.
        rready  = (rstate == R_DATA) && (!fifo_full || resync_req_axi);
    end

    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate        <= R_WAIT;
            rd_addr       <= demo_bus_pkg::FINAL_A;
            active_final_base <= 0;
            display_initialized <= 0;active_final_mode<=2;
            rd_words_left <= axi_words_for(2'd0);
            rd_burst_beats<= {BEAT_CNT_W{1'b0}};
            rd_beat       <= {BEAT_CNT_W{1'b0}};
            rd_bank       <= 2'd0;
            rd_hold       <= 1'b0;
            axi_error_rd  <= 1'b0;
            resync_req_meta <= 1'b0;
            resync_req_axi  <= 1'b0;
            resync_ack      <= 1'b0;
        end else begin
            resync_req_meta <= resync_req;
            resync_req_axi  <= resync_req_meta;
            // Restart at pixel 0 only between bursts, so an accepted
            // AR is always drained.  New reads wait until the video
            // side has dropped the request.
            if (!display_initialized && final_valid && (rstate == R_WAIT)) begin
                rd_addr <= final_base;
                active_final_base <= final_base;
                active_final_mode<=final_mode;
                rd_words_left <= axi_words_for(final_mode==3 ? 2'd2 : final_mode);
                rd_hold <= 0;
                display_initialized <= 1;
            end else if (resync_req_axi && !resync_ack && (rstate == R_WAIT)) begin
                // All old AR/R have drained before this frame-boundary publish.
                rd_addr       <= final_base;
                active_final_base <= final_base;
                active_final_mode<=final_mode;
                rd_bank       <= display_bank;
                rd_words_left <= axi_words_for(final_mode==3 ? 2'd2 : final_mode);
                rd_beat       <= {BEAT_CNT_W{1'b0}};
                rd_hold       <= 1'b0;
                resync_ack    <= 1'b1;
            end else begin
            if (!resync_req_axi)
                resync_ack <= 1'b0;
            case (rstate)
                R_WAIT: begin
                    if (final_valid && display_initialized && fifo_can_accept_burst && !resync_req_axi && !rd_hold)
                        rstate <= R_AR;
                end

                R_AR: begin
                    if (arvalid && arready) begin
                        rd_burst_beats <= rd_next_burst_beats;
                        rd_beat        <= {BEAT_CNT_W{1'b0}};
                        rstate         <= R_DATA;
                    end
                end

                R_DATA: begin
                    if (rvalid && rready) begin
                        if (rresp != 2'b00)
                            axi_error_rd <= 1'b1;

                        if (rbeat_is_last || rlast) begin
                            if (rd_words_left <= rd_burst_beats) begin
                                // One frame is in the FIFO or already on
                                // screen.  Do not start the next copy until
                                // the raster vsync reloads pixel 0.
                                rd_words_left <= axi_words_for(active_final_mode==3 ? 2'd2 : active_final_mode);
                                rd_hold       <= 1'b1;
                            end else begin
                                rd_words_left <= rd_words_left - rd_burst_beats;
                                rd_addr       <= rd_addr + rd_burst_beats * BYTES_PER_BEAT;
                            end
                            rstate <= R_WAIT;
                        end else begin
                            rd_beat <= rd_beat + 1'b1;
                        end
                    end
                end

                default: rstate <= R_WAIT;
            endcase
            end
        end
    end

    // ---------------------------------------------------------------------
    // Video-side FIFO read and timing generator.
    // ---------------------------------------------------------------------
    (* async_reg = "true" *) reg write_done_v0;
    (* async_reg = "true" *) reg write_done_v1;
    reg video_started;
    reg [AXI_DATA_WIDTH-1:0] pixel_shift;
    reg [BEAT_CNT_W-1:0] pixel_index;
    reg pixel_word_valid;
    // Sticky video-side read FIFO underflow indication.  This is only set
    // after video timing has started, so the intentional startup wait for
    // the first committed frame does not trigger it.
    // An underrun invalidates the source/raster correspondence. Blank the
    // rest of this frame, then restart DDR and FIFO at the existing VS
    // handshake. Resuming a late FIFO word in this raster shifts every pixel.
    reg frame_aborted;
    reg [12:0] h_count;
    reg [12:0] v_count;
    (* async_reg = "true" *) reg resync_ack_meta;
    (* async_reg = "true" *) reg resync_ack_vid;
    reg resync_busy;
    reg [1:0] vid_mode_hold;

    // One-cycle request/response pipeline for the synchronous video-side
    // RAM read. The read pointer advances when the RAM read is issued;
    // pixel_word_valid is asserted when the registered data returns.
    wire resync_hold = resync_req || resync_busy;
    wire fifo_rd_request;
    wire fifo_rd_prefetch_request;
    assign fifo_mem_re = fifo_rd_request || fifo_rd_prefetch_request;

    wire h_active = (h_count >= H_SYNC + H_BACK_PORCH) &&
                    (h_count < H_SYNC + H_BACK_PORCH + H_VALID);
    wire v_active = (v_count >= V_SYNC + V_BACK_PORCH) &&
                    (v_count < V_SYNC + V_BACK_PORCH + V_VALID);
    wire video_active = h_active && v_active;
    wire [12:0] src_w = (vid_mode_hold == 2'd1) ? 13'd1280 :
                        (vid_mode_hold == 2'd2) ? 13'd854  : 13'd1920;
    wire [12:0] src_stride = (vid_mode_hold==2'd2) ? 13'd864 : src_w;
    wire [12:0] src_h = (vid_mode_hold == 2'd1) ? 13'd720 :
                        (vid_mode_hold == 2'd2) ? 13'd480  : 13'd1080;
    wire src_v_active = (v_count >= V_SYNC + V_BACK_PORCH) &&
                        (v_count < V_SYNC + V_BACK_PORCH + src_h);
    wire [12:0] src_h_beg = H_SYNC + H_BACK_PORCH;
    wire [12:0] src_h_end = src_h_beg + src_stride;
    // Prefetch the first AXI word during HSYNC+HBP. Completing that RAM
    // read must not wait for line_body: the old fifo_allow term excluded
    // fifo_rd_pending, so the word only landed on the first DE cycle and
    // every line lost one pixel (45-degree shear).
    wire h_pre_active = src_v_active && (h_count < src_h_beg);
    wire line_body = src_v_active && (h_count >= src_h_beg) &&
                     (h_count < src_h_end);
    wire fifo_allow = line_body ||
                      (h_pre_active && !pixel_word_valid);
    wire pixel_missing = line_body && !pixel_word_valid && !fifo_rd_pending;
    assign fifo_rd_request = !resync_hold && !frame_aborted && !pixel_missing && !pixel_word_valid && !fifo_rd_pending &&
                             !fifo_empty && fifo_allow;
    assign fifo_rd_prefetch_request = !resync_hold && !frame_aborted && pixel_word_valid && line_body &&
                                      (h_count < src_h_end - PIXELS_PER_WORD[12:0]) &&
                                      (pixel_index == PIXELS_PER_WORD - 2) &&
                                      !fifo_rd_pending && !fifo_empty;

    always @(posedge o_clk or negedge output_rst_n) begin
        if (!output_rst_n) begin
            fifo_wr_gray_sync1 <= {FIFO_PTR_W{1'b0}};
            fifo_wr_gray_sync2 <= {FIFO_PTR_W{1'b0}};
            fifo_rd_bin        <= {FIFO_PTR_W{1'b0}};
            fifo_rd_gray       <= {FIFO_PTR_W{1'b0}};
            write_done_v0      <= 1'b0;
            write_done_v1      <= 1'b0;
            video_started      <= 1'b0;
            pixel_shift        <= {AXI_DATA_WIDTH{1'b0}};
            pixel_index        <= {BEAT_CNT_W{1'b0}};
            pixel_word_valid   <= 1'b0;
            fifo_rd_pending    <= 1'b0;
            rd_fifo_empty_latched <= 1'b0;
            frame_aborted      <= 1'b0;
            h_count            <= 13'd0;
            v_count            <= 13'd0;
            o_hs               <= 1'b0;
            o_vs               <= 1'b0;
            o_de               <= 1'b0;
            vout               <= {O_VID_WIDTH{1'b0}};
            resync_req         <= 1'b0;
            resync_ack_meta    <= 1'b0;
            resync_ack_vid     <= 1'b0;
            resync_busy        <= 1'b0;
            vid_mode_hold      <= 2'd0;
        end else begin
            fifo_wr_gray_sync1 <= fifo_wr_gray;
            fifo_wr_gray_sync2 <= fifo_wr_gray_sync1;
            write_done_v0      <= final_valid;
            write_done_v1      <= write_done_v0;

            if (!video_started) begin
                h_count <= 13'd0;
                v_count <= 13'd0;
                o_hs    <= 1'b0;
                o_vs    <= 1'b0;
                o_de    <= 1'b0;
                vout    <= {O_VID_WIDTH{1'b0}};
                if (write_done_v1 && (pixel_word_valid || !fifo_empty))
                    video_started <= 1'b1;
            end else begin
                o_hs <= (h_count < H_SYNC);
                o_vs <= (v_count < V_SYNC);
                o_de <= video_active;
                resync_ack_meta <= resync_ack;
                resync_ack_vid  <= resync_ack_meta;

                // Realign to pixel 0 at the start of vertical blanking.
                // One read underrun otherwise leaves the next copy of the
                // frame glued to the bottom of the raster.
                if ((h_count == 13'd0) && (v_count == 13'd0) &&
                    !resync_req && !resync_busy) begin
                    resync_req       <= 1'b1;
                    resync_busy      <= 1'b1;
                    frame_aborted    <= 1'b0;
                    pixel_word_valid <= 1'b0;
                    fifo_rd_pending  <= 1'b0;
                    pixel_index      <= {BEAT_CNT_W{1'b0}};
                    vout             <= {O_VID_WIDTH{1'b0}};
                end else if (resync_req && resync_ack_vid) begin
                    vid_mode_hold<=active_final_mode==3 ? 2'd2 : active_final_mode;
                    fifo_rd_bin      <= {FIFO_PTR_W{1'b0}};
                    fifo_rd_gray     <= {FIFO_PTR_W{1'b0}};
                    pixel_word_valid <= 1'b0;
                    fifo_rd_pending  <= 1'b0;
                    pixel_index      <= {BEAT_CNT_W{1'b0}};
                    resync_req       <= 1'b0;
                    vout             <= {O_VID_WIDTH{1'b0}};
                end else if (resync_req && !resync_ack_vid) begin
                    // Do not pop.  Popping while the write pointer is
                    // forced to zero reads a torn FIFO and tiles the frame.
                    vout             <= {O_VID_WIDTH{1'b0}};
                    pixel_word_valid <= 1'b0;
                    fifo_rd_pending  <= 1'b0;
                end else if (resync_busy && !resync_ack_vid) begin
                    resync_busy <= 1'b0;
                    vout        <= {O_VID_WIDTH{1'b0}};
                end else begin

                if (frame_aborted || pixel_missing) begin
                    if (pixel_missing)
                        rd_fifo_empty_latched <= 1'b1;
                    frame_aborted    <= 1'b1;
                    pixel_word_valid <= 1'b0;
                    fifo_rd_pending  <= 1'b0;
                    pixel_index      <= {BEAT_CNT_W{1'b0}};
                    vout             <= {O_VID_WIDTH{1'b0}};
                end else if (line_body && pixel_word_valid) begin
                    vout        <= (h_count < src_h_beg+src_w) ?
                                   pixel_shift[pixel_index*O_VID_WIDTH +: O_VID_WIDTH] :
                                   {O_VID_WIDTH{1'b0}};
                    if (pixel_index == PIXELS_PER_WORD - 1) begin
                        if (fifo_rd_pending) begin
                            pixel_shift      <= fifo_rd_data;
                            pixel_index      <= {BEAT_CNT_W{1'b0}};
                            pixel_word_valid <= 1'b1;
                            fifo_rd_pending  <= 1'b0;
                        end else begin
                            pixel_index      <= {BEAT_CNT_W{1'b0}};
                            pixel_word_valid <= 1'b0;
                        end
                    end else begin
                        pixel_index <= pixel_index + 1'b1;
                        if (fifo_rd_prefetch_request) begin
                            fifo_rd_pending <= 1'b1;
                            fifo_rd_bin     <= fifo_rd_bin + 1'b1;
                            fifo_rd_gray    <= bin_to_gray(fifo_rd_bin + 1'b1);
                        end
                    end
                end else if (fifo_rd_pending) begin
                    // RAM data is valid this cycle. Finish the pop even
                    // in blanking so line_body starts with a ready word.
                    pixel_shift      <= fifo_rd_data;
                    pixel_word_valid <= 1'b1;
                    fifo_rd_pending  <= 1'b0;
                    if (line_body) begin
                        vout        <= fifo_rd_data[0 +: O_VID_WIDTH];
                        pixel_index <= {{(BEAT_CNT_W-1){1'b0}}, 1'b1};
                    end else begin
                        pixel_index <= {BEAT_CNT_W{1'b0}};
                        vout        <= {O_VID_WIDTH{1'b0}};
                    end
                end else if (fifo_rd_request) begin
                    fifo_rd_pending  <= 1'b1;
                    fifo_rd_bin      <= fifo_rd_bin + 1'b1;
                    fifo_rd_gray     <= bin_to_gray(fifo_rd_bin + 1'b1);
                    vout             <= {O_VID_WIDTH{1'b0}};
                end else begin
                    vout <= {O_VID_WIDTH{1'b0}};
                end
                end

                if (h_count == H_SYNC + H_BACK_PORCH + H_VALID + H_FRONT_PORCH - 1) begin
                    h_count <= 13'd0;
                    if (v_count == V_SYNC + V_BACK_PORCH + V_VALID + V_FRONT_PORCH - 1)
                        v_count <= 13'd0;
                    else
                        v_count <= v_count + 1'b1;
                end else begin
                    h_count <= h_count + 1'b1;
                end
            end
        end
    end

    assign test_rd_fifo_rddata = fifo_rd_data[31:0];
    assign test_wdata          = wdata[31:0];
    assign test_rdata          = rdata[31:0];
    assign axi_error           = axi_error_w | axi_error_rd;

    // Bring-up observability outputs (see the port comment).
    assign dbg_wstate          = wstate;
    assign dbg_rstate          = rstate;
    assign dbg_cam_frame_start = cam_frame_start_axi;
    assign dbg_cam_frame_end   = cam_frame_end_axi;
    assign dbg_cap_used        = cap_used;
    assign dbg_display_bank    = display_bank;
    assign dbg_rd_bank         = rd_bank;
    assign dbg_write_done      = write_done;
    assign dbg_video_started   = video_started;

endmodule
