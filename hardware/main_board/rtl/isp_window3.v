`include "isp_params.vh"

// 3x3 Bayer window with 2 line memories. Center is the previous line,
// delayed 2 pixels so the horizontal taps match the old 5x5 center column.
// The first sensor line has no north neighbor, so it is not emitted; the
// line below is mirrored into that neighborhood instead. One extra line is
// then read back from these same RAMs so the frame stays 1920x1080.
// A short DE hole must not pad or split a line.
module isp_window3 #(
    parameter WIDTH  = `ISP_WIDTH,
    parameter HEIGHT = `ISP_HEIGHT
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vs,
    input  wire        in_de,
    input  wire [9:0]  in_pix,
    input  wire [10:0] in_x,
    input  wire [10:0] in_y,
    output reg         out_vs,
    output reg         out_de,
    output reg  [10:0] out_x,
    output reg  [10:0] out_y,
    output reg  [9:0]  nw, n, ne,
    output reg  [9:0]  w,  c, e,
    output reg  [9:0]  sw, s, se
);
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [9:0] ram0 [0:WIDTH-1];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [9:0] ram1 [0:WIDTH-1];

    reg [9:0]  q0, q1;
    reg        de_d, vs_d;
    reg [9:0]  pix_d;
    reg [10:0] x_d, y_d;
    reg        replay;
    reg [10:0] rx;
    reg        replay_arm;
    reg        first_line_ready;
    wire       frame_start = in_vs && !vs_d;

    // Replay presents y==HEIGHT, which the sensor never does. That even
    // index selects ram1 (the last odd line) as the center row.
    wire [10:0] y_replay = HEIGHT;
    // Address mux is outside the clocked read. The read itself stays
    // unconditional, or Efinity maps the line RAMs into flip-flops.
    wire [10:0] rd_addr = replay ? rx : in_x;

    always @(posedge clk) begin
        q0 <= ram0[rd_addr];
        q1 <= ram1[rd_addr];
        if (!rst_n) begin
            de_d   <= 1'b0;
            vs_d   <= 1'b0;
            pix_d  <= 10'd0;
            x_d    <= 11'd0;
            y_d    <= 11'd0;
            replay <= 1'b0;
            rx     <= 11'd0;
        end else if (frame_start) begin
            // Discard delayed pixels / replay from the previous frame.
            // RAM is reused without clearing; output is gated by validity.
            de_d   <= in_de;
            vs_d   <= in_vs;
            pix_d  <= in_pix;
            x_d    <= in_x;
            y_d    <= in_y;
            replay <= 1'b0;
            rx     <= 11'd0;
        end else if (replay) begin
            de_d  <= 1'b1;
            vs_d  <= in_vs;
            pix_d <= 10'd0;
            x_d   <= rx;
            y_d   <= y_replay;
            if (rx == WIDTH-1)
                replay <= 1'b0;
            else
                rx <= rx + 11'd1;
        end else begin
            // Write the previous beat so read and write never share in_x.
            // Same-address read-through on Efinix BRAM returns the new pixel
            // and collapses the vertical Bayer neighbors.
            if (de_d) begin
                if (y_d[0])
                    ram1[x_d] <= pix_d;
                else
                    ram0[x_d] <= pix_d;
            end
            de_d  <= in_de;
            vs_d  <= in_vs;
            pix_d <= in_pix;
            x_d   <= in_x;
            y_d   <= in_y;
            if (replay_arm && !in_de) begin
                replay <= 1'b1;
                rx     <= 11'd0;
            end
        end
    end

    // Line y lives in ram[y[0]]. While line y is arriving, y-1 is the
    // other bank and y-2 is the bank about to be overwritten at x-1.
    wire [9:0] line_prev  = y_d[0] ? q0 : q1;
    wire [9:0] line_prev2 = y_d[0] ? q1 : q0;

    reg [9:0] row_n, row_c, row_s;
    always @(*) begin
        row_s = pix_d;
        if (y_d == 11'd0) begin
            // Not emitted. Rows are unused, but keep the taps defined.
            row_n = pix_d;
            row_c = pix_d;
        end else if (y_d == 11'd1) begin
            // Center is sensor line 0. The missing line above has the same
            // Bayer phase as line 1, so mirror line 1 into the north tap.
            row_n = pix_d;
            row_c = line_prev;
            row_s = pix_d;
        end else if (y_d == y_replay) begin
            // Center is the last sensor line. Mirror the line above it
            // into the south tap (same phase as the missing line below).
            row_n = line_prev2;
            row_c = line_prev;
            row_s = line_prev2;
        end else begin
            row_n = line_prev2;
            row_c = line_prev;
        end
    end

    reg [9:0] sn [0:4];
    reg [9:0] sc [0:4];
    reg [9:0] ss [0:4];
    reg [1:0] pad;
    reg [5:0] gap;
    reg [9:0] last_n, last_c, last_s;
    reg [10:0] y_hold;
    localparam [5:0] GAP_CYC = 6'd32;

    integer i;
    wire [10:0] y_line = de_d ? y_d : y_hold;
    wire [10:0] y_center = (y_line == 11'd0) ? 11'd0 : (y_line - 11'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 5; i = i + 1) begin
                sn[i] <= 10'd0;
                sc[i] <= 10'd0;
                ss[i] <= 10'd0;
            end
            pad    <= 2'd0;
            gap    <= 6'd0;
            last_n <= 10'd0;
            last_c <= 10'd0;
            last_s <= 10'd0;
            y_hold <= 11'd0;
            replay_arm <= 1'b0;
            first_line_ready <= 1'b0;
            out_vs <= 1'b0;
            out_de <= 1'b0;
            out_x  <= 11'd0;
            out_y  <= 11'd0;
            nw <= 10'd0; n <= 10'd0; ne <= 10'd0;
            w  <= 10'd0; c <= 10'd0; e  <= 10'd0;
            sw <= 10'd0; s <= 10'd0; se <= 10'd0;
        end else if (frame_start) begin
            pad <= 2'd0;
            gap <= 6'd0;
            y_hold <= 11'd0;
            replay_arm <= 1'b0;
            first_line_ready <= 1'b0;
            out_vs <= in_vs;
            out_de <= 1'b0;
            out_x <= 11'd0;
            out_y <= 11'd0;
        end else begin
            if (de_d) begin
                if ((y_d == 11'd0) && (x_d == WIDTH-1))
                    first_line_ready <= 1'b1;
                y_hold <= y_d;
                last_n <= row_n;
                last_c <= row_c;
                last_s <= row_s;
                if (x_d == 11'd0) begin
                    sn[0] <= row_n; sn[1] <= row_n; sn[2] <= row_n; sn[3] <= row_n; sn[4] <= row_n;
                    sc[0] <= row_c; sc[1] <= row_c; sc[2] <= row_c; sc[3] <= row_c; sc[4] <= row_c;
                    ss[0] <= row_s; ss[1] <= row_s; ss[2] <= row_s; ss[3] <= row_s; ss[4] <= row_s;
                end else begin
                    sn[0] <= row_n; sn[1] <= sn[0]; sn[2] <= sn[1]; sn[3] <= sn[2]; sn[4] <= sn[3];
                    sc[0] <= row_c; sc[1] <= sc[0]; sc[2] <= sc[1]; sc[3] <= sc[2]; sc[4] <= sc[3];
                    ss[0] <= row_s; ss[1] <= ss[0]; ss[2] <= ss[1]; ss[3] <= ss[2]; ss[4] <= ss[3];
                end
                pad <= 2'd2;
                gap <= 6'd0;
            end else if (gap < GAP_CYC) begin
                gap <= gap + 6'd1;
            end else if (pad != 2'd0) begin
                sn[0] <= last_n; sn[1] <= sn[0]; sn[2] <= sn[1]; sn[3] <= sn[2]; sn[4] <= sn[3];
                sc[0] <= last_c; sc[1] <= sc[0]; sc[2] <= sc[1]; sc[3] <= sc[2]; sc[4] <= sc[3];
                ss[0] <= last_s; ss[1] <= ss[0]; ss[2] <= ss[1]; ss[3] <= ss[2]; ss[4] <= ss[3];
                pad <= pad - 2'd1;
            end

            // Same horizontal alignment as isp_window5: center column is tap 2,
            // first emit after 2 pixels, then 2 replicated pixels past EOL.
            // y_line==0 is the replicated first line and is not a real row.
            if (((de_d && (x_d >= 11'd2)) ||
                 (pad != 2'd0 && !de_d && gap >= GAP_CYC)) &&
                (y_line != 11'd0) && first_line_ready) begin
                out_de <= 1'b1;
                out_vs <= vs_d;
                if (de_d)
                    out_x <= x_d - 11'd2;
                else
                    out_x <= out_x + 11'd1;
                out_y <= y_center;
                // At x_d==3 the center is pixel 0 and the west tap is still
                // a copy of that pixel. The east tap is pixel 1, which has
                // the phase the missing left neighbor would have had.
                if (de_d && (x_d == 11'd3)) begin
                    nw <= sn[1]; n <= sn[2]; ne <= sn[1];
                    w  <= sc[1]; c <= sc[2]; e  <= sc[1];
                    sw <= ss[1]; s <= ss[2]; se <= ss[1];
                end else begin
                    nw <= sn[3]; n <= sn[2]; ne <= sn[1];
                    w  <= sc[3]; c <= sc[2]; e  <= sc[1];
                    sw <= ss[3]; s <= ss[2]; se <= ss[1];
                end
            end else begin
                out_de <= 1'b0;
                out_vs <= vs_d;
            end

            // Arm only in the blank after the last line. A new DE before
            // the readback starts cancels it, so a late line is never
            // inserted into the next frame.
            if (replay || de_d)
                replay_arm <= 1'b0;
            else if ((gap >= GAP_CYC) && (pad == 2'd1) &&
                     (y_hold == HEIGHT-1))
                replay_arm <= 1'b1;
        end
    end
endmodule
