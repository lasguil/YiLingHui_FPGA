// Capture one validated 1080p HDMI frame per MJPEG request and reduce it to
// 1280x720 by keeping two of every three source rows and columns. The HDMI
// receiver cannot be backpressured, so a small Gray-pointer FIFO crosses the
// recovered pixel clock into proc_clk, where the JPEG encoder applies ready.
module mjpeg_hdmi_720p_source #(
    parameter int SRC_W = 1920,
    parameter int SRC_H = 1080,
    parameter int FIFO_ADDR_W = 10
) (
    input  logic        pclk,
    input  logic        proc_clk,
    input  logic        reset,
    input  logic        request,
    input  logic        hdmi_vs,
    input  logic        hdmi_de,
    input  logic [7:0]  hdmi_r,
    input  logic [7:0]  hdmi_g,
    input  logic [7:0]  hdmi_b,
    output logic [23:0] tdata,
    output logic        tvalid,
    input  logic        tready,
    output logic        tlast,
    output logic        tuser,
    output logic        overflow_sticky,
    output logic        source_error_sticky,
    output logic        frame_done_toggle
);
    logic request_toggle;
    (* async_reg = "true" *) logic [2:0] request_sync;
    logic request_seen;
    logic request_pending;
    logic capture_active;
    logic source_mode_ok;

    logic p_vs_d, p_de_d;
    logic [10:0] src_x, src_y;
    logic src_bad, p_frame_seen;

    // reset originates in proc_clk; synchronize release for the recovered
    // HDMI pixel clock before using it on source-timing state.
    (* async_reg = "true" *) logic [1:0] pclk_reset_pipe;
    always_ff @(posedge pclk or posedge reset) begin
        if (reset) pclk_reset_pipe <= '0;
        else       pclk_reset_pipe <= {pclk_reset_pipe[0], 1'b1};
    end
    wire pclk_reset = !pclk_reset_pipe[1];
    wire vs_rise = hdmi_vs && !p_vs_d;
    wire sample_pixel = capture_active && hdmi_de && src_x < SRC_W && src_y < SRC_H &&
                        (src_x % 3 != 2) && (src_y % 3 != 2);
    wire sample_sof = src_x == 0 && src_y == 0;
    wire sample_eol = src_x == SRC_W-2;
    wire sample_eof = src_x == SRC_W-2 && src_y == SRC_H-2;

    logic [25:0] fifo_wdata, fifo_rdata;
    logic fifo_full, fifo_empty;
    wire fifo_pop = tvalid && tready;

    always_ff @(posedge proc_clk or posedge reset) begin
        if (reset) request_toggle <= 1'b0;
        else if (request) request_toggle <= ~request_toggle;
    end

    always_ff @(posedge pclk) begin
        if (pclk_reset) begin
            request_sync <= '0;
            request_seen <= 1'b0;
            request_pending <= 1'b0;
            capture_active <= 1'b0;
            source_mode_ok <= 1'b0;
            p_vs_d <= 1'b0;
            p_de_d <= 1'b0;
            src_x <= '0;
            src_y <= '0;
            src_bad <= 1'b0;
            p_frame_seen <= 1'b0;
            overflow_sticky <= 1'b0;
            source_error_sticky <= 1'b0;
            frame_done_toggle <= 1'b0;
        end else begin
            request_sync <= {request_sync[1:0], request_toggle};
            p_vs_d <= hdmi_vs;
            p_de_d <= hdmi_de;

            if (request_sync[2] != request_seen) begin
                request_seen <= request_sync[2];
                request_pending <= 1'b1;
            end

            if (vs_rise) begin
                source_mode_ok <= p_frame_seen && !src_bad && src_y == SRC_H && src_x == 0;
                p_frame_seen <= 1'b1;
                src_x <= '0;
                src_y <= '0;
                src_bad <= 1'b0;
                if (capture_active)
                    source_error_sticky <= 1'b1;
                capture_active <= request_pending && source_mode_ok;
                if (request_pending && source_mode_ok)
                    request_pending <= 1'b0;
            end else begin
                if (hdmi_de) begin
                    if (src_x < SRC_W) src_x <= src_x + 1'b1;
                    else src_bad <= 1'b1;
                end
                if (p_de_d && !hdmi_de) begin
                    if (src_x != SRC_W) src_bad <= 1'b1;
                    src_x <= '0;
                    if (src_y < SRC_H) src_y <= src_y + 1'b1;
                    else src_bad <= 1'b1;
                end

                if (sample_pixel && fifo_full)
                    overflow_sticky <= 1'b1;
                if (sample_pixel && sample_eof) begin
                    capture_active <= 1'b0;
                    frame_done_toggle <= ~frame_done_toggle;
                end
                if (capture_active && src_bad)
                    source_error_sticky <= 1'b1;
            end
        end
    end

    assign fifo_wdata = {sample_sof, sample_eol, hdmi_r, hdmi_g, hdmi_b};
    gesture_async_fifo #(.DATA_W(26), .ADDR_W(FIFO_ADDR_W)) u_pixel_fifo (
        .arst(reset), .wclk(pclk), .wr_en(sample_pixel && !fifo_full), .wr_data(fifo_wdata),
        .full(fifo_full), .rclk(proc_clk), .rd_en(fifo_pop), .rd_data(fifo_rdata),
        .empty(fifo_empty));

    assign tvalid = !fifo_empty;
    assign tdata = fifo_rdata[23:0];
    assign tlast = fifo_rdata[24];
    assign tuser = fifo_rdata[25];
endmodule
