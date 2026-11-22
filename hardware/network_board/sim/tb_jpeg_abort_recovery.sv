`timescale 1ns/1ps
module tb_jpeg_abort_recovery;
    localparam integer CLK_HZ = 1_000_000;
    localparam integer FPS = 100;
    localparam integer RESIDUAL_BYTES = 5;
    localparam integer JPEG_BYTES = 7;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg cap_busy = 1'b1;
    reg cap_error = 1'b1;
    reg [7:0] cap_mem [0:15];
    reg cap_mem_last [0:15];
    integer cap_rd = 0;
    integer cap_count = RESIDUAL_BYTES;
    wire cap_data_valid = cap_rd < cap_count;
    wire [15:0] cap_data = {7'd0, cap_mem_last[cap_rd], cap_mem[cap_rd]};
    wire cap_pop;
    wire cap_rd_begin, cap_rd_end, cap_using;

    wire [7:0] tx_data;
    wire tx_wr, tx_req, tx_busy;
    wire [15:0] tx_len, tx_port, cap_addr;
    wire [31:0] frame_cnt, pkt_cnt, drop_cnt;
    reg mac_send_end = 1'b0;
    wire tx_ram_req = tx_req;

    reg [7:0] captured [0:127];
    integer captured_count = 0;
    integer packet_expected_len = 0;
    integer wait_cycles = 0;
    integer i;

    vid_packet #(.JPEG_MODE(1), .W(16'd1280), .H(16'd720), .FPS(FPS[7:0]),
                 .PKT_MAX(16'd1452), .CLK_HZ(CLK_HZ), .WAIT_FRESH(1)) dut (
        .clk(clk), .rst_n(rst_n), .tx_data(tx_data), .tx_wr(tx_wr), .tx_len(tx_len),
        .tx_req(tx_req), .tx_port(tx_port), .tx_busy(tx_busy), .tx_ram_req(tx_ram_req),
        .mac_send_end(mac_send_end), .cfg_stream_en(1'b1), .cfg_test_src(2'd0),
        .frame_cnt(frame_cnt), .pkt_cnt(pkt_cnt), .drop_cnt(drop_cnt),
        .cur_w(), .cur_h(), .cap_addr(cap_addr), .cap_data(cap_data),
        .cap_data_valid(cap_data_valid), .cap_last(cap_data[8]), .cap_error(cap_error),
        .cap_busy(cap_busy), .cap_pop(cap_pop), .cap_valid(1'b1), .cap_present(1'b1),
        .cap_rd_begin(cap_rd_begin), .cap_rd_end(cap_rd_end), .cap_using(cap_using)
    );

    always @(posedge clk) begin
        mac_send_end <= 1'b0;
        if (!rst_n) begin
            cap_rd <= 0;
            captured_count <= 0;
        end else begin
            if (cap_pop && cap_data_valid) cap_rd <= cap_rd + 1;
            if (tx_req && tx_len != 0) packet_expected_len <= tx_len;
            if (tx_wr) begin
                captured[captured_count] <= tx_data;
                captured_count <= captured_count + 1;
                if (captured_count + 1 == packet_expected_len)
                    mac_send_end <= 1'b1;
            end
        end
    end

    initial begin
        for (i = 0; i < 16; i = i + 1) begin
            cap_mem[i] = 8'hA0 + i;
            cap_mem_last[i] = 1'b0;
        end
        repeat (8) @(posedge clk);
        rst_n = 1'b1;

        // An encoder/link abort left queued bytes while the packetizer was idle.
        // The packetizer must claim and drain this stale FIFO before admitting a frame.
        wait_cycles = 0;
        while (cap_rd < RESIDUAL_BYTES && wait_cycles < 64) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (cap_rd != RESIDUAL_BYTES)
            $fatal(1, "idle abort did not drain residual FIFO: consumed %0d/%0d", cap_rd, RESIDUAL_BYTES);
        if (cap_rd_begin)
            $fatal(1, "packetizer began a frame while cap_error/cap_busy remained asserted");

        repeat (3) @(posedge clk);
        cap_error = 1'b0;
        cap_busy = 1'b0;
        wait (dut.st == 0);
        @(negedge clk);
        cap_count = RESIDUAL_BYTES + JPEG_BYTES;
        cap_mem[5] = 8'hFF; cap_mem_last[5] = 1'b0;
        cap_mem[6] = 8'hD8; cap_mem_last[6] = 1'b0;
        cap_mem[7] = 8'h12; cap_mem_last[7] = 1'b0;
        cap_mem[8] = 8'h34; cap_mem_last[8] = 1'b0;
        cap_mem[9] = 8'h56; cap_mem_last[9] = 1'b0;
        cap_mem[10] = 8'hFF; cap_mem_last[10] = 1'b0;
        cap_mem[11] = 8'hD9; cap_mem_last[11] = 1'b1;

        wait (frame_cnt == 1);
        if (pkt_cnt != 1) $fatal(1, "expected one packet, got %0d", pkt_cnt);
        if (captured_count != 20 + JPEG_BYTES)
            $fatal(1, "packet length %0d expected %0d", captured_count, 20 + JPEG_BYTES);
        if (captured[0] !== 8'h56 || captured[1] !== 8'h49 ||
            captured[2] !== 8'd2 || captured[3] !== 8'h03)
            $fatal(1, "recovered packet header invalid: %02x %02x %02x %02x",
                   captured[0], captured[1], captured[2], captured[3]);
        if (captured[20] !== 8'hFF || captured[21] !== 8'hD8 ||
            captured[22] !== 8'h12 || captured[23] !== 8'h34 ||
            captured[24] !== 8'h56 || captured[25] !== 8'hFF || captured[26] !== 8'hD9)
            $fatal(1, "recovered JPEG payload contains stale/corrupt bytes");
        $display("PASS: idle JPEG abort drains stale bytes and packetizer transmits a clean next frame");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "timeout: frame_cnt=%0d pkt_cnt=%0d cap_rd=%0d tx_busy=%0b", frame_cnt, pkt_cnt, cap_rd, tx_busy);
    end
endmodule
