// Reset and DDR-ready sequencing for the 100MHz CPU / 180MHz proc domains.
// CPU boot is independent of initial DDR calibration so firmware can report
// and park on a cold DDR. A calibration loss after a successful calibration
// latches a fail-stop reset until external reset; this flushes both CDC epochs
// rather than leaving CPU transactions waiting for responses that cannot come.
module gesture_clock_reset #(
    parameter integer CPU_RESET_BITS = 10
) (
    input  logic core_clk,
    input  logic proc_clk,
    input  logic async_reset_n,
    input  logic core_pll_locked,
    input  logic proc_pll_locked,
    input  logic cal_done,
    output logic cpu_reset_n,
    output logic proc_cdc_reset_n,
    output logic proc_reset_n,
    output logic proc_ddr_ready,
    output logic runtime_cal_lost,
    output logic cal_done_core
);
    wire pll_boot_ok = async_reset_n & core_pll_locked & proc_pll_locked;
    logic [CPU_RESET_BITS-1:0] cpu_reset_count;
    (* async_reg = "true" *) logic cal_done_core_meta, cal_done_core_sync;

    always_ff @(posedge core_clk or negedge pll_boot_ok) begin
        if (!pll_boot_ok) cpu_reset_count <= '0;
        else if (!(&cpu_reset_count)) cpu_reset_count <= cpu_reset_count + 1'b1;
    end
    always_comb cal_done_core = cal_done_core_sync;

    logic cal_seen_core;
    always_ff @(posedge core_clk or negedge pll_boot_ok) begin
        if (!pll_boot_ok) begin
            cal_done_core_meta <= 1'b0;
            cal_done_core_sync <= 1'b0;
            cal_seen_core <= 1'b0;
            runtime_cal_lost <= 1'b0;
        end else begin
            cal_done_core_meta <= cal_done;
            cal_done_core_sync <= cal_done_core_meta;
            if (cal_done_core_sync) cal_seen_core <= 1'b1;
            if (cal_seen_core && !cal_done_core_sync) runtime_cal_lost <= 1'b1;
        end
    end

    always_comb begin
        cpu_reset_n = pll_boot_ok & (&cpu_reset_count) & !runtime_cal_lost;
    end

    // The CDC epoch reset is independent of calibration, asynchronously
    // asserted and synchronously released in the destination domain.
    wire cdc_epoch_ok = pll_boot_ok & !runtime_cal_lost;
    logic [1:0] proc_cdc_reset_pipe;
    always_ff @(posedge proc_clk or negedge cdc_epoch_ok) begin
        if (!cdc_epoch_ok) proc_cdc_reset_pipe <= 2'b00;
        else proc_cdc_reset_pipe <= {proc_cdc_reset_pipe[0],1'b1};
    end
    always_comb proc_cdc_reset_n = proc_cdc_reset_pipe[1];

    // Cal_done is synchronized before either the DDR gate or accelerator
    // reset is released. The extra two cycles give downstream reset release
    // a clean proc_clk edge after synchronized calibration status.
    (* async_reg = "true" *) logic cal_done_proc_meta, cal_done_proc_sync;
    logic [1:0] proc_reset_pipe;
    always_ff @(posedge proc_clk or negedge proc_cdc_reset_n) begin
        if (!proc_cdc_reset_n) begin
            cal_done_proc_meta <= 1'b0;
            cal_done_proc_sync <= 1'b0;
            proc_reset_pipe <= 2'b00;
        end else begin
            cal_done_proc_meta <= cal_done;
            cal_done_proc_sync <= cal_done_proc_meta;
            proc_reset_pipe <= {proc_reset_pipe[0], cal_done_proc_sync};
        end
    end
    always_comb begin
        proc_ddr_ready = proc_reset_pipe[1];
        proc_reset_n = proc_ddr_ready;
    end
endmodule
