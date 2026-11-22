`timescale 1ns/1ps
module tb_capture_recovery;
    import demo_bus_pkg::*;
    localparam int SW=96, SH=48, BYTES=SW*SH/9*3;
    logic clk=0,pclk=0,reset=1,vs=0,de=0;
    always #2.778 clk=~clk;
    always #3.367 pclk=~pclk;
    logic valid,slot,overflow,error,lost;
    logic [30:0] seq;
    axi_req_t req;
    axi_rsp_t rsp;
    gesture_frame_capture #(.SRC_W(SW),.SRC_H(SH)) dut(
        .proc_clk(clk),.pclk,.reset,.hdmi_vs(vs),.hdmi_de(de),
        .hdmi_r(8'h12),.hdmi_g(8'h34),.hdmi_b(8'h56),
        .frame0_base(32'h03000000),.frame1_base(32'h03100000),
        .net_lock(1'b0),.net_lock_slot(1'b0),.roi_lock(1'b0),.roi_lock_slot(1'b0),
        .clear_errors(1'b0),.frame_valid(valid),.published_slot(slot),.published_seq(seq),
        .overflow_sticky(overflow),.error_sticky(error),.video_lost(lost),
        .axi_req(req),.axi_rsp(rsp));
    logic active=0,bvalid=0;
    logic first_response=1;
    int response_delay=0;
    logic [7:0] cycle=0;
    logic aw_stalled=0;
    logic [31:0] held_awaddr;
    logic [7:0] held_awlen;
    int left=0;
    logic [31:0] addr;
    byte mem[0:2*BYTES-1];
    always_comb begin
        rsp='0;
        rsp.awready=!active&&!bvalid&&(cycle[2:0]<3);
        rsp.wready=active&&(cycle[1:0]!=0);
        rsp.bvalid=bvalid&&(response_delay==0);
    end
    always @(posedge clk) if(!reset) begin
        cycle<=cycle+1'b1;
        if(response_delay>0)response_delay<=response_delay-1;
        if(aw_stalled && (!req.awvalid || req.awaddr!=held_awaddr || req.awlen!=held_awlen))
            $fatal(1,"capture changed an unaccepted AXI AW during recovery");
        aw_stalled<=req.awvalid&&!rsp.awready;
        held_awaddr<=req.awaddr;held_awlen<=req.awlen;
        if(req.awvalid&&rsp.awready) begin
            active<=1;left<=int'(req.awlen)+1;addr<=req.awaddr;
        end
        if(req.wvalid&&rsp.wready) begin
            if(req.wlast!=(left==1)) $fatal(1,"AXI burst was truncated");
            for(int k=0;k<16;k++) begin
                if(addr>=32'h03100000) mem[BYTES+int'(addr-32'h03100000)+k]=req.wdata[k*8+:8];
                else mem[int'(addr-32'h03000000)+k]=req.wdata[k*8+:8];
            end
            addr<=addr+16;left<=left-1;
            if(left==1)begin
                active<=0;bvalid<=1;
                // Keep the first accepted burst outstanding across the
                // interrupted-frame boundary; recovery must drain its B.
                response_delay<=first_response?2000:2;
                first_response<=0;
            end
        end
        if(req.bready&&rsp.bvalid)bvalid<=0;
    end
    task automatic frame(input bit truncated);
        @(negedge pclk);vs=1;de=0;
        repeat(4)@(negedge pclk);
        vs=0;
        for(int y=0;y<(truncated?13:SH);y++) begin
            for(int x=0;x<SW;x++) begin de=1;@(negedge pclk);end
            de=0;repeat(20)@(negedge pclk);
        end
        if(truncated)begin
            // Three sampled pixels leave nine bytes in the RGB packer and
            // fewer than sixteen complete beats behind the final AXI burst.
            for(int x=0;x<8;x++)begin de=1;@(negedge pclk);end
            de=0;
        end
        repeat(200)@(negedge pclk);
    endtask
    int previous_seq;
    initial begin
        repeat(20)@(negedge clk);reset=0;
        frame(1);
        repeat(6)frame(0);
        if(!valid||seq==0)$fatal(1,"capture did not recover from startup partial frame");
        previous_seq=int'(seq);
        frame(1);
        repeat(6)frame(0);
        if(int'(seq)<=previous_seq)$fatal(1,"capture froze after HDMI interruption");
        for(int i=0;i<BYTES;i++)
            if(mem[(slot?BYTES:0)+i]!=(i%3==0?8'h12:i%3==1?8'h34:8'h56))
                $fatal(1,"published frame contains bytes from an incomplete frame at %0d",i);
        // Once recovered, every complete source frame must publish at the next
        // boundary; the former implementation deliberately published every other.
        previous_seq=int'(seq);
        repeat(20)frame(0);
        if(int'(seq)-previous_seq!=20)$fatal(1,"capture did not publish every source frame: delta=%0d",int'(seq)-previous_seq);
        $display("PASS: 20 consecutive source frames published without deliberate frame skipping");
        $display("PASS: startup partial frame and HDMI interruption recover, full DDR pixels verified seq=%0d",seq);
        $finish;
    end
    initial begin #5_000_000;$fatal(1,"capture recovery timed out");end
endmodule
