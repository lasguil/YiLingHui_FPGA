`timescale 1ns/1ps
module tb_tx_pipeline;
 parameter W=320,H=180,FPS=60,FRAMES=100,ICMP_ENABLE=1;
 reg clk=0;always #20 clk=~clk;
 reg rst_n=0;
 wire [7:0] vd,ad,md,ed; wire vw,vr,vb,aw,ar,rr,cr,me,mv,ee,pb,fd,ov,ready,upe;
 wire [15:0] vl,vp,al,ap;
 wire [31:0] frames,packets,drops;
 wire pop,begin_frame,end_frame;
 reg cap_busy=0;
 integer pixel_index=0,source_fid=-1;
 reg [31:0] random_state=32'h12345678;
 wire pixel_valid=cap_busy && random_state[3:0]!=0;
 wire [15:0] pixel=16'(16'ha500+source_fid*113+pixel_index);
 reg udp_seen=0;
 wire done=me&&udp_seen;
 always @(posedge clk) begin
  if(!rst_n)begin udp_seen<=0;random_state<=32'h12345678;end
  else begin
   random_state<={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
   if(done)udp_seen<=0;else if(upe)udp_seen<=1;
  end
 end
 always @(posedge clk) if(rst_n)begin
  if(begin_frame)begin cap_busy<=1;pixel_index<=0;source_fid<=source_fid+1;end
  if(pop)pixel_index<=pixel_index+1;
  if(end_frame)begin cap_busy<=0;if(pixel_index!=W*H)$fatal(1,"source pixel count");end
 end
 vid_packet #(.W(W),.H(H),.FPS(FPS)) v(
  .clk,.rst_n,.tx_data(vd),.tx_wr(vw),.tx_len(vl),.tx_req(vr),.tx_port(vp),.tx_busy(vb),
  .tx_ram_req(cr),.mac_send_end(done),.cfg_stream_en(1'b1),.cfg_test_src(2'd0),
  .frame_cnt(frames),.pkt_cnt(packets),.drop_cnt(drops),
  .cap_valid(1'b1),.cap_present(1'b1),.cap_data(pixel),.cap_data_valid(pixel_valid),.cap_error(1'b0),.cap_busy,
  .cap_pop(pop),.cap_rd_begin(begin_frame),.cap_rd_end(end_frame));
 reg [2:0] cs=0;reg [7:0] cd=0;reg cw=0,cq=0;wire cb,crr;
 assign cb=(cs!=0);
 integer ci=0,control_timer=0,control_done=0;
 always @(posedge clk)if(rst_n)begin
  cw<=0;control_timer<=control_timer+1;
  case(cs)
   0:if(control_timer>=12500)begin cq<=1;cs<=1;control_timer<=0;end
   1:if(crr)begin cq<=0;ci<=0;cs<=2;end
   2:begin cw<=1;cd<=8'(ci);if(ci==11)cs<=3;else ci<=ci+1;end
   3:if(done)begin cs<=0;control_done<=control_done+1;end
  endcase
 end
 wire [15:0] a_source_port;
 udp_tx_arb a(.clk,.rst_n,
  .c0_data(cd),.c0_wr(cw),.c0_len(16'd12),.c0_req(cq),.c0_busy(cb),.c0_port(16'd5000),.c0_source_port(16'd5000),.c0_ram_req(crr),
  .c1_data(vd),.c1_wr(vw),.c1_len(vl),.c1_req(vr),.c1_busy(vb),.c1_port(vp),.c1_source_port(16'd8080),.c1_ram_req(cr),
  .tx_data(ad),.tx_wr(aw),.tx_len(al),.tx_req(ar),.dest_port(ap),.source_port(a_source_port),.tx_ram_req(rr),.mac_send_end(done),.tx_accept_ready(ready));
 wire icmp_data_req;
 reg icmp_req=0,icmp_ready=0,icmp_end=0;
 reg [7:0] icmp_data=0;
 integer icmp_state=0,icmp_index=0,icmp_requests=0,icmp_completed=0;
 function automatic [7:0] icmp_byte(input integer i);
  case(i)
   0:icmp_byte=0;1:icmp_byte=0;2:icmp_byte=8'hf6;3:icmp_byte=8'hb7;
   4:icmp_byte=8'h12;5:icmp_byte=8'h34;6:icmp_byte=0;7:icmp_byte=1;
   default:icmp_byte=8'(i-8);
  endcase
 endfunction
 always @(posedge clk)if(rst_n)begin
  icmp_req<=0;icmp_end<=0;
  case(icmp_state)
   0:if(ICMP_ENABLE && random_state[13:0]==14'h2345)begin
    icmp_req<=1;icmp_ready<=1;icmp_state<=1;icmp_requests<=icmp_requests+1;
   end
   1:if(icmp_data_req)begin icmp_ready<=0;icmp_index<=0;icmp_state<=2;end
   2:begin
    icmp_data<=icmp_byte(icmp_index);
    if(icmp_index==63)begin icmp_state<=0;icmp_end<=1;icmp_completed<=icmp_completed+1;end
    else icmp_index<=icmp_index+1;
   end
  endcase
 end
 // Unsolicited ARP races with both clients and cannot acknowledge a UDP.
 reg arp_req=0;
 always @(posedge clk)if(rst_n)arp_req<=random_state[15:0]==16'h5678;
 mac_tx_top m(.clk,.rst_n,.tx_accept_ready(ready),.udp_payload_end(upe),
  .destination_mac_addr(48'h123456789abc),.source_mac_addr(48'h000a3501fec0),
  .TTL(8'h80),.source_ip_addr(32'hc0a80002),.destination_ip_addr(32'hc0a80003),
  .udp_send_source_port(a_source_port),.udp_send_destination_port(ap),
  .arp_reply_req(1'b0),.arp_rec_source_ip_addr(32'd0),.arp_rec_source_mac_addr(48'd0),.arp_request_req(arp_req),
  .ram_wr_data(ad),.ram_wr_en(aw),.udp_tx_req(ar),.udp_ram_data_req(rr),.udp_send_data_length(al),
  .upper_data_req(icmp_data_req),.icmp_tx_ready(icmp_ready),.icmp_tx_data(icmp_data),.icmp_tx_end(icmp_end),.icmp_tx_req(icmp_req),.icmp_send_data_length(16'd84),
  .mac_data_valid(mv),.mac_send_end(me),.mac_tx_data(md));
 gmii_tx_buffer b(.clk,.rst_n,.eth_10_100m_en(1'b1),.link(1'b1),.accept_ready(ready),
  .gmii_tx_en(mv),.gmii_txd(md),.e10_100_tx_en(ee),.e10_100_txd(ed),.play_busy(pb),.frame_done(fd),.overflow(ov));
 integer cycles=0,last_sof=0,last_req=0,nreq=0,nline=0,nend=0;
 integer file,byte_count=0,nibbles=0,gap=1000,line_cycle=0,previous_end=0;
 integer max_service=0,service,first_source=0,last_source=0;
 reg old_req=0,old_line=0;reg [31:0] old_frames=0;
 reg [7:0] line_bytes[0:2047];
 string trace_path;
 initial begin
  if(!$value$plusargs("trace=%s",trace_path))trace_path="build/tx_pipeline_frames.hex";
  file=$fopen(trace_path,"w");if(!file)$fatal(1,"cannot open trace");
 end
 always @(negedge clk)if(rst_n)begin
  cycles=cycles+1;
  if(v.st==1&&v.hcnt==0&&v.pkt_idx==0)begin last_sof=cycles;end
  if(vr&&!old_req)begin
   if(nreq<5)$display("REQUEST cycle=%0d interval=%0d len=%0d",cycles,cycles-last_req,vl);
   last_req=cycles;nreq=nreq+1;
  end
  if(ee)begin
   if(!old_line)begin
    if(nline>0&&cycles-previous_end-1<24)$fatal(1,"IFG too short");
    line_cycle=cycles;byte_count=0;nibbles=0;nline=nline+1;
   end
   if(!nibbles[0])line_bytes[byte_count][3:0]=ed[3:0];
   else begin line_bytes[byte_count][7:4]=ed[3:0];byte_count=byte_count+1;end
   nibbles=nibbles+1;
  end else if(old_line)begin
   if(nibbles[0])$fatal(1,"odd nibble count");
   $fwrite(file,"%0d %0d ",line_cycle,byte_count);
   for(integer i=0;i<byte_count;i=i+1)$fwrite(file,"%02x",line_bytes[i]);
   $fwrite(file,"\n");nend=nend+1;previous_end=cycles-1;
  end
  if(ov||v.tx_failed||a.fail_to!=0)$fatal(1,"overflow=%0d fail=%0d cs=%0d grant=%b%b fifo=%0d mac=%0d udp=%0d ip=%0d seen=%0d upe=%0d",ov,a.fail_to,cs,a.grant0,a.grant1,b.cnt,m.mac0.send_state,m.udp0.state,m.ip0.state,udp_seen,upe);
  if(drops!=0)$fatal(1,"unexpected frame drop");
  if(frames!=old_frames)begin
   service=cycles-last_sof;if(service>max_service)max_service=service;
   if(frames==1)first_source=last_sof;last_source=last_sof;
   old_frames=frames;
   if(frames<=2)$display("FRAME frame=%0d service_us=%0.2f",frames,service*0.04);
  end
  // Finish only after the final video packet has actually left the replay FIFO.
  if(frames>=FRAMES&&!pb&&!ee)begin
   $display("PASS: TX frames=%0d packets=%0d physical=%0d controls=%0d max_service_us=%0.2f fps=%0.3f",frames,packets,nend,control_done,max_service*0.04,(FRAMES-1)*25000000.0/(last_source-first_source));
   $fclose(file);$finish;
  end
  old_req=vr;old_line=ee;
 end
 initial begin repeat(8)@(negedge clk);rst_n=1;end
 // Leave enough simulated time for a 100-frame low-rate profile plus drain.
 initial begin #2_000_000_000;$fatal(1,"TX timeout");end
endmodule
