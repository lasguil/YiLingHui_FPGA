`include "vid_params.vh"

// Color-corrected 1080p RGB in, stored-size RGB out. RAM-less nearest
// neighbour with exact integer ratios (no 16-bit Bresenham):
//   mode 0 : 1920x1080 identity
//   mode 1 : 1280x720 = keep 2 of every 3 on X and Y
//   mode 2 : 720x480  = keep 3 of 8 on X, 4 of 9 on Y
//
// ISP lines are 1918 DE + 32-cycle pad hole + 2 pad DE. GAP_CYC must stay
// so a short line still ends. Full 1920 also wraps so last-line replay
// cannot glue onto the previous line. Never emit more than out_h rows.
module vid_store_down #(
    parameter SRC_W   = `VID_WIDTH,
    parameter SRC_H   = `VID_HEIGHT,
    parameter GAP_CYC = 32
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  mode,

    input  wire        in_vs,
    input  wire        in_de,
    input  wire [7:0]  in_r,
    input  wire [7:0]  in_g,
    input  wire [7:0]  in_b,

    output reg         out_vs,
    output reg         out_de,
    output reg  [7:0]  out_r,
    output reg  [7:0]  out_g,
    output reg  [7:0]  out_b,

    output reg  [1:0]  mode_hold
);
    reg        vs_d;
    reg [5:0]  gap;
    reg        cap_line;
    reg [1:0]  xph3;
    reg [1:0]  yph3;
    reg [2:0]  xph8;
    reg [3:0]  yph9;
    reg [11:0] src_x;

    wire vs_rise = in_vs & ~vs_d;
    wire pass_1080 = (mode_hold == 2'd0);
    wire keep_x = pass_1080
                | ((mode_hold == 2'd1) & (xph3 != 2'd1))
                | ((mode_hold == 2'd2) & (xph8 < 3'd3));
    wire src_last = (src_x == SRC_W[11:0] - 12'd1);
    wire emit = in_de & keep_x & cap_line;
    wire gap_eol = (gap == GAP_CYC[5:0]) && (src_x != 12'd0);

    wire [1:0] yph3_n = (yph3 == 2'd2) ? 2'd0 : (yph3 + 2'd1);
    wire [3:0] yph9_n = (yph9 == 4'd8) ? 4'd0 : (yph9 + 4'd1);
    wire cap_line_n = pass_1080
                    | ((mode_hold == 2'd1) & (yph3_n != 2'd1))
                    | ((mode_hold == 2'd2) & (yph9_n < 4'd4));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d      <= 1'b0;
            gap       <= 6'd0;
            mode_hold <= 2'd0;
            cap_line  <= 1'b1;
            xph3      <= 2'd0;
            yph3      <= 2'd0;
            xph8      <= 3'd0;
            yph9      <= 4'd0;
            src_x     <= 12'd0;
        end else begin
            vs_d <= in_vs;

            if (vs_rise) begin
                gap       <= 6'd0;
                cap_line  <= 1'b1;
                xph3      <= 2'd0;
                yph3      <= 2'd0;
                xph8      <= 3'd0;
                yph9      <= 4'd0;
                src_x     <= 12'd0;
                mode_hold <= mode;
            end else if (in_de) begin
                gap <= 6'd0;

                if (src_last) begin
                    src_x    <= 12'd0;
                    xph3     <= 2'd0;
                    xph8     <= 3'd0;
                    yph3     <= yph3_n;
                    yph9     <= yph9_n;
                    cap_line <= cap_line_n;
                end else begin
                    src_x <= src_x + 12'd1;
                    xph3  <= (xph3 == 2'd2) ? 2'd0 : (xph3 + 2'd1);
                    xph8  <= xph8 + 3'd1;
                end
            end else if (gap != 6'h3f) begin
                gap <= gap + 6'd1;
                if (gap_eol) begin
                    src_x    <= 12'd0;
                    xph3     <= 2'd0;
                    xph8     <= 3'd0;
                    yph3     <= yph3_n;
                    yph9     <= yph9_n;
                    cap_line <= cap_line_n;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vs <= 1'b0;
            out_de <= 1'b0;
            out_r  <= 8'd0;
            out_g  <= 8'd0;
            out_b  <= 8'd0;
        end else begin
            out_vs <= in_vs;
            out_de <= emit;
            out_r  <= in_r;
            out_g  <= in_g;
            out_b  <= in_b;
        end
    end
endmodule
