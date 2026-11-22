`timescale 1ns/1ps
module tb_gesture_capture_phase;
    import demo_bus_pkg::*;
    localparam int SW=1920, SH=1080;
    logic pclk=0,proc_clk=0,reset=1,vs=0,de=0;
    logic [7:0] r=0,g=0,b=0;
    always #1 pclk=~pclk;
    always #5 proc_clk=~proc_clk;
    axi_rsp_t rsp0='0,rsp1='0;
    axi_req_t req0,req1;
    wire valid0,slot0,overflow0,error0,lost0,is720_0,mode_valid0;
    wire valid1,slot1,overflow1,error1,lost1,is720_1,mode_valid1;
    wire [30:0] seq0,seq1;
    gesture_frame_capture #(.SRC_W(SW),.SRC_H(SH),.DECIM(3),.FIFO_ADDR_W(20),
        .KEEP_TWO_OF_THREE(1'b0),.AUTO_INPUT_MODE(1'b0)) center(
        .proc_clk,.pclk,.reset,.hdmi_vs(vs),.hdmi_de(de),.hdmi_r(r),.hdmi_g(g),.hdmi_b(b),
        .frame0_base(32'h03400000),.frame1_base(32'h03800000),.net_lock(1'b0),.net_lock_slot(1'b0),
        .roi_lock(1'b0),.roi_lock_slot(1'b0),.clear_errors(1'b0),.frame_valid(valid0),
        .published_slot(slot0),.published_seq(seq0),.overflow_sticky(overflow0),.error_sticky(error0),
        .video_lost(lost0),.input_is_720p(is720_0),.input_mode_valid(mode_valid0),.axi_req(req0),.axi_rsp(rsp0));
    gesture_frame_capture #(.SRC_W(SW),.SRC_H(SH),.DECIM(3),.FIFO_ADDR_W(20),
        .KEEP_TWO_OF_THREE(1'b1),.AUTO_INPUT_MODE(1'b0)) keep_two(
        .proc_clk,.pclk,.reset,.hdmi_vs(vs),.hdmi_de(de),.hdmi_r(r),.hdmi_g(g),.hdmi_b(b),
        .frame0_base(32'h03400000),.frame1_base(32'h03800000),.net_lock(1'b0),.net_lock_slot(1'b0),
        .roi_lock(1'b0),.roi_lock_slot(1'b0),.clear_errors(1'b0),.frame_valid(valid1),
        .published_slot(slot1),.published_seq(seq1),.overflow_sticky(overflow1),.error_sticky(error1),
        .video_lost(lost1),.input_is_720p(is720_1),.input_mode_valid(mode_valid1),.axi_req(req1),.axi_rsp(rsp1));

    task automatic check_phase;
        #0.1;
        if(center.src_x_phase3 !== (center.src_x%3) || center.src_y_phase3 !== (center.src_y%3))
            $fatal(1,"center modulo phase diverged at x=%0d y=%0d phase=%0d,%0d",center.src_x,center.src_y,center.src_x_phase3,center.src_y_phase3);
        if(keep_two.src_x_phase3 !== (keep_two.src_x%3) || keep_two.src_y_phase3 !== (keep_two.src_y%3))
            $fatal(1,"keep-two modulo phase diverged at x=%0d y=%0d phase=%0d,%0d",keep_two.src_x,keep_two.src_y,keep_two.src_x_phase3,keep_two.src_y_phase3);
    endtask

    task automatic start_frame;
        @(negedge pclk); de=0;vs=1;
        repeat(2) begin @(posedge pclk);check_phase();end
        @(negedge pclk);vs=0;
    endtask

    task automatic drive_frame(input int width,input int height,input int fid,
                               input int expected_center,input int expected_keep,input bit begin_frame);
        int center_count,keep_count;
        logic center_ref,keep_ref,center_sof_ref,keep_sof_ref;
        center_count=0;keep_count=0;
        if(begin_frame) start_frame();
        for(int y=0;y<height;y++)begin
            for(int x=0;x<width;x++)begin
                @(negedge pclk);
                de=1; r=8'(x+fid);g=8'(y^fid);b=8'(x+y+fid);
                #0.1;
                center_ref=(x<SW && y<SH && x%3==1 && y%3==1);
                keep_ref=(x<SW && y<SH && x%3!=2 && y%3!=2);
                center_sof_ref=(x==1 && y==1);
                keep_sof_ref=(x==0 && y==0);
                if(center.pix_fifo_wr !== center_ref || keep_two.pix_fifo_wr !== keep_ref)
                    $fatal(1,"sample enable mismatch fid=%0d xy=%0d,%0d got=%b,%b ref=%b,%b",fid,x,y,center.pix_fifo_wr,keep_two.pix_fifo_wr,center_ref,keep_ref);
                if(center_ref)begin
                    center_count++;
                    if(center.pix_fifo_wdata !== {center_sof_ref,r,g,b})
                        $fatal(1,"center sampled pixel mismatch at fid=%0d xy=%0d,%0d",fid,x,y);
                end
                if(keep_ref)begin
                    keep_count++;
                    if(keep_two.pix_fifo_wdata !== {keep_sof_ref,r,g,b})
                        $fatal(1,"keep-two sampled pixel mismatch at fid=%0d xy=%0d,%0d",fid,x,y);
                end
                @(posedge pclk);check_phase();
            end
            @(negedge pclk);de=0;
            repeat(2)begin @(posedge pclk);check_phase();end
        end
        if(center_count!=expected_center || keep_count!=expected_keep)
            $fatal(1,"wrong sampled count %0dx%0d: center=%0d keep=%0d",width,height,center_count,keep_count);
        $display("PASS pixel reference %0dx%0d fid=%0d center=%0d keep-two=%0d",width,height,fid,center_count,keep_count);
    endtask

    initial begin
        repeat(6)@(negedge pclk);reset=0;
        repeat(3)begin @(posedge pclk);check_phase();end
        if(mode_valid0!==1'b1 || mode_valid1!==1'b1 || is720_0!==1'b0 || is720_1!==1'b0)
            $fatal(1,"fixed 1080p metadata incorrect");
        drive_frame(1920,1080,1,230400,921600,1'b1);
        drive_frame(1280,720,2,102480,409920,1'b1);
        // This boundary rejects the completed 720p frame and begins recovery.
        start_frame();
        if(center.bad_toggle!==1'b1)
            $fatal(1,"720p geometry was not rejected");
        drive_frame(1920,1080,3,230400,921600,1'b0);
        // This boundary confirms the recovered 1080p frame adds no geometry error.
        start_frame();
        if(center.bad_toggle!==1'b1)
            $fatal(1,"1080p did not recover after rejected 720p");
        $display("PASS fixed 1080p geometry; 720p rejected; 1080p recovered");
        drive_frame(1922,1081,4,230400,921600,1'b1);
        $display("PASS modulo-three phases freeze with saturated overlong coordinates");
        $finish;
    end
    initial begin #80_000_000;$fatal(1,"capture phase test timeout");end
endmodule
