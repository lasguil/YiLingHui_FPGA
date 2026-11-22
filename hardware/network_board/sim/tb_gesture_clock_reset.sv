`timescale 1ns/1ps
module tb_gesture_clock_reset;
    logic core_clk=0, proc_clk=0, async_reset_n=0;
    logic core_pll_locked=0, proc_pll_locked=0, cal_done=0;
    logic cpu_reset_n, proc_cdc_reset_n, proc_reset_n, proc_ddr_ready, runtime_cal_lost, cal_done_core;
    always #5 core_clk=~core_clk;
    initial begin #1.7; forever #2.7777778 proc_clk=~proc_clk; end

    gesture_clock_reset dut(.*);

    task automatic wait_cpu_boot;
        integer timeout;
        begin
            timeout=0;
            while (!cpu_reset_n && timeout<1200) begin @(posedge core_clk); timeout++; end
            if (!cpu_reset_n) $fatal(1,"CPU did not boot after both PLLs locked");
        end
    endtask

    initial begin
        repeat(5) @(posedge core_clk);
        async_reset_n=1; core_pll_locked=1;
        repeat(20) @(posedge core_clk);
        if(cpu_reset_n) $fatal(1,"CPU released before proc PLL lock");
        proc_pll_locked=1;
        wait_cpu_boot();

        repeat(5) @(posedge proc_clk);
        if(!proc_cdc_reset_n) $fatal(1,"proc CDC epoch did not release after PLL boot");
        if(proc_reset_n || proc_ddr_ready) $fatal(1,"proc datapath released before DDR calibration");

        cal_done=1;
        begin : wait_proc_ready
            integer timeout;
            timeout=0;
            while(!proc_reset_n && timeout<20) begin @(posedge proc_clk); timeout++; end
            if(!proc_reset_n || !proc_ddr_ready) $fatal(1,"proc datapath did not release after synchronized calibration");
        end
        repeat(3) @(posedge core_clk);
        if(!cal_done_core) $fatal(1,"core-domain calibration status did not synchronize high");

        // A runtime calibration loss must flush CPU and both CDC epochs and
        // remain fail-stopped instead of stranding accepted AXI transactions.
        cal_done=0;
        repeat(3) @(posedge core_clk);
        if(cal_done_core) $fatal(1,"core-domain calibration status did not synchronize low");
        begin : wait_fault
            integer timeout;
            timeout=0;
            while(!runtime_cal_lost && timeout<20) begin @(posedge core_clk); timeout++; end
            if(!runtime_cal_lost) $fatal(1,"runtime DDR calibration loss was not latched");
        end
        repeat(5) @(posedge proc_clk);
        if(cpu_reset_n || proc_reset_n || proc_cdc_reset_n)
            $fatal(1,"runtime DDR loss did not fail-stop all domains");
        repeat(20) @(posedge core_clk);
        if(cpu_reset_n || !runtime_cal_lost) $fatal(1,"runtime loss did not remain latched until external reset");

        async_reset_n=0; core_pll_locked=0; proc_pll_locked=0;
        repeat(5) @(posedge core_clk);
        async_reset_n=1; core_pll_locked=1; proc_pll_locked=1;
        wait_cpu_boot();
        repeat(5) @(posedge proc_clk);
        if(runtime_cal_lost || !proc_cdc_reset_n || proc_reset_n)
            $fatal(1,"external reset failed to begin a clean pre-calibration boot");

        $display("PASS: 100/180 reset release, CPU boot before DDR cal, proc cal synchronization, runtime-loss fail-stop and external-reset recovery");
        $finish;
    end

    initial begin #100000;$fatal(1,"clock reset test timed out"); end
endmodule
