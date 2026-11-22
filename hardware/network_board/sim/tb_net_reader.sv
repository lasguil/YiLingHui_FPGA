`timescale 1ns/1ps
module tb_net_reader;
    parameter OW=240, OH=136;
    logic [30:0] source_seq=17;
    integer starts=0;
    import demo_bus_pkg::*;
    logic clk=0,nclk=0,reset=1;
    always #2.778 clk=~clk;
    always #20 nclk=~nclk;
    logic begin_frame=0,end_frame=0,pop=0;
    wire available,busy,error,valid,locked,slot;
    wire [15:0] pixel;wire [31:0] count;
    axi_req_t req;axi_rsp_t rsp;
    logic active=0,inject_error=0;
    logic [31:0] address;
    logic [7:0] length,beat;
    logic [31:0] random_q=32'h12345678;
    integer bursts=0;
    gesture_net_reader #(.OUT_W(OW),.OUT_H(OH)) dut(.proc_clk(clk),.net_clk(nclk),.reset,
      .frame_valid(1'b1),.video_lost(1'b0),.published_slot(1'b0),.published_seq(source_seq),
      .frame0_base(32'h03000000),.frame1_base(32'h03100000),
      .net_lock(locked),.net_lock_slot(slot),.axi_req(req),.axi_rsp(rsp),
      .frame_begin(begin_frame),.frame_end(end_frame),.pixel_pop(pop),
      .available,.busy,.error,.pixel_data(pixel),.pixel_valid(valid),.frame_count(count));
    function automatic [7:0] source_byte(input logic [31:0] addr);
        integer offset,x,y,component;
        begin
            offset=int'(addr-32'h03000000);y=offset/1920;x=(offset%1920)/3;component=offset%3;
            case(component)
              0:source_byte=8'(x+y);
              1:source_byte=8'(x*3+y);
              default:source_byte=8'(x+y*7);
            endcase
        end
    endfunction
    always_comb begin
        rsp='0;rsp.arready=!active&&random_q[0];rsp.rvalid=active&&random_q[1];
        rsp.rlast=beat==length;rsp.rresp=inject_error ? 2'd2:0;
        for(integer i=0;i<16;i++)rsp.rdata[i*8+:8]=source_byte(address+32'(beat)*16+32'(i));
    end
    always @(posedge clk)begin
        random_q<={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
        if(req.arvalid&&rsp.arready)begin
            if(active||req.araddr[3:0]!=0||({1'b0,req.araddr[11:0]}+(13'(req.arlen)+1)*16)>4096)
                $fatal(1,"unaligned/overlapping/4KiB crossing burst");
            if(!locked||slot!=0)$fatal(1,"DDR access without source lock");
            active<=1;address<=req.araddr;length<=req.arlen;beat<=0;bursts<=bursts+1;
        end
        if(rsp.rvalid&&req.rready)begin
            if(rsp.rlast)active<=0;else beat<=beat+1'b1;
        end
    end
    task automatic start;
        if(starts>0)begin
            if(available)$fatal(1,"stale source was available twice");
            source_seq=source_seq+1'b1;
        end
        starts=starts+1;
        wait(available);@(negedge nclk);begin_frame=1;@(negedge nclk);begin_frame=0;
    endtask
    task automatic release_frame;
        @(negedge nclk);end_frame=1;@(negedge nclk);end_frame=0;
        wait(!busy);repeat(6)@(negedge nclk);
    endtask
    initial begin
        repeat(8)@(negedge nclk);reset=0;
        start();
        for(integer n=0;n<OW*OH;n++)begin
            integer sx,sy;logic [7:0] r,g,b;logic [15:0] expected_pixel;
            @(negedge nclk);pop=0;
            repeat(n%5)@(negedge nclk);
            while(!valid)@(negedge nclk);
            sx=(n%OW)*640/OW;sy=(n/OW)*360/OH;
            r=8'(sx+sy);g=8'(sx*3+sy);b=8'(sx+sy*7);
            expected_pixel={r[7:3],g[7:2],b[7:3]};
            if(error||pixel!==expected_pixel)$fatal(1,"full-size pixel %0d got %h expected %h",n,pixel,expected_pixel);
            pop=1;@(negedge nclk);pop=0;
        end
        release_frame();
        if(valid||locked||count!=17)$fatal(1,"frame release/FIFO accounting");
        // Error drains the accepted burst, then releases only after cancellation.
        inject_error=1;start();wait(error);release_frame();
        if(active||locked||valid)$fatal(1,"error left outstanding data or slot lock");
        inject_error=0;
        // Cancel with a burst outstanding; drain it before releasing its source.
        start();wait(active);release_frame();
        if(active||locked||valid)$fatal(1,"cancel failed to drain accepted burst");
        $display("PASS: %0d RGB565 pixels, RGB word crossings, 4KiB splitting, async backpressure, AXI error and cancellation; bursts=%0d",OW*OH,bursts);
        $finish;
    end
    initial begin #50_000_000;$fatal(1,"reader timeout");end
endmodule
