`timescale 1ns/1ps
module tb_gesture_engine_pixel_delta;
    logic clk = 0;
    logic reset = 1;
    logic start = 0;
    logic [7:0] layer_id = 0;
    always #5 clk = ~clk;

    logic rd_ready = 0;
    logic rd_data_valid = 0;
    logic [127:0] rd_data = '0;
    logic [15:0] rd_keep = 16'hffff;
    logic rd_last = 0;
    logic rd_done = 0;
    logic rd_error = 0;
    logic wr_ready = 0;
    logic wr_data_ready = 0;
    logic wr_done = 0;
    logic wr_error = 0;

    wire base_busy, base_done, base_error;
    wire base_rd_valid, base_rd_data_ready;
    wire [31:0] base_rd_address;
    wire [15:0] base_rd_length;
    wire base_wr_valid, base_wr_data_valid, base_wr_last;
    wire [31:0] base_wr_address;
    wire [15:0] base_wr_length, base_wr_keep;
    wire [127:0] base_wr_data;

    wire cand_busy, cand_done, cand_error;
    wire cand_rd_valid, cand_rd_data_ready;
    wire [31:0] cand_rd_address;
    wire [15:0] cand_rd_length;
    wire cand_wr_valid, cand_wr_data_valid, cand_wr_last;
    wire [31:0] cand_wr_address;
    wire [15:0] cand_wr_length, cand_wr_keep;
    wire [127:0] cand_wr_data;

    gesture_engine_baseline #(.OUT_BYTES(8192)) baseline (
        .clk, .reset, .start, .layer_id,
        .busy(base_busy), .done(base_done), .error(base_error),
        .rd_valid(base_rd_valid), .rd_ready, .rd_address(base_rd_address),
        .rd_length(base_rd_length), .rd_data_valid, .rd_data_ready(base_rd_data_ready),
        .rd_data, .rd_keep, .rd_last, .rd_done, .rd_error,
        .wr_valid(base_wr_valid), .wr_ready, .wr_address(base_wr_address),
        .wr_length(base_wr_length), .wr_data_valid(base_wr_data_valid),
        .wr_data_ready, .wr_data(base_wr_data), .wr_keep(base_wr_keep),
        .wr_last(base_wr_last), .wr_done, .wr_error
    );

    gesture_engine #(.OUT_BYTES(8192)) candidate (
        .clk, .reset, .start, .layer_id,
        .busy(cand_busy), .done(cand_done), .error(cand_error),
        .rd_valid(cand_rd_valid), .rd_ready, .rd_address(cand_rd_address),
        .rd_length(cand_rd_length), .rd_data_valid, .rd_data_ready(cand_rd_data_ready),
        .rd_data, .rd_keep, .rd_last, .rd_done, .rd_error,
        .wr_valid(cand_wr_valid), .wr_ready, .wr_address(cand_wr_address),
        .wr_length(cand_wr_length), .wr_data_valid(cand_wr_data_valid),
        .wr_data_ready, .wr_data(cand_wr_data), .wr_keep(cand_wr_keep),
        .wr_last(cand_wr_last), .wr_done, .wr_error
    );

    logic rd_active = 0;
    logic [31:0] rd_base = 0;
    integer rd_left = 0;
    integer rd_index = 0;
    logic wr_active = 0;
    integer wr_left = 0;
    logic wr_done_q = 0;
    integer cycle = 0;
    integer compared_cycles = 0;
    integer read_stalls = 0;
    integer write_cmd_stalls = 0;
    integer write_data_stalls = 0;
    integer accepted_reads = 0;
    integer accepted_writes = 0;
    integer pixel_advances = 0;
    logic rd_stalled_q = 0;
    logic [127:0] rd_stalled_data_q = '0;
    logic rd_stalled_last_q = 0;

    function automatic logic [127:0] memory_word(input logic [31:0] address,
                                                  input integer beat);
        logic [127:0] value;
        logic [31:0] x;
        logic [31:0] beat_address;
        begin
            beat_address = address + 32'(beat * 16);
            // Packed quantization parameters: m18=65536 (normalized),
            // post_shift=20, bfix=0, zp=0 in every 64-bit lane record.
            if (beat_address >= 32'h0010_d000 && beat_address < 32'h0012_9000) begin
                value = {2{64'h0000_0000_0029_0000}};
                return value;
            end
            x = address ^ (32'h9e37_79b9 * (beat + 1));
            for (int b = 0; b < 16; b++) begin
                x = x ^ (x << 13);
                x = x ^ (x >> 17);
                x = x ^ (x << 5);
                value[b*8 +: 8] = x[7:0] ^ (8'(address >> ((b % 4) * 8)) + 8'(b*19));
            end
            return value;
        end
    endfunction

    always_comb begin
        rd_ready = !rd_active && (cycle % 7 != 2);
        // The responder holds VALID and the payload until a real ready/valid
        // handshake. The engine currently keeps ready high, but model the
        // protocol from the DUT output rather than assuming that behavior.
        rd_data_valid = rd_active;
        rd_data = memory_word(rd_base, rd_index);
        rd_last = rd_data_valid && (rd_left == 1);
        rd_done = rd_data_valid && rd_last && cand_rd_data_ready;
        rd_error = 1'b0;
        rd_keep = 16'hffff;

        // Force one legal command-side backpressure event on the first write;
        // then accept later commands without randomizing away that coverage.
        wr_ready = !wr_active && !(cand_wr_valid && (write_cmd_stalls == 0));
        wr_data_ready = wr_active && (cycle % 9 != 4);
        wr_done = wr_done_q;
        wr_error = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            cycle <= 0;
            rd_active <= 0;
            rd_base <= 0;
            rd_left <= 0;
            rd_index <= 0;
            wr_active <= 0;
            wr_left <= 0;
            wr_done_q <= 0;
            rd_stalled_q <= 0;
            rd_stalled_data_q <= '0;
            rd_stalled_last_q <= 0;
        end else begin
            cycle <= cycle + 1;
            if ((cycle % 100) == 0)
                $display("SIM_PROGRESS cycle=%0d layer=%0d state=%0d x=%0d y=%0d pixels=%0d reads=%0d writes=%0d",
                         cycle, layer_id, candidate.state_q, candidate.x_q,
                         candidate.y_q, pixel_advances, accepted_reads, accepted_writes);
            wr_done_q <= 0;

            if (rd_stalled_q && (!rd_data_valid || rd_data !== rd_stalled_data_q
                                 || rd_last !== rd_stalled_last_q))
                $fatal(1, "DDR read payload/last changed while stalled cycle=%0d", cycle);
            rd_stalled_q <= rd_data_valid && !cand_rd_data_ready;
            if (rd_data_valid && !cand_rd_data_ready) begin
                rd_stalled_data_q <= rd_data;
                rd_stalled_last_q <= rd_last;
            end

            if (cand_rd_valid && rd_ready) begin
                rd_active <= 1;
                rd_base <= cand_rd_address;
                rd_left <= (cand_rd_length + 15) / 16;
                rd_index <= 0;
                accepted_reads <= accepted_reads + 1;
            end else if (rd_data_valid && cand_rd_data_ready && base_rd_data_ready) begin
                if (rd_left == 1) begin
                    rd_active <= 0;
                    rd_left <= 0;
                end else begin
                    rd_left <= rd_left - 1;
                    rd_index <= rd_index + 1;
                end
            end

            if (cand_wr_valid && wr_ready) begin
                wr_active <= 1;
                wr_left <= (cand_wr_length + 15) / 16;
                accepted_writes <= accepted_writes + 1;
            end else if (cand_wr_data_valid && wr_data_ready) begin
                if (wr_left <= 1) begin
                    wr_active <= 0;
                    wr_left <= 0;
                    wr_done_q <= 1;
                end else wr_left <= wr_left - 1;
            end

            if (cand_rd_valid && !rd_ready) read_stalls <= read_stalls + 1;
            if (cand_wr_valid && !wr_ready) write_cmd_stalls <= write_cmd_stalls + 1;
            if (cand_wr_data_valid && !wr_data_ready) write_data_stalls <= write_data_stalls + 1;
            if (candidate.pixel_advance_gap || candidate.pixel_advance_capture
                || candidate.pixel_advance_store)
                pixel_advances <= pixel_advances + 1;
        end
    end

    always @(negedge clk) begin
        if (!reset) begin
            #1;
            if ({base_busy, base_done, base_error, base_rd_valid, base_rd_address,
                 base_rd_length, base_rd_data_ready, base_wr_valid, base_wr_address,
                 base_wr_length, base_wr_data_valid, base_wr_data, base_wr_keep,
                 base_wr_last} !==
                {cand_busy, cand_done, cand_error, cand_rd_valid, cand_rd_address,
                 cand_rd_length, cand_rd_data_ready, cand_wr_valid, cand_wr_address,
                 cand_wr_length, cand_wr_data_valid, cand_wr_data, cand_wr_keep,
                 cand_wr_last})
                $fatal(1, "engine output mismatch cycle=%0d layer=%0d", cycle, layer_id);
            if (cand_wr_data_valid && wr_data_ready && $isunknown(cand_wr_data))
                $fatal(1, "candidate emitted unknown write payload cycle=%0d layer=%0d", cycle, layer_id);
            if (base_wr_data_valid && wr_data_ready && $isunknown(base_wr_data))
                $fatal(1, "baseline emitted unknown write payload cycle=%0d layer=%0d", cycle, layer_id);
            if ({baseline.state_q, baseline.x_q, baseline.y_q, baseline.kx_q,
                 baseline.ky_q, baseline.ci_q, baseline.pixel_base_q,
                 baseline.row_addr_q, baseline.out_we, baseline.out_waddr,
                 baseline.out_wdata} !==
                {candidate.state_q, candidate.x_q, candidate.y_q, candidate.kx_q,
                 candidate.ky_q, candidate.ci_q, candidate.pixel_base_q,
                 candidate.row_addr_q, candidate.out_we, candidate.out_waddr,
                 candidate.out_wdata})
                $fatal(1, "engine internal cursor/output mismatch cycle=%0d layer=%0d", cycle, layer_id);
            compared_cycles = compared_cycles + 1;
        end
    end

    task automatic hard_reset;
        begin
            @(negedge clk); reset = 1; start = 0;
            repeat (3) @(negedge clk);
            reset = 0;
            @(negedge clk);
        end
    endtask

    task automatic launch_layer(input logic [7:0] id);
        begin
            layer_id = id;
            $display("LAYER_START id=%0d time=%0t", id, $time);
            start = 1;
            @(negedge clk);
            start = 0;
        end
    endtask

    task automatic wait_done(input integer limit_cycles);
        integer elapsed;
        begin
            elapsed = 0;
            while (!cand_done && elapsed < limit_cycles) begin
                @(negedge clk);
                elapsed = elapsed + 1;
            end
            if (!cand_done || !base_done)
                $fatal(1, "engine timeout layer=%0d elapsed=%0d", layer_id, elapsed);
            if (cand_error || base_error)
                $fatal(1, "engine reported error layer=%0d", layer_id);
            $display("LAYER_PASS id=%0d cycles=%0d", layer_id, elapsed);
        end
    endtask

    task automatic wait_prefix(input integer target_pixels,
                               input integer target_writes,
                               input integer limit_cycles);
        integer elapsed;
        integer start_pixels;
        integer start_writes;
        begin
            elapsed = 0;
            start_pixels = pixel_advances;
            start_writes = accepted_writes;
            while (((pixel_advances - start_pixels) < target_pixels
                    || (accepted_writes - start_writes) < target_writes)
                   && elapsed < limit_cycles) begin
                @(negedge clk);
                elapsed = elapsed + 1;
            end
            if ((pixel_advances - start_pixels) < target_pixels
                || (accepted_writes - start_writes) < target_writes)
                $fatal(1, "prefix timeout layer=%0d pixels=%0d writes=%0d elapsed=%0d",
                       layer_id, pixel_advances - start_pixels,
                       accepted_writes - start_writes, elapsed);
            $display("LAYER_PREFIX_PASS id=%0d pixels=%0d writes=%0d cycles=%0d",
                     layer_id, pixel_advances - start_pixels,
                     accepted_writes - start_writes, elapsed);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        reset = 0;

        // Abort a real padded depthwise run after several pixel advances, then
        // restart it cleanly. Both engines see the same reset and DDR schedule.
        launch_layer(8'd1);
        wait (pixel_advances >= 3);
        hard_reset();
        launch_layer(8'd1);
        // Finish the padded DW output row, then enter the next row so both
        // the pixel increment and row-base update are compared against the
        // independent baseline engine.
        wait_prefix(128, 1, 30_000);

        hard_reset(); launch_layer(8'd0);  wait_prefix(16, 0, 30_000); // stride-2 convolution
        hard_reset(); launch_layer(8'd4);  wait_prefix(16, 0, 30_000); // stride-2 max-pool
        hard_reset(); launch_layer(8'd7);  wait_prefix(16, 0, 30_000); // ADD
        hard_reset(); launch_layer(8'd58); wait_prefix(16, 0, 30_000); // GAP, k=1

        if (pixel_advances < 3 || read_stalls == 0 || write_cmd_stalls == 0
            || write_data_stalls == 0 || accepted_reads == 0 || accepted_writes == 0)
            $fatal(1, "coverage missing advances=%0d rd_stall=%0d wr_cmd_stall=%0d wr_data_stall=%0d reads=%0d writes=%0d",
                   pixel_advances, read_stalls, write_cmd_stalls, write_data_stalls,
                   accepted_reads, accepted_writes);
        $display("PAIRED_ENGINE_PASS compared=%0d pixel_advances=%0d rd_stalls=%0d wr_cmd_stalls=%0d wr_data_stalls=%0d reads=%0d writes=%0d",
                 compared_cycles, pixel_advances, read_stalls, write_cmd_stalls,
                 write_data_stalls, accepted_reads, accepted_writes);
        $finish;
    end

    initial begin
        #200_000_000;
        $fatal(1, "paired engine testbench global timeout");
    end
endmodule
