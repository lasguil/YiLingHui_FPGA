// 4 条重量化车道。每拍接收 LANE_N 个累加值、产出 LANE_N 个码值。
//
// 参数（m18/post/B_fixed/zp）随值同行，由引擎按输出通道读出并一起推进，
// 所以车道本身不需要参数存储。
module gesture_rq_array #(
    parameter int LANE_N = 4,
    parameter bit USE_DSP = 1'b1,
    parameter int ACC_WIDTH = 32
) (
    input  logic                    clk,
    input  logic                    reset,
    input  logic                    in_valid,
    input  logic [LANE_N*32-1:0]    in_acc_flat,
    input  logic [LANE_N*17-1:0]    in_m18_flat,
    input  logic [LANE_N*6-1:0]     in_post_flat,
    input  logic [LANE_N*32-1:0]    in_bfix_flat,
    input  logic [LANE_N*8-1:0]     in_zp_flat,
    output logic                    out_valid,
    output logic [LANE_N*8-1:0]     out_code_flat,
    output logic signed [LANE_N*22-1:0] out_fixed_flat
);
    logic lane_valid [0:LANE_N-1];

    for (genvar l = 0; l < LANE_N; l++) begin : g_lane
        gesture_rq_lane #(.USE_DSP(USE_DSP), .ACC_WIDTH(ACC_WIDTH)) u_rq (
            .clk       (clk),
            .reset     (reset),
            .in_valid  (in_valid),
            .in_acc    (in_acc_flat[l*32 +: 32]),
            .in_m18    (in_m18_flat[l*17 +: 17]),
            .in_post   (in_post_flat[l*6 +: 6]),
            .in_bfix   (in_bfix_flat[l*32 +: 32]),
            .in_zp     (in_zp_flat[l*8 +: 8]),
            .out_valid (lane_valid[l]),
            .out_code  (out_code_flat[l*8 +: 8]),
            .out_fixed_q10(out_fixed_flat[l*22 +: 22])
        );
    end

    // 整批同拍推进，valid 取任一条即可（用 0 号，并对其余做仿真一致性检查）。
    assign out_valid = lane_valid[0];

`ifdef SIM_ASSERT
    always_ff @(posedge clk) begin
        if (!reset) begin
            for (int l = 1; l < LANE_N; l++)
                if (lane_valid[l] !== lane_valid[0])
                    $fatal(1, "rq_array: lane %0d valid disagrees with lane 0", l);
        end
    end
`endif
endmodule
