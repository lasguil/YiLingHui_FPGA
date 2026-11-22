`timescale 1ns/1ps
module tb_apb_csr_cdc;
    logic s_clk=0, m_clk=0;
    always #5 s_clk=~s_clk;
    always #7 m_clk=~m_clk;

    logic s_reset=1, m_reset=1;
    logic s_psel=0, s_penable=0, s_pwrite=0;
    logic [11:0] s_paddr=0;
    logic [31:0] s_pwdata=0;
    wire [31:0] s_prdata;
    wire s_pready, s_pslverr;
    wire m_psel, m_penable, m_pwrite;
    wire [11:0] m_paddr;
    wire [31:0] m_pwdata;
    logic [31:0] m_prdata=0;
    logic m_pready=0, m_pslverr=0;

    apb_csr_cdc dut(.*);

    logic [31:0] regs[0:1023];
    logic setup_seen=0;
    logic [11:0] setup_addr;
    logic setup_write;
    logic [31:0] setup_wdata;
    integer wait_count=0;
    integer remote_accesses=0;
    integer delay_cycles=0;
    logic remote_enable=0;
    logic protocol_fault=0;

    always @(posedge m_clk) begin
        if(m_reset) begin
            setup_seen<=0;
            m_pready<=0;
            wait_count<=0;
        end else begin
            m_pready<=0;
            if(m_psel && !m_penable) begin
                setup_seen<=1;
                setup_addr<=m_paddr;
                setup_write<=m_pwrite;
                setup_wdata<=m_pwdata;
                wait_count<=delay_cycles;
            end
            if(m_psel && m_penable) begin
                if(!setup_seen || m_paddr!==setup_addr || m_pwrite!==setup_write ||
                   (m_pwrite && m_pwdata!==setup_wdata)) begin
                    protocol_fault<=1;
                    $error("APB ACCESS lacked stable preceding SETUP");
                end
                if(m_pready) begin
                    setup_seen<=0;
                end else if(wait_count!=0) wait_count<=wait_count-1;
                else if(remote_enable) begin
                    if(m_pwrite) regs[m_paddr[11:2]]<=m_pwdata;
                    else m_prdata<=regs[m_paddr[11:2]];
                    $display("REMOTE access wr=%b addr=%h data=%h rdata=%h",m_pwrite,m_paddr,m_pwdata,regs[m_paddr[11:2]]);
                    m_pslverr<=1'b0;
                    remote_accesses<=remote_accesses+1;
                    m_pready<=1;
                end
            end else if(!m_psel) setup_seen<=0;
        end
    end

    task automatic apb_transfer(input logic wr, input logic [11:0] addr,
                                input logic [31:0] wdata, output logic [31:0] rdata);
        begin
            @(negedge s_clk); s_psel=1; s_penable=0; s_pwrite=wr; s_paddr=addr; s_pwdata=wdata;
            @(negedge s_clk); s_penable=1;
            while(!s_pready && !s_reset) @(posedge s_clk);
            if(s_reset) rdata=0;
            else rdata=s_prdata;
            @(negedge s_clk); s_psel=0; s_penable=0; s_pwrite=0;
        end
    endtask

    logic [31:0] rd;
    integer before_accesses;
    initial begin
        foreach(regs[i]) regs[i]=32'hcafe_0000+i;
        repeat(6) @(negedge s_clk);
        s_reset=0; m_reset=0;
        // Source starts while DDR is not ready. CDC clocks/resets are live, but
        // target PREADY is gated low until calibration has completed.
        fork
            begin apb_transfer(1,12'h024,32'h1234_5678,rd); end
            begin
                repeat(10) @(negedge m_clk);
                if(remote_accesses!=0) $fatal(1,"target accepted while DDR-ready gate was low");
                remote_enable=1;
            end
        join
        if(regs[9]!==32'h1234_5678) $fatal(1,"delayed target release lost/mangled write");

        delay_cycles=4;
        apb_transfer(0,12'h024,0,rd);
        if(rd!==32'h1234_5678) $fatal(1,"read data mismatch %h",rd);
        apb_transfer(1,12'h028,32'h89ab_cdef,rd);
        apb_transfer(0,12'h028,0,rd);
        if(rd!==32'h89ab_cdef) $fatal(1,"back-to-back read/write mismatch %h",rd);

        before_accesses=remote_accesses;
        // Reset both sides while an APB command is held in the remote wait phase.
        delay_cycles=100;
        fork
            begin apb_transfer(1,12'h030,32'hbad0_1001,rd); end
            begin
                wait(m_psel && m_penable);
                repeat(3) @(negedge m_clk);
                @(negedge s_clk); s_reset=1; m_reset=1;
                repeat(5) @(negedge s_clk);
                s_psel=0; s_penable=0;
                s_reset=0; m_reset=0;
            end
        join
        delay_cycles=0;
        if(remote_accesses!=before_accesses) $fatal(1,"reset-in-flight command reached target");

        // Fresh post-reset requests must not replay the cancelled command or return old data.
        @(negedge s_clk); s_reset=1; m_reset=1; s_psel=0; s_penable=0;
        repeat(5) @(negedge s_clk);
        s_reset=0; m_reset=0;
        remote_enable=1;
        apb_transfer(1,12'h02c,32'hfeed_0102,rd);
        apb_transfer(0,12'h02c,0,rd);
        if(rd!==32'hfeed_0102) $fatal(1,"post-reset stale/lost data %h",rd);
        apb_transfer(0,12'h024,0,rd);
        if(rd!==32'h1234_5678) $fatal(1,"old command state corrupted after reset %h",rd);
        if(remote_accesses!=before_accesses+3)
            $fatal(1,"duplicate/lost target access count got %0d expected %0d",remote_accesses,before_accesses+3);
        if(protocol_fault) $fatal(1,"remote APB phase/protocol violation");
        $display("PASS: APB CDC delayed target reset release, wait states, back-to-back read/write and coordinated reset recovery; remote accesses=%0d (initial=%0d)",remote_accesses,before_accesses);
        $finish;
    end
    initial begin #1000000;
        $display("timeout: s_psel=%b s_penable=%b ready=%b active=%b req=%b ack_sync=%b mstate=%b req_sync=%b ack=%b m_psel=%b m_penable=%b mready=%b remote_enable=%b accesses=%0d",
            s_psel,s_penable,s_pready,dut.active_q,dut.req_toggle,dut.ack_sync2,dut.mstate_q,dut.req_sync2,dut.ack_toggle,m_psel,m_penable,m_pready,remote_enable,remote_accesses);
        $fatal(1,"APB CDC simulation timeout");
    end
endmodule
