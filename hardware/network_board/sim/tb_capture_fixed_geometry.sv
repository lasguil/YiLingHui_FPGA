`timescale 1ns/1ps
module tb_capture_fixed_geometry;
    import demo_bus_pkg::*;
    localparam int SW=96, SH=48, OUT_W=SW*2/3, OUT_H=SH*2/3, BYTES=OUT_W*OUT_H*3;
    logic clk=0,pclk=0,reset=1,vs=0,de=0;
    logic [7:0] r=0,g=0,b=0;
    always #2 clk=~clk;       // 250 MHz processing clock
    always #8 pclk=~pclk;     // 62.5 MHz source clock leaves ample drain margin
    logic valid,slot,overflow,error,lost,is720,mode_valid;
    logic [30:0] seq;
    axi_req_t req;
    axi_rsp_t rsp;
    gesture_frame_capture #(.SRC_W(SW),.SRC_H(SH),.DECIM(3),.FIFO_ADDR_W(12),
        .KEEP_TWO_OF_THREE(1'b1),.FAST_PACK(1'b1),.AUTO_INPUT_MODE(1'b0),
        .LOCK_SKIP_ERROR(1'b0),.WRITE_FIFO_AW(5),.WRITE_FIFO_REG_BITS(48)) dut(
        .proc_clk(clk),.pclk,.reset,.hdmi_vs(vs),.hdmi_de(de),.hdmi_r(r),.hdmi_g(g),.hdmi_b(b),
        .frame0_base(32'h03400000),.frame1_base(32'h03800000),
        .net_lock(1'b0),.net_lock_slot(1'b0),.roi_lock(1'b0),.roi_lock_slot(1'b0),
        .clear_errors(1'b0),.frame_valid(valid),.published_slot(slot),.published_seq(seq),
        .overflow_sticky(overflow),.error_sticky(error),.video_lost(lost),
        .input_is_720p(is720),.input_mode_valid(mode_valid),.axi_req(req),.axi_rsp(rsp));

    logic active=0,bvalid=0;
    int left=0;
    logic [31:0] addr;
    byte mem[0:2*BYTES-1];
    always_comb begin
        rsp='0;
        rsp.awready=!active&&!bvalid;
        rsp.wready=active;
        rsp.bvalid=bvalid;
    end
    function automatic int mem_index(input logic [31:0] a);
        return a>=32'h03800000 ? BYTES+int'(a-32'h03800000) : int'(a-32'h03400000);
    endfunction
    always @(posedge clk) begin
        if(reset) begin active<=0;bvalid<=0;left<=0;addr<=0;end
        else begin
            if(req.awvalid&&rsp.awready)begin
                active<=1;left<=int'(req.awlen)+1;addr<=req.awaddr;
            end
            if(req.wvalid&&rsp.wready)begin
                if(req.wlast!=(left==1))$fatal(1,"capture AXI WLAST mismatch");
                if(mem_index(addr)<0||mem_index(addr)+15>=2*BYTES)$fatal(1,"capture wrote outside frame buffers");
                for(int k=0;k<16;k++)mem[mem_index(addr)+k]=req.wdata[k*8+:8];
                addr<=addr+16;left<=left-1;
                if(left==1)begin active<=0;bvalid<=1;end
            end
            if(req.bready&&rsp.bvalid)bvalid<=0;
        end
    end

    task automatic source_frame_start;
        @(negedge pclk);de=0;vs=1;
        repeat(3)@(negedge pclk);
        vs=0;
        // Let the SOF marker cross to proc_clk and finish its frame decision.
        repeat(20)@(posedge clk);
    endtask
    task automatic send_active(input int width,input int height,input int fid);
        for(int y=0;y<height;y++)begin
            for(int x=0;x<width;x++)begin
                @(negedge pclk);
                de=1;r=8'(x+fid);g=8'(y^fid);b=8'(x+y+fid);
            end
            @(negedge pclk);de=0;
            repeat(3)@(negedge pclk);
        end
        repeat(1500)@(posedge clk);
    endtask
    task automatic check_published_frame(input int fid,input logic published_slot);
        int base,sx,sy,offset;
        base=published_slot?BYTES:0;
        for(int y=0;y<OUT_H;y++)begin
            sy=(y/2)*3+(y%2);
            for(int x=0;x<OUT_W;x++)begin
                sx=(x/2)*3+(x%2);
                offset=base+(y*OUT_W+x)*3;
                if(mem[offset]!==8'(sx+fid) || mem[offset+1]!==8'(sy^fid) ||
                   mem[offset+2]!==8'(sx+sy+fid))
                    $fatal(1,"published DDR pixel mismatch fid=%0d xy=%0d,%0d got=%h%h%h",fid,x,y,mem[offset],mem[offset+1],mem[offset+2]);
            end
        end
    endtask

    initial begin
        repeat(10)@(negedge clk);reset=0;
        repeat(5)@(posedge pclk);
        if(mode_valid!==1'b1||is720!==1'b0)$fatal(1,"fixed source metadata is not 1080p");

        // First valid image is published when the first sampled pixel of the next frame arrives.
        source_frame_start();
        send_active(SW,SH,1);
        source_frame_start();
        send_active(OUT_W,OUT_H,2);
        if(!valid||seq!=1)$fatal(1,"first full frame did not publish, valid=%b seq=%0d",valid,seq);
        check_published_frame(1,slot);

        // A 2/3-sized input is an invalid 720p frame under the fixed 1080p policy.
        source_frame_start();
        send_active(SW,SH,3);
        repeat(3000)@(posedge clk);
        if(seq!=1)$fatal(1,"720p frame was incorrectly published, seq=%0d",seq);
        if(!error)$fatal(1,"720p geometry rejection did not set the capture error");

        // A following full-size frame restores complete publication and image contents.
        source_frame_start();
        send_active(SW,SH,4);
        // The bad-frame toggle is synchronized into proc_clk, so allow one
        // clean full frame after that boundary before requiring publication.
        source_frame_start();
        send_active(SW,SH,5);
        repeat(3000)@(posedge clk);
        if(seq!=2) begin
            $display("DEBUG recover valid=%b seq=%0d cap_active=%b sampled=%0d/%0d frame_bad=%b cap_slot=%b write_state=%0d beat_count=%0d pack_count=%0d bad_sync=%b/%b src_bad=%b timing_bad=%b src_y=%0d measured_width=%0d error=%b overflow=%b",valid,seq,dut.cap_active,dut.sampled_pixels,dut.FRAME_PIXELS,dut.frame_bad,dut.cap_slot,dut.wstate,dut.beat_count,dut.pack_count,dut.bad_sync2,dut.bad_seen,dut.src_bad,dut.timing_bad,dut.src_y,dut.measured_width,error,overflow);
            $fatal(1,"1080p capture did not recover after 720p, seq=%0d",seq);
        end
        check_published_frame(4,slot);
        $display("PASS fixed 1080p: complete DDR frame verified, 720p rejected, 1080p recovered");
        $finish;
    end
    initial begin #5_000_000;$fatal(1,"fixed geometry capture timeout");end
endmodule
