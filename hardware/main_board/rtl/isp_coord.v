`include "isp_params.vh"

// Raster coordinates from DE / VSYNC. VSYNC rising edge starts a frame.
// End-of-line is DE low for GAP_CYC clocks.  Single-cycle DE holes from
// the 50 MHz CSI pixel clock must not reset X or increment Y: that split
// every camera line into a left stub (horizontal tear) plus a GB/BG
// Bayer row slip (vertical stripes).  Do not wrap at 1920.
module isp_coord #(
    parameter WIDTH   = `ISP_WIDTH,
    parameter GAP_CYC = 32
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vs,
    input  wire        in_de,
    output reg  [10:0] x,
    output reg  [10:0] y,
    output wire        vs_rise
);
    reg vs_d;
    reg [5:0] gap;
    reg line_open;

    assign vs_rise = in_vs & ~vs_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d <= 1'b0;
            gap  <= 6'd0;
            x    <= 11'd0;
            y    <= 11'd0;
            line_open <= 1'b0;
        end else begin
            vs_d <= in_vs;
            if (vs_rise) begin
                x   <= 11'd0;
                y   <= 11'd0;
                gap <= 6'd0;
                line_open <= 1'b0;
            end else if (in_de) begin
                x   <= x + 11'd1;
                gap <= 6'd0;
                line_open <= 1'b1;
            end else if (gap != 6'h3f) begin
                gap <= gap + 6'd1;
                // A blank before the first pixel is not a sensor line.
                // Advance once only after this row actually received data.
                if ((gap == GAP_CYC[5:0]) && line_open) begin
                    x <= 11'd0;
                    y <= y + 11'd1;
                    line_open <= 1'b0;
                end
            end
        end
    end
endmodule
