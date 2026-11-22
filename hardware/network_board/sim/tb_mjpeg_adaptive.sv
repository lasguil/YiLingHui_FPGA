`timescale 1ns/1ps
module tb_mjpeg_adaptive #(parameter int SW=96, SH=48, parameter bit NPU_ONLY=0);
    import demo_bus_pkg::*;
    localparam int LW=SW*2/3,LH=SH*2/3;
    localparam int OW=NPU_ONLY?SW/3:LW,OH=NPU_ONLY?SH/3:LH,FB=OW*OH*3;
    localparam logic [31:0] BASE0=32'h03400000,BASE1=32'h03800000;
    logic clk=0,pclk=0,reset=1,vs=0,de=0;
    realtime pixel_half=3.367;
    logic pclk_run=1;
    always #2.778 clk=~clk;
    always #(pixel_half) if(pclk_run)pclk=~pclk;
    logic [7:0] r=0,g=0,b=0;
    logic [23:0] data;
    logic valid,last,sof,overflow,error,toggle,available,mode_low,mode_valid;
    logic request=0,ready=0;
    axi_req_t req;axi_rsp_t rsp;
    logic npu_slot;logic[30:0] npu_seq;
    if(!NPU_ONLY)begin:g_mjpeg
    mjpeg_ddr_source #(.SRC_W(SW),.SRC_H(SH),.AUTO_INPUT_MODE(1'b1)) dut(
        .pclk,.proc_clk(clk),.reset,.request,.hdmi_vs(vs),.hdmi_de(de),
        .hdmi_r(r),.hdmi_g(g),.hdmi_b(b),.tdata(data),.tvalid(valid),.tready(ready),
        .tlast(last),.tuser(sof),.overflow_sticky(overflow),.source_error_sticky(error),
        .frame_done_toggle(toggle),.frame_available(available),
        .input_is_720p(mode_low),.input_mode_valid(mode_valid),.axi_req(req),.axi_rsp(rsp));
    end else begin:g_npu
        gesture_frame_capture #(.SRC_W(SW),.SRC_H(SH),.AUTO_INPUT_MODE(1'b1)) dut(
            .pclk,.proc_clk(clk),.reset,.hdmi_vs(vs),.hdmi_de(de),.hdmi_r(r),.hdmi_g(g),.hdmi_b(b),
            .frame0_base(BASE0),.frame1_base(BASE1),.net_lock(1'b0),.net_lock_slot(1'b0),
            .roi_lock(1'b0),.roi_lock_slot(1'b0),.clear_errors(1'b0),.frame_valid(available),
            .published_slot(npu_slot),.published_seq(npu_seq),.overflow_sticky(overflow),
            .error_sticky(),.video_lost(),.input_is_720p(mode_low),.input_mode_valid(mode_valid),.axi_req(req),.axi_rsp(rsp));
        assign error=0;assign valid=0;assign data=0;assign last=0;assign sof=0;
    end

    byte mem[0:2*FB-1];
    function automatic int index_for(input logic[31:0] addr);
        if(addr>=BASE1)return FB+int'(addr-BASE1);
        return int'(addr-BASE0);
    endfunction
    logic wa=0,ra=0,bv=0;
    int wl=0,rl=0,cycle=0,delay_b=0;
    logic [31:0] waddr=0,raddr=0;
    always_comb begin
        rsp='0;rsp.awready=!wa&&!bv&&(cycle%7<5);rsp.wready=wa&&(cycle%11!=3);
        rsp.bvalid=bv&&delay_b==0;rsp.arready=!ra&&(cycle%9<6);
        rsp.rvalid=ra;rsp.rlast=rl==1;
        if(ra)for(int i=0;i<16;i++)rsp.rdata[8*i+:8]=mem[index_for(raddr)+i];
    end
    always @(posedge clk)if(!reset)begin
        cycle<=cycle+1;
        if(req.awvalid&&rsp.awready)begin wa<=1;wl<=int'(req.awlen)+1;waddr<=req.awaddr;end
        if(req.wvalid&&rsp.wready)begin
            if(req.wlast!=(wl==1))$fatal(1,"incorrect DDR WLAST");
            for(int i=0;i<16;i++)begin
                if(index_for(waddr)+i<0||index_for(waddr)+i>=2*FB)$fatal(1,"write outside frame");
                mem[index_for(waddr)+i]<=req.wdata[8*i+:8];
            end
            waddr<=waddr+16;wl<=wl-1;
            if(wl==1)begin wa<=0;bv<=1;delay_b<=5;end
        end
        if(delay_b>0)delay_b<=delay_b-1;
        if(rsp.bvalid&&req.bready)bv<=0;
        if(req.arvalid&&rsp.arready)begin ra<=1;rl<=int'(req.arlen)+1;raddr<=req.araddr;end
        if(rsp.rvalid&&req.rready)begin raddr<=raddr+16;rl<=rl-1;if(rl==1)ra<=0;end
    end
    task automatic send_frame(input int width,height,id,input bit low_clock);
        int blank_h,blank_v;
        pixel_half=low_clock?6.734:3.367;
        blank_h=low_clock?LW*370/1280:SW*280/1920;
        blank_v=low_clock?LH*30/720:SH*45/1080;
        if(blank_v<2)blank_v=2;
        @(negedge pclk);de=0;vs=1;repeat(8)@(negedge pclk);vs=0;
        repeat((blank_h+width)*2)@(negedge pclk);
        for(int y=0;y<height;y++)begin
            for(int x=0;x<width;x++)begin
                de=1;r=8'(id);g=8'(x);b=8'(y);@(negedge pclk);
            end
            de=0;repeat(blank_h)@(negedge pclk);
        end
        repeat(blank_v*(width+blank_h))@(negedge pclk);
    endtask
    int received=0,completed=0,high_frames=0,low_frames=0,chosen=0;
    bit source_done=0,request_pending=0,reading=0;
    logic stalled=0;logic[25:0] held;
    if(!NPU_ONLY)begin:g_check_mjpeg
    always @(posedge clk)if(!reset)begin
        request<=0;ready<=cycle%17<13;
        if(available&&!reading&&!request_pending)begin request<=1;request_pending<=1;end
        if(valid&&ready)begin
            automatic int x=received%OW,y=received/OW,sx,sy;
            if(received==0)begin chosen=int'(data[23:16]);reading<=1;request_pending<=0;end
            if(chosen>=128||chosen==0)$fatal(1,"unsupported/partial frame published: %0d",chosen);
            sx=(chosen>=64)?x:x/2*3+x%2;sy=(chosen>=64)?y:y/2*3+y%2;
            if(data!=={8'(chosen),8'(sx),8'(sy)})
                $fatal(1,"torn/wrong frame=%0d pixel=%0d got=%h expected=%h",chosen,received,data,{8'(chosen),8'(sx),8'(sy)});
            if(sof!=(received==0)||last!=(x==OW-1))$fatal(1,"bad SOF/EOL");
            received++;
            if(received==OW*OH)begin
                received=0;completed++;reading<=0;
                if(chosen>=64)low_frames++;else high_frames++;
            end
        end
        if(stalled&&{sof,last,data}!==held)$fatal(1,"unstable AXI video under backpressure");
        stalled<=valid&&!ready;held<={sof,last,data};
        if(error)$fatal(1,"DDR reader error");
    end
    end else begin:g_check_npu
        logic[30:0] seen=0;
        always @(posedge clk)if(!reset&&npu_seq!=seen)begin
            automatic int base=npu_slot?FB:0;
            automatic int id=int'(unsigned'(mem[base]));
            int sx,sy;
            seen<=npu_seq;
            if(id==0||id>=128)$fatal(1,"NPU published unsupported/partial frame %0d",id);
            for(int y=0;y<OH;y++)for(int x=0;x<OW;x++)begin
                sx=(id>=64)?x*2+1:x*3+1;sy=(id>=64)?y*2+1:y*3+1;
                if({mem[base+(y*OW+x)*3],mem[base+(y*OW+x)*3+1],mem[base+(y*OW+x)*3+2]}!=={8'(id),8'(sx),8'(sy)})
                    $fatal(1,"wrong NPU sample frame %0d x=%0d y=%0d",id,x,y);
            end
            if(id>=64)low_frames++;else high_frames++;
        end
    end
    initial begin
        repeat(20)@(negedge clk);reset=0;
        for(int i=1;i<=8;i++)send_frame(SW,SH,i,0);
        if(!mode_valid||mode_low)$fatal(1,"high input not detected");
        for(int i=64;i<72;i++)send_frame(LW,LH,i,1);
        if(!mode_valid||!mode_low)$fatal(1,"low input not detected");
        for(int i=16;i<24;i++)send_frame(SW,SH,i,0);
        for(int i=128;i<132;i++)send_frame(LW+16,LH+8,i,1);
        if(mode_valid)$fatal(1,"unsupported size accepted");
        // Incomplete line geometry and a recovered clock gap must not be published.
        send_frame(SW,SH/2,140,0);
        de=0;@(negedge pclk);pclk_run=0;#100000;pclk_run=1;
        for(int i=72;i<80;i++)send_frame(LW,LH,i,1);
        if(!mode_valid||!mode_low)$fatal(1,"input mode did not recover");
        if(high_frames<2||low_frames<2)$fatal(1,"insufficient high/low frames checked %0d/%0d",high_frames,low_frames);
        $display("PASS: adaptive high->low->high->unsupported->partial->low; %0d high and %0d low complete pixel-exact frames",high_frames,low_frames);
        $finish;
    end
    initial begin #1500000000;$fatal(1,"adaptive capture timeout");end
endmodule
