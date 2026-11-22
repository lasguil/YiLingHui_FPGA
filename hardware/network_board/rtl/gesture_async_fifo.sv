// Gray-pointer dual-clock FIFO with a synchronous-read RAM and FWFT output.
//
// The memory has one write port in wclk and one registered read port in rclk;
// this is the inference pattern used by the Efinix dual-clock FIFO RAM.  A
// one-word prefetch register hides the RAM latency and preserves the original
// interface contract: rd_data is the current head and remains stable while
// empty is low until rd_en consumes it.  A consumed head may be refilled by a
// read request in the same rclk edge; the next head appears after the RAM
// latency.  The pixel consumer runs much slower than the RAM clock, so the
// refill bubble does not limit capture throughput.
module gesture_async_fifo #(
    parameter int DATA_W = 26,
    parameter int ADDR_W = 9
) (
    input  logic              arst,
    input  logic              wclk,
    input  logic              wr_en,
    input  logic [DATA_W-1:0] wr_data,
    output logic              full,
    output logic              write_empty,
    input  logic              rclk,
    input  logic              rd_en,
    output logic [DATA_W-1:0] rd_data,
    output logic              empty
);
    localparam int DEPTH = 1 << ADDR_W;
    localparam int PTR_W = ADDR_W + 1;

    // Do not reset the RAM: resetting an inferred memory would turn it into
    // thousands of individual registers.  Pointer and valid reset makes all
    // pre-reset contents unreachable.
    (* syn_ramstyle = "block_ram" *) logic [DATA_W-1:0] mem [0:DEPTH-1];
    logic [DATA_W-1:0] ram_rdata_q;
    logic [DATA_W-1:0] head_q;

    logic [PTR_W-1:0] wbin, wgray, rbin, rgray;
    logic [PTR_W-1:0] rcons_bin, rcons_gray, rcons_bin_next, rcons_gray_next;
    (* async_reg = "true" *) logic [PTR_W-1:0] rcons_gray_w1, rcons_gray_w2;
    (* async_reg = "true" *) logic [PTR_W-1:0] wgray_r1, wgray_r2;
    logic [PTR_W-1:0] wbin_next, wgray_next, rbin_next, rgray_next;
    (* async_reg = "true" *) logic [1:0] wreset_pipe, rreset_pipe;
    logic head_valid_q;
    logic read_pending_q;
    logic read_issue;
    logic mem_empty;
    wire wreset = wreset_pipe[1];
    wire rreset = rreset_pipe[1];
    wire write_fire = wr_en && !full && !wreset;
    wire read_pop = rd_en && !empty && !rreset;

    // Standard asynchronous FIFO full/empty detection. rgray advances only
    // after data has been safely copied into the FWFT head register, freeing
    // its physical RAM location without losing the output copy.
    always_comb begin
        // The prefetch register is an extra physical storage location, but
        // externally full remains exactly DEPTH words. Use the consumer
        // pointer (not the RAM read-ahead pointer) for write-side capacity.
        full = (wgray == {~rcons_gray_w2[PTR_W-1:PTR_W-2],
                          rcons_gray_w2[PTR_W-3:0]});
        // Includes the prefetched head; safe in wclk after the existing
        // consumer Gray-pointer synchronizer. Used to retire an errored frame.
        write_empty = (wgray == rcons_gray_w2);
        mem_empty = (rgray == wgray_r2);
        empty = !head_valid_q;
        rd_data = head_q;

        // One synchronous RAM read may be in flight. Issue only when the
        // head is absent or will be consumed now; otherwise hold FWFT data.
        read_issue = !rreset && !read_pending_q && !mem_empty &&
                     (!head_valid_q || read_pop);

        wbin_next  = wbin + (write_fire ? 1'b1 : 1'b0);
        wgray_next = (wbin_next >> 1) ^ wbin_next;
        rbin_next  = rbin + (read_issue ? 1'b1 : 1'b0);
        rgray_next = (rbin_next >> 1) ^ rbin_next;
        rcons_bin_next = rcons_bin + (read_pop ? 1'b1 : 1'b0);
        rcons_gray_next = (rcons_bin_next >> 1) ^ rcons_bin_next;
    end

    always_ff @(posedge wclk or posedge arst) begin
        if (arst) wreset_pipe <= 2'b11;
        else      wreset_pipe <= {wreset_pipe[0],1'b0};
    end
    always_ff @(posedge rclk or posedge arst) begin
        if (arst) rreset_pipe <= 2'b11;
        else      rreset_pipe <= {rreset_pipe[0],1'b0};
    end

    // Independent-clock RAM ports.  The registered read is required for
    // block-RAM inference on Titanium; keep this process free of reset logic.
    always_ff @(posedge wclk) begin
        if (write_fire)
            mem[wbin[ADDR_W-1:0]] <= wr_data;
    end

    always_ff @(posedge rclk) begin
        if (read_issue)
            ram_rdata_q <= mem[rbin[ADDR_W-1:0]];
    end

    always_ff @(posedge wclk or posedge arst) begin
        if (arst) begin
            wbin <= '0;
            wgray <= '0;
            rcons_gray_w1 <= '0;
            rcons_gray_w2 <= '0;
        end else if (wreset) begin
            wbin <= '0;
            wgray <= '0;
            rcons_gray_w1 <= '0;
            rcons_gray_w2 <= '0;
        end else begin
            rcons_gray_w1 <= rcons_gray;
            rcons_gray_w2 <= rcons_gray_w1;
            if (write_fire) begin
                wbin <= wbin_next;
                wgray <= wgray_next;
            end
        end
    end

    always_ff @(posedge rclk or posedge arst) begin
        if (arst) begin
            rbin <= '0;
            rgray <= '0;
            rcons_bin <= '0;
            rcons_gray <= '0;
            wgray_r1 <= '0;
            wgray_r2 <= '0;
            head_q <= '0;
            head_valid_q <= 1'b0;
            read_pending_q <= 1'b0;
        end else if (rreset) begin
            rbin <= '0;
            rgray <= '0;
            rcons_bin <= '0;
            rcons_gray <= '0;
            wgray_r1 <= '0;
            wgray_r2 <= '0;
            head_valid_q <= 1'b0;
            read_pending_q <= 1'b0;
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
            if (read_pop) begin
                rcons_bin <= rcons_bin_next;
                rcons_gray <= rcons_gray_next;
            end

            // The RAM data from the prior read_issue is now available.
            if (read_pending_q) begin
                head_q <= ram_rdata_q;
                head_valid_q <= 1'b1;
            end else if (read_pop) begin
                head_valid_q <= 1'b0;
            end

            read_pending_q <= read_issue;
            if (read_issue) begin
                rbin <= rbin_next;
                rgray <= rgray_next;
            end
        end
    end

`ifdef SIM_ASSERT
    initial if (ADDR_W < 2) $fatal(1, "gesture_async_fifo ADDR_W must be >= 2");
    always @(posedge rclk) if (!arst && !rreset) begin
        if (read_pop && !head_valid_q)
            $fatal(1, "gesture_async_fifo popped without a valid FWFT head");
        if (read_pending_q && head_valid_q)
            $fatal(1, "gesture_async_fifo read response overflowed head register");
    end
`endif
endmodule
