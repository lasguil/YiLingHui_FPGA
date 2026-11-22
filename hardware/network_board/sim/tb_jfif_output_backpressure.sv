`timescale 1ns/1ps
module tb_jfif_output_backpressure;
    // scan_last is a packer flush sentinel, not a JPEG payload byte. The
    // writer must consume but discard that final zero before generating EOI.
    localparam integer SCAN_BYTES = 37;
    localparam integer SCAN_INPUT_BYTES = SCAN_BYTES + 1;
    localparam integer FRAME_BYTES = 623 + SCAN_BYTES + 2;
    localparam integer FRAMES = 2;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg frame_start = 1'b0;
    reg frame_done = 1'b0;
    reg scan_go = 1'b0;

    reg ref_scan_valid = 1'b0;
    reg [7:0] ref_scan_data = 8'd0;
    reg ref_scan_last = 1'b0;
    wire ref_scan_ready;
    wire ref_valid, ref_last, ref_headers_done;
    wire [7:0] ref_data;

    reg bp_scan_valid = 1'b0;
    reg [7:0] bp_scan_data = 8'd0;
    reg bp_scan_last = 1'b0;
    wire bp_scan_ready;
    wire bp_valid, bp_last, bp_headers_done;
    wire [7:0] bp_data;
    reg bp_ready = 1'b1;

    jfif_writer #(.IMG_WIDTH(64), .IMG_HEIGHT(48), .LITE_MODE(1),
                  .OUTPUT_BACKPRESSURE(0)) u_ref (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start), .frame_done(frame_done),
        .restart_interval(16'd0), .qt_rd_addr(), .qt_rd_is_chroma(), .qt_rd_data(8'd0),
        .scan_valid(ref_scan_valid), .scan_data(ref_scan_data), .scan_last(ref_scan_last),
        .scan_ready(ref_scan_ready), .m_axis_tready(1'b1),
        .m_axis_tvalid(ref_valid), .m_axis_tdata(ref_data), .m_axis_tlast(ref_last),
        .headers_done(ref_headers_done)
    );

    jfif_writer #(.IMG_WIDTH(64), .IMG_HEIGHT(48), .LITE_MODE(1),
                  .OUTPUT_BACKPRESSURE(1)) u_bp (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start), .frame_done(frame_done),
        .restart_interval(16'd0), .qt_rd_addr(), .qt_rd_is_chroma(), .qt_rd_data(8'd0),
        .scan_valid(bp_scan_valid), .scan_data(bp_scan_data), .scan_last(bp_scan_last),
        .scan_ready(bp_scan_ready), .m_axis_tready(bp_ready),
        .m_axis_tvalid(bp_valid), .m_axis_tdata(bp_data), .m_axis_tlast(bp_last),
        .headers_done(bp_headers_done)
    );

    reg [7:0] ref_bytes [0:FRAME_BYTES*FRAMES-1];
    integer ref_pos = 0;
    integer bp_pos = 0;
    integer bp_total = 0;
    integer ref_frames = 0;
    integer bp_frames = 0;
    integer bp_stall_cycles = 0;
    integer header_stall_cycles = 0;
    integer scan_stall_cycles = 0;
    integer eoi_stall_cycles = 0;
    integer ref_scan_idx = 0;
    integer bp_scan_idx = 0;
    integer ref_scan_frame = 0;
    integer bp_scan_frame = 0;
    integer frames_started = 0;
    reg [15:0] lfsr = 16'h1d0f;
    reg [4:0] stall_left = 0;
    reg saw_header_stall = 0;
    reg saw_scan_stall = 0;
    reg saw_eoi_stall = 0;
    reg prev_bp_stall = 0;
    reg [7:0] prev_bp_data = 0;
    reg prev_bp_last = 0;

    wire force_header_stall = bp_valid && (bp_pos == 0) && !saw_header_stall;
    wire force_scan_stall = bp_valid && (bp_pos == 623) && !saw_scan_stall;
    wire force_eoi_stall = bp_valid && (bp_pos == 623 + SCAN_BYTES) && !saw_eoi_stall;
    always @* begin
        bp_ready = (stall_left == 0) && !force_header_stall &&
                   !force_scan_stall && !force_eoi_stall &&
                   (lfsr[0] || lfsr[3]);
    end

    function automatic [7:0] scan_byte(input integer idx, input integer frame_idx);
        if (idx == SCAN_BYTES) scan_byte = 8'h00;
        else scan_byte = (idx * 8'h3d) ^ (idx >> 1) ^ 8'ha7 ^ (frame_idx * 8'h59);
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            ref_pos <= 0;
            bp_pos <= 0;
            bp_total <= 0;
            ref_frames <= 0;
            bp_frames <= 0;
            ref_scan_idx <= 0;
            bp_scan_idx <= 0;
            ref_scan_frame <= 0;
            bp_scan_frame <= 0;
            ref_scan_valid <= 0;
            bp_scan_valid <= 0;
            ref_scan_last <= 0;
            bp_scan_last <= 0;
            ref_scan_data <= 0;
            bp_scan_data <= 0;
            stall_left <= 0;
            saw_header_stall <= 0;
            saw_scan_stall <= 0;
            saw_eoi_stall <= 0;
            lfsr <= 16'h1d0f;
            bp_stall_cycles <= 0;
            header_stall_cycles <= 0;
            scan_stall_cycles <= 0;
            eoi_stall_cycles <= 0;
            prev_bp_stall <= 0;
            prev_bp_data <= 0;
            prev_bp_last <= 0;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};

            if (scan_go) begin
                ref_scan_idx <= 0;
                bp_scan_idx <= 0;
                ref_scan_frame <= frames_started - 1;
                bp_scan_frame <= frames_started - 1;
                ref_scan_data <= scan_byte(0, frames_started - 1);
                bp_scan_data <= scan_byte(0, frames_started - 1);
                ref_scan_last <= 1'b0;
                bp_scan_last <= 1'b0;
                ref_scan_valid <= 1;
                bp_scan_valid <= 1;
            end else begin
                if (ref_scan_valid && ref_scan_ready) begin
                    if (ref_scan_idx == SCAN_INPUT_BYTES-1) ref_scan_valid <= 0;
                    else begin
                        ref_scan_idx <= ref_scan_idx + 1;
                        ref_scan_data <= scan_byte(ref_scan_idx + 1, ref_scan_frame);
                        ref_scan_last <= (ref_scan_idx + 1 == SCAN_INPUT_BYTES-1);
                    end
                end
                if (bp_scan_valid && bp_scan_ready) begin
                    if (bp_scan_idx == SCAN_INPUT_BYTES-1) bp_scan_valid <= 0;
                    else begin
                        bp_scan_idx <= bp_scan_idx + 1;
                        bp_scan_data <= scan_byte(bp_scan_idx + 1, bp_scan_frame);
                        bp_scan_last <= (bp_scan_idx + 1 == SCAN_INPUT_BYTES-1);
                    end
                end
            end

            if (ref_valid) begin
                if (ref_pos >= FRAME_BYTES*FRAMES)
                    $fatal(1, "reference emitted too many bytes");
                ref_bytes[ref_pos] <= ref_data;
                if ((ref_pos % FRAME_BYTES) == 0 && ref_data !== 8'hFF)
                    $fatal(1, "missing SOI marker byte 0");
                if ((ref_pos % FRAME_BYTES) == 1 && ref_data !== 8'hD8)
                    $fatal(1, "missing SOI marker byte 1");
                if ((ref_pos % FRAME_BYTES) >= 623 && (ref_pos % FRAME_BYTES) < 623 + SCAN_BYTES &&
                    ref_data !== scan_byte((ref_pos % FRAME_BYTES) - 623, ref_pos / FRAME_BYTES))
                    $fatal(1, "frame %0d scan byte %0d corrupted: got %02x", ref_pos / FRAME_BYTES,
                           (ref_pos % FRAME_BYTES) - 623, ref_data);
                if ((ref_pos % FRAME_BYTES) == FRAME_BYTES-2 && ref_data !== 8'hFF)
                    $fatal(1, "missing EOI marker byte 0");
                if ((ref_pos % FRAME_BYTES) == FRAME_BYTES-1 && ref_data !== 8'hD9)
                    $fatal(1, "missing EOI marker byte 1");
                ref_pos <= ref_pos + 1;
                if (ref_last) begin
                    if (ref_pos % FRAME_BYTES != FRAME_BYTES-1)
                        $fatal(1, "reference tlast at byte %0d", ref_pos);
                    ref_frames <= ref_frames + 1;
                end
            end

            if (bp_valid && !bp_ready) begin
                bp_stall_cycles <= bp_stall_cycles + 1;
                if (bp_pos < 623) header_stall_cycles <= header_stall_cycles + 1;
                else if (bp_pos < 623 + SCAN_BYTES) scan_stall_cycles <= scan_stall_cycles + 1;
                else eoi_stall_cycles <= eoi_stall_cycles + 1;
            end
            if (prev_bp_stall && (!bp_valid || bp_data !== prev_bp_data || bp_last !== prev_bp_last))
                $fatal(1, "output changed while valid was held under backpressure");
            prev_bp_stall <= bp_valid && !bp_ready;
            prev_bp_data <= bp_data;
            prev_bp_last <= bp_last;

            if (bp_valid && bp_ready) begin
                if (bp_pos >= FRAME_BYTES*FRAMES)
                    $fatal(1, "backpressured writer emitted too many bytes");
                if (bp_total >= ref_pos)
                    $fatal(1, "backpressured output outran reference at byte %0d", bp_total);
                if (bp_data !== ref_bytes[bp_total])
                    $fatal(1, "byte mismatch at %0d: got %02x expected %02x", bp_total, bp_data, ref_bytes[bp_total]);
                if (bp_last !== ((bp_pos % FRAME_BYTES) == FRAME_BYTES-1))
                    $fatal(1, "tlast mismatch at byte %0d", bp_pos);
                bp_pos <= bp_pos + 1;
                bp_total <= bp_total + 1;
                if (bp_last) begin
                    bp_frames <= bp_frames + 1;
                    bp_pos <= 0;
                    saw_header_stall <= 0;
                    saw_scan_stall <= 0;
                    saw_eoi_stall <= 0;
                end
            end

            if (force_header_stall) begin saw_header_stall <= 1; stall_left <= 5'd8; end
            else if (force_scan_stall) begin saw_scan_stall <= 1; stall_left <= 5'd13; end
            else if (force_eoi_stall) begin saw_eoi_stall <= 1; stall_left <= 5'd17; end
            else if (stall_left != 0) stall_left <= stall_left - 1'b1;
        end
    end

    initial begin
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        @(negedge clk); frame_start = 1; frames_started = 1;
        @(negedge clk); frame_start = 0;
        wait(ref_headers_done && bp_headers_done);
        @(negedge clk); scan_go = 1;
        @(negedge clk); scan_go = 0;
        wait(ref_frames == 1 && bp_frames == 1);
        repeat (3) @(posedge clk);
        @(negedge clk); frame_start = 1; frames_started = 2;
        @(negedge clk); frame_start = 0;
        wait(ref_headers_done && bp_headers_done);
        @(negedge clk); scan_go = 1;
        @(negedge clk); scan_go = 0;
        wait(ref_frames == FRAMES && bp_frames == FRAMES);
        if (ref_pos != FRAME_BYTES*FRAMES || bp_total != FRAME_BYTES*FRAMES || bp_pos != 0)
            $fatal(1, "wrong final byte counters ref=%0d bp_total=%0d bp_frame_pos=%0d", ref_pos,bp_total,bp_pos);
        if (bp_stall_cycles < 38)
            $fatal(1, "expected header/scan/EOI stalls, observed %0d", bp_stall_cycles);
        if (header_stall_cycles < 16 || scan_stall_cycles < 26 || eoi_stall_cycles < 34)
            $fatal(1, "targeted stalls missing: header=%0d scan=%0d eoi=%0d",
                   header_stall_cycles, scan_stall_cycles, eoi_stall_cycles);
        $display("PASS: two complete JFIF frames match without loss under random and targeted header/scan/EOI stalls");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "timeout: frames ref=%0d bp=%0d bytes ref=%0d bp=%0d", ref_frames, bp_frames, ref_pos, bp_pos);
    end
endmodule
