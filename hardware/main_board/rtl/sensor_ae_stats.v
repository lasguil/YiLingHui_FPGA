// Decimated RAW-domain metering. Physical BGGR: green is x[0]!=y[0].
// Coordinates start at sensor row 0; the old blank-induced +1 is removed.
// Per 64 columns, sample one green for brightness and two CFA sites for
// clipping. 1080p gives 32400 green / 64800 clipping samples per frame.
// Publish a stable action plus a toggle at the next frame start; no divider,
// multiplier, frame RAM, or pixel modification is required.
module sensor_ae_stats (
    input wire clk,
    input wire rst_n,
    input wire in_vs,
    input wire in_de,
    input wire [9:0] in_raw,
    input wire [10:0] in_x,
    input wire in_y0,
    output reg frame_toggle,
    output reg [1:0] action
);
    localparam [1:0] HOLD=2'd0, DOWN=2'd1, UP=2'd2, FAST_DOWN=2'd3;
    reg vs_d;
    reg [14:0] green_count;
    reg [20:0] green_sum;
    reg [15:0] clipped_count;
    wire green_sample = in_de && (in_x[5:0] == {5'd0,~in_y0});
    wire clip_sample = in_de && (in_x[5:1] == 5'd0);
    wire complete_frame = (green_count >= 15'd32000) &&
                          (green_count <= 15'd32500);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d <= 1'b0;
            green_count <= 15'd0;
            green_sum <= 21'd0;
            clipped_count <= 16'd0;
            frame_toggle <= 1'b0;
            action <= HOLD;
        end else begin
            vs_d <= in_vs;
            if (in_vs && !vs_d) begin
                frame_toggle <= ~frame_toggle;
                action <= HOLD;
                if (complete_frame) begin
                    // About 1.6% near-ADC-full-scale samples; tolerate tiny
                    // lamps/specular points rather than chase every bright dot.
                    if (clipped_count >= 16'd1024)
                        action <= FAST_DOWN;
                    // Sum floor(RAW/16): uniform RAW >=144 requests down.
                    else if (green_sum > 21'd262144)
                        action <= DOWN;
                    // Uniform RAW <=111 requests up if <~0.4% clipped.
                    else if ((green_sum < 21'd196608) &&
                             (clipped_count <= 16'd256))
                        action <= UP;
                end
                green_count <= 15'd0;
                green_sum <= 21'd0;
                clipped_count <= 16'd0;
            end else begin
                if (green_sample && green_count < 15'd32500) begin
                    green_count <= green_count + 15'd1;
                    green_sum <= green_sum + {15'd0,in_raw[9:4]};
                end
                if (clip_sample && in_raw >= 10'd960 && clipped_count != 16'hffff)
                    clipped_count <= clipped_count + 16'd1;
            end
        end
    end
endmodule
