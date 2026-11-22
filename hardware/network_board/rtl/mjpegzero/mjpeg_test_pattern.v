// SPDX-License-Identifier: Apache-2.0
// 1280x720 RGB test source for the isolated MJPEG hardware experiment.
module mjpeg_test_pattern #(
    parameter IMG_WIDTH = 1280,
    parameter IMG_HEIGHT = 720,
    parameter RATE_DIV = 6             // one accepted pixel per six proc_clk cycles (~30 Mpixel/s at 180 MHz)
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output reg         active,
    output wire [23:0] tdata,
    output wire        tvalid,
    input  wire        tready,
    output wire        tlast,
    output wire        tuser
);
    reg [10:0] x;
    reg [9:0] y;
    reg [2:0] rate_wait;
    reg [23:0] bar_rgb;
    wire texture = x[3] ^ y[3] ^ x[6] ^ y[5];

    always @* begin
        if      (x < 11'd160)  bar_rgb = 24'hffffff;
        else if (x < 11'd320)  bar_rgb = 24'hffff00;
        else if (x < 11'd480)  bar_rgb = 24'h00ffff;
        else if (x < 11'd640)  bar_rgb = 24'h00ff00;
        else if (x < 11'd800)  bar_rgb = 24'hff00ff;
        else if (x < 11'd960)  bar_rgb = 24'hff0000;
        else if (x < 11'd1120) bar_rgb = 24'h0000ff;
        else                   bar_rgb = 24'h101010;
    end

    // Fine checker texture makes the JPEG exercise spatial detail while the
    // broad bars keep the received 720p test frame immediately recognizable.
    assign tdata  = texture ? (bar_rgb ^ 24'h030303) : bar_rgb;
    assign tvalid = active && (rate_wait == 0);
    assign tlast  = active && (x == IMG_WIDTH-1);
    assign tuser  = active && (x == 0) && (y == 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            x <= 0;
            y <= 0;
            rate_wait <= 0;
        end else if (start && !active) begin
            active <= 1'b1;
            x <= 0;
            y <= 0;
            rate_wait <= 0;
        end else if (active && rate_wait != 0) begin
            rate_wait <= rate_wait - 1'b1;
        end else if (active && tready) begin
            rate_wait <= RATE_DIV-1;
            if (x == IMG_WIDTH-1) begin
                x <= 0;
                if (y == IMG_HEIGHT-1) begin
                    y <= 0;
                    active <= 1'b0;
                    rate_wait <= 0;
                end else y <= y + 1'b1;
            end else x <= x + 1'b1;
        end
    end
endmodule
