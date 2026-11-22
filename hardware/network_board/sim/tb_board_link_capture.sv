`timescale 1ns/1ps
module tb_board_link_capture;
 import demo_bus_pkg::*;
 reg pclk=0,clk=0,rst=1,vs=0,hs=0,de=0;
 always #3.333 pclk=~pclk;
 always #2.777 clk=~clk;
 reg [23:0] rgb=0;
 wire[9:0] b,g,r;wire ctrl,island,rxvs,rxhs,db;wire[7:0] rb,rg,rr;
 tmds_encode eb(pclk,rst,rgb[7:0],hs,vs,de,b);
 tmds_encode eg(pclk,rst,rgb[15:8],1'b0,1'b0,de,g);
 tmds_encode er(pclk,rst,rgb[23:16],1'b0,1'b0,de,r);
 package_ctrl_v1 pkg(.clk(pclk),.i_gdata(g),.i_rdata(r),.i_bdata(b),.ctrl_time(ctrl),.data_island(island),.aux_ch0_o(),.aux_ch1_o(),.aux_ch2_o(),.hs(rxhs),.vs(rxvs));
 decoder_v1 dc0(.pixelclk(pclk),.i_data(b),.pmerdy_int(1'b1),.ctrl_time(ctrl),.pc0(),.pc1(),.pvde(db),.pdatain(rb));
 decoder_v1 dc1(.pixelclk(pclk),.i_data(g),.pmerdy_int(1'b1),.ctrl_time(ctrl),.pc0(),.pc1(),.pvde(),.pdatain(rg));
 decoder_v1 dc2(.pixelclk(pclk),.i_data(r),.pmerdy_int(1'b1),.ctrl_time(ctrl),.pc0(),.pc1(),.pvde(),.pdatain(rr));
 // Same final output register as the real board-B dvi_decoder.
 reg outvs=0,outde=0;reg[23:0] outrgb=0;
 always @(posedge pclk)begin outvs<=rxvs;outde<=db;outrgb<={rr,rg,rb};end
 axi_req_t req;axi_rsp_t rsp;
 wire valid,slot,overflow,error,lost;wire[30:0] seq;
 gesture_frame_capture dut(.proc_clk(clk),.pclk(pclk),.reset(rst),.hdmi_vs(outvs),.hdmi_de(outde),.hdmi_r(outrgb[23:16]),.hdmi_g(outrgb[15:8]),.hdmi_b(outrgb[7:0]),.frame0_base(32'h03000000),.frame1_base(32'h03100000),.net_lock(1'b0),.net_lock_slot(1'b0),.roi_lock(1'b0),.roi_lock_slot(1'b0),.clear_errors(1'b0),.frame_valid(valid),.published_slot(slot),.published_seq(seq),.overflow_sticky(overflow),.error_sticky(error),.video_lost(lost),.input_is_720p(),.input_mode_valid(),.axi_req(req),.axi_rsp(rsp));
 reg active=0,bvalid=0;integer beats_left=0,writes=0;
 always_comb begin rsp='0;rsp.awready=!active&&!bvalid;rsp.wready=active;rsp.bvalid=bvalid;end
 always @(posedge clk)begin
  if(rst)begin active<=0;bvalid<=0;beats_left<=0;writes<=0;end
  else begin
   if(req.awvalid&&rsp.awready)begin active<=1;beats_left<=req.awlen+1;end
   if(req.wvalid&&rsp.wready)begin
    if(req.wlast!=(beats_left==1))$fatal(1,"WLAST mismatch");
    writes<=writes+1;beats_left<=beats_left-1;
    if(beats_left==1)begin active<=0;bvalid<=1;end
   end
   if(bvalid&&req.bready)bvalid<=0;
  end
 end
 integer frame_index=0;
 initial begin
  repeat(200)@(negedge pclk);rst=0;
  repeat(200)@(negedge pclk);
  for(frame_index=0;frame_index<2;frame_index=frame_index+1)begin
   for(integer y=0;y<1125;y=y+1)begin
    for(integer x=0;x<2200;x=x+1)begin
     @(negedge pclk);hs=(x<44);vs=(y<5);de=(x>=192&&x<2112&&y>=41&&y<1121);
     rgb={8'(x),8'(y),8'(x^y)};
    end
    if(y%250==0)$display("FRAME_PROGRESS frame=%0d line=%0d t=%0t",frame_index,y,$time);
    if(frame_index==1&&y==42)begin
     repeat(1000)@(negedge pclk);
     $display("CAPTURE valid=%b seq=%0d overflow=%b error=%b writes=%0d sampled=%0d",valid,seq,overflow,error,writes,dut.sampled_pixels);
     if(!valid||seq<1||overflow||error)$fatal(1,"full frame capture failed");
     $display("PASS actual board-A DVI -> board-B parser -> 1080p capture publishes an intact frame");$finish;
    end
   end
  end
 end
endmodule

