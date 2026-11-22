`timescale 1ns/1ps
module tb_web_control_mailbox;
    reg net_clk=0, cpu_clk=0, arst=1;
    always #5 net_clk=~net_clk;
    always #7 cpu_clk=~cpu_clk;
    reg cmd_valid=0;
    wire cmd_ready;
    reg [31:0] cmd_token=0;
    reg [7:0] cmd_type=0, cmd_length=0;
    reg [431:0] cmd_payload=0;
    reg psel=0, penable=0, pwrite=0;
    reg [11:0] paddr=0;
    reg [31:0] pwdata=0;
    wire [31:0] prdata;
    wire pready, pslverr;
    wire net_status_valid;
    wire [63:0] net_status_data;
    integer i;
    reg [7:0] got [0:8];
    reg [63:0] status_got;

    web_control_mailbox dut(.*);

    task read_command_byte(output [7:0] value);
        begin
            @(negedge cpu_clk);
            psel=1; penable=1; pwrite=0; paddr=12'h004;
            #1;
            while (!pready) @(negedge cpu_clk);
            #1 value=prdata[7:0];
            @(posedge cpu_clk);
            #1 psel=0; penable=0;
        end
    endtask

    task apb_write(input [11:0] address, input [31:0] value);
        begin
            @(negedge cpu_clk);
            psel=1; penable=1; pwrite=1; paddr=address;
            pwdata=value;
            #1;
            if (!pready || pslverr) $fatal(1,"status APB write rejected");
            @(posedge cpu_clk);
            #1 psel=0; penable=0; pwrite=0;
        end
    endtask

    initial begin
        repeat (4) @(posedge cpu_clk);
        arst=0;
        wait(cmd_ready);
        @(negedge net_clk);
        cmd_token=32'h12345678;
        cmd_type=8'h13;
        cmd_length=3;
        cmd_payload[7:0]=8'h04;
        cmd_payload[15:8]=8'h00;
        cmd_payload[23:16]=8'h00;
        cmd_valid=1;
        @(negedge net_clk); cmd_valid=0;
        wait(!dut.busy);
        if (cmd_ready) $fatal(1,"new command accepted before wire completion");
        repeat (6) @(posedge cpu_clk);
        for (i=0;i<9;i=i+1) read_command_byte(got[i]);
        #1;
        if (got[0]!==8'h78 || got[1]!==8'h56 || got[2]!==8'h34 || got[3]!==8'h12 ||
            got[4]!==8'h13 || got[5]!==8'h03 || got[6]!==8'h04 ||
            got[7]!==8'h00 || got[8]!==8'h00)
            $fatal(1,"mailbox record mismatch");
        if (pslverr!==1'b0 || pready!==1'b1)
            $fatal(1,"APB response invalid");
        apb_write(12'h008,32'h12345678);
        apb_write(12'h00c,32'hbeef0004);
        apb_write(12'h010,32'd1);
        wait(net_status_valid);
        status_got=net_status_data;
        @(posedge net_clk);
        if (status_got!==64'hbeef000412345678)
            $fatal(1,"status mailbox mismatch: %h",status_got);
        wait(cmd_ready);
        $display("PASS: atomic command record crossed network/CPU clocks over APB");
        $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
