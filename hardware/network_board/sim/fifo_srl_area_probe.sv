module fifo_srl_area_probe (
    input  logic clk,
    input  logic reset,
    output logic probe_out
);
    localparam int DATA_W = 128;
    logic [15:0] rng [0:DATA_W-1];
    wire [DATA_W-1:0] data_in;
    wire [DATA_W-1:0] data_out;
    wire full, empty;
    wire [5:0] count;
    (* syn_keep = 1 *) logic [DATA_W-1:0] observed_q;
    logic [6:0] scan_q;
    wire [DATA_W-1:0] scan_bus;

    for (genvar b = 0; b < DATA_W; b = b + 1) begin : g_random_lane
        localparam logic [15:0] SEED = 16'h1D2B ^ (b * 16'h0137);
        localparam logic [15:0] TAPS = 16'h8001 | (16'h0001 << (1 + (b % 14))) |
                                        (16'h0001 << (1 + ((b * 7 + 3) % 14)));
        assign data_in[b] = rng[b][0];
        always_ff @(posedge clk) begin
            if (reset) rng[b] <= SEED;
            else rng[b] <= {rng[b][14:0], ^(rng[b] & TAPS)};
        end
    end

`ifdef PROBE_BASELINE
    gesture_sync_fifo_baseline #(.DATA_W(DATA_W), .ADDR_W(5), .REGISTER_BITS(48)) u_fifo (
`else
    gesture_sync_fifo #(.DATA_W(DATA_W), .ADDR_W(5), .REGISTER_BITS(48)) u_fifo (
`endif
        .clk, .reset, .wr_en(1'b1), .wr_data(data_in), .full,
        .rd_en(!empty), .rd_data(data_out), .empty, .count
    );

`ifdef PROBE_REVERSE_SCAN
    for (genvar b = 0; b < DATA_W; b = b + 1) begin : g_reverse_observation
        assign scan_bus[b] = observed_q[DATA_W-1-b];
    end
`else
    assign scan_bus = observed_q;
`endif

    always_ff @(posedge clk) begin
        if (reset) begin
            observed_q <= '0;
            scan_q <= '0;
            probe_out <= 1'b0;
        end else begin
            observed_q <= data_out;
            probe_out <= scan_bus[scan_q[6:0]];
            scan_q <= (scan_q == DATA_W-1) ? '0 : scan_q + 1'b1;
        end
    end
endmodule
