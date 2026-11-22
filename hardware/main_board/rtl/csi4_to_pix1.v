// Convert CSI 4 x RAW10 (one beat on i_mipi_rx_pclk) to a 1-pixel stream
// on rd_clk. SC431HAI 1080p60 4ppc is ~31 MHz write / 148.5 MHz read, so
// the read side is always faster; one 1920/4=480-beat line plus margin
// fits in 512. HS defines the crop boundary on the write side; only the
// first WIDTH/4 qualified beats of each of the first HEIGHT rows are stored.
//
// dual_clock_fifo o_empty/o_full are combinational in i_re/i_we.  Feeding
// those flags straight back into i_re/i_we creates a combo loop; Efinity
// then ties the read enable to 0 and the ISP is deleted as constant-0.
module csi4_to_pix1 #(
    parameter WIDTH = 1920,
    parameter HEIGHT = 1080
) (
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [63:0] in_data,

    input  wire        rd_clk,
    input  wire        rd_rst_n,
    input  wire        rd_stall,
    output reg         out_vs,
    output wire        out_hs,
    output reg         out_de,
    output reg  [9:0]  out_raw,
    output wire        overflow
);
    // Efinix RAW10 table 19: first pixel is in_data[9:0].
    // Arrange the FIFO word MSB-first in raster order for the serializer.
    // Old capture dumps reversed each four-pixel group; undoing that
    // flips horizontal CFA parity (captured GBRG becomes physical BGGR).
    localparam DW = 42;
    localparam AW = 9;

    wire          wr_full;
    wire          rd_empty;
    wire [DW-1:0] rd_word;
    wire          wr_en;
    wire          can_issue;
    reg           rd_re;
    reg           re_q1;
    reg           have;
    reg           nxt_valid;
    reg  [1:0]    phase;
    reg           vs_h, de_h;
    reg           vs_n, de_n;
    reg  [9:0]    p0, p1, p2, p3;
    reg  [9:0]    n0, n1, n2, n3;

    assign out_hs = 1'b0;
    // Only pixel beats.  CSI vsync is a frame-level signal on this
    // board; stuffing it into the FIFO floods the gearbox and turns VS
    // into a short pulse, which the proven capture frame buffer cannot use.
    // Clip in the CSI clock domain, before the FIFO and ISP line RAMs.
    // Count qualified beats, not elapsed clocks or DE edges: short DE holes
    // inside a line must not restart the crop. HS defines the line boundary.
    localparam LINE_BEATS = WIDTH / 4;
    reg vs_d, hs_d;
    reg [11:0] row_count;
    reg [11:0] beat_count;
    wire frame_start = in_vs && !vs_d;
    wire line_start = in_hs && !hs_d;
    wire qualified = in_vs && in_hs && in_de;
    wire [12:0] current_row = frame_start ? 13'd1 :
                             (line_start ? {1'b0,row_count} + 13'd1 :
                                           {1'b0,row_count});
    wire row_keep = (current_row != 0) && (current_row <= HEIGHT);
    wire beat_keep = frame_start || line_start || (beat_count < LINE_BEATS);
    assign wr_en = qualified && row_keep && beat_keep;
    assign overflow = wr_en & wr_full;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            vs_d <= 1'b0;
            hs_d <= 1'b0;
            row_count <= 12'd0;
            beat_count <= 12'd0;
        end else begin
            vs_d <= in_vs;
            hs_d <= in_hs;
            if (frame_start)
                row_count <= in_hs ? 12'd1 : 12'd0;
            else if (line_start && in_vs && row_count <= HEIGHT)
                row_count <= row_count + 12'd1;
            if (frame_start || line_start)
                beat_count <= qualified ? 12'd1 : 12'd0;
            else if (qualified && beat_count < LINE_BEATS)
                beat_count <= beat_count + 12'd1;
        end
    end
    // Prefetch the next 4-pixel word while emitting pixel 1 so the FIFO
    // data returns on pixel 2 and pixel 3 is never dropped.  The old
    // (phase==2) issue overlapped re_q1 with pixel 3 and skipped it,
    // which made 1440-wide lines, GBRG slip, and green vertical stripes.
    assign can_issue = (~rd_empty) & (~rd_re) & (~re_q1) & (~rd_stall) &
                       (~nxt_valid) & ((~have) | (phase == 2'd1));

    wire [DW-1:0] wr_word = {
        in_vs, in_de,
        in_data[9:0],
        in_data[19:10],
        in_data[29:20],
        in_data[39:30]
    };

    dual_clock_fifo_wrapper #(
        .DATA_WIDTH     (DW),
        .ADDR_WIDTH     (AW),
        .OUTPUT_REG     ("FALSE"),
        .CHECK_FULL     ("TRUE"),
        .CHECK_EMPTY    ("TRUE"),
        .COMPATIBILITY  ("E")
    ) u_fifo (
        .i_arst   (~wr_rst_n | ~rd_rst_n),
        .i_wclk   (wr_clk),
        .i_we     (wr_en),
        .i_wdata  (wr_word),
        .i_rclk   (rd_clk),
        .i_re     (rd_re),
        .o_full   (wr_full),
        .o_empty  (rd_empty),
        .o_rdata  (rd_word),
        .o_afull  (),
        .o_wcnt   (),
        .o_aempty (),
        .o_rcnt   (),
        .o_dbg_w_re (),
        .o_dbg_w_waddrb_1P (),
        .o_dbg_w_waddrg_1P (),
        .o_dbg_r_waddrb_1P (),
        .o_dbg_r_waddrg_1P (),
        .o_dbg_r_waddrg_2P (),
        .o_dbg_r_wflag_1P (),
        .o_dbg_w_raddrb_1P (),
        .o_dbg_w_raddrg_1P (),
        .o_dbg_r_raddrb_1P (),
        .o_dbg_r_raddrg_1P (),
        .o_dbg_r_raddrg_2P (),
        .o_dbg_r_rflag_1P (),
        .o_dbg_r_rflag_2P ()
    );

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_re     <= 1'b0;
            re_q1     <= 1'b0;
            have      <= 1'b0;
            nxt_valid <= 1'b0;
            phase     <= 2'd0;
            vs_h      <= 1'b0;
            de_h      <= 1'b0;
            vs_n      <= 1'b0;
            de_n      <= 1'b0;
            p0        <= 10'd0;
            p1        <= 10'd0;
            p2        <= 10'd0;
            p3        <= 10'd0;
            n0        <= 10'd0;
            n1        <= 10'd0;
            n2        <= 10'd0;
            n3        <= 10'd0;
            out_vs    <= 1'b0;
            out_de    <= 1'b0;
            out_raw   <= 10'd0;
        end else begin
            rd_re <= can_issue;
            re_q1 <= rd_re;

            if (re_q1) begin
                vs_n      <= rd_word[41];
                de_n      <= rd_word[40];
                n0        <= rd_word[39:30];
                n1        <= rd_word[29:20];
                n2        <= rd_word[19:10];
                n3        <= rd_word[9:0];
                nxt_valid <= 1'b1;
            end

            if (have) begin
                out_vs <= vs_h;
                out_de <= de_h;
                case (phase)
                    2'd0:    out_raw <= p0;
                    2'd1:    out_raw <= p1;
                    2'd2:    out_raw <= p2;
                    default: out_raw <= p3;
                endcase
                if (phase == 2'd3) begin
                    if (nxt_valid) begin
                        vs_h      <= vs_n;
                        de_h      <= de_n;
                        p0        <= n0;
                        p1        <= n1;
                        p2        <= n2;
                        p3        <= n3;
                        nxt_valid <= 1'b0;
                        phase     <= 2'd0;
                    end else begin
                        have <= 1'b0;
                    end
                end else begin
                    phase <= phase + 2'd1;
                end
            end else if (nxt_valid) begin
                vs_h      <= vs_n;
                de_h      <= de_n;
                p0        <= n0;
                p1        <= n1;
                p2        <= n2;
                p3        <= n3;
                nxt_valid <= 1'b0;
                have      <= 1'b1;
                phase     <= 2'd1;
                out_vs    <= vs_n;
                out_de    <= de_n;
                out_raw   <= n0;
            end else begin
                out_de  <= 1'b0;
                out_raw <= 10'd0;
            end
        end
    end
endmodule
