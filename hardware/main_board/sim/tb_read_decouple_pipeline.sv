// Full production NPU/IPX scheduling and DMA benchmark. Numerical timing
// stubs are optional and must first match the real datapath's small-frame trace.
`timescale 1ns/1ps
module tb_read_decouple_pipeline #(parameter W=8,H=8,VARIANT=2,DISPLAY=0,CAMERA=0,PHASE=0,START_CYCLE=0,MAX_CYCLES=30000000,QUEUE_DEPTH=256,RESERVE=1,QUANTUM=64,PIPE_READS=2,BANK_LSB=24,BANK_XOR_LSB=-1,FAIR=0,DISPLAY_BURST=64,USE_BUFFER=(VARIANT==2));
 import demo_bus_pkg::*;
 integer run_w=W,run_h=H,run_display=DISPLAY,run_camera=CAMERA,run_phase=PHASE,run_start=START_CYCLE;
 integer run_mode=3,run_camera_fps=30;
 wire [31:0] visible_w=run_w==856?854:run_w;
 wire [31:0] camera_frame_cycles=180000000/run_camera_fps;
 wire [31:0] camera_frame_bursts=(((run_w*2+15)/16)*16*run_h+255)/256;
 wire [31:0] x_step=((visible_w-1)*65536+1918)/1919;
 wire enable_a=run_mode!=1,enable_b=run_mode!=0;
 wire [11:0] display_width_a=run_mode==2?12'((959*x_step)/65536+1):12'(visible_w);
 wire [7:0] display_first_b=run_mode==2?8'(((960*x_step)/65536)/8):8'd0;
 wire [15:0] display_stride=16'(((run_w*2+15)/16)*16);
 wire [11:0] display_width_b=12'(visible_w);
 wire [31:0] line_period=2640;
 wire [31:0] output_lines=run_mode==3?32'd540:32'd1080;
 wire [31:0] start_line=run_mode==3?32'd315:32'd45;
 wire [31:0] map_step=32'(((run_h-1)*65536+output_lines-2)/(output_lines-1));
 wire [31:0] b_offset=run_mode==1?0:1152;
 initial begin
  if($value$plusargs("W=%d",run_w))begin end
  if($value$plusargs("H=%d",run_h))begin end
  if($value$plusargs("DISPLAY=%d",run_display))begin end
  if($value$plusargs("CAMERA=%d",run_camera))begin end
  if($value$plusargs("PHASE=%d",run_phase))begin end
  if($value$plusargs("START_CYCLE=%d",run_start))begin end
  if($value$plusargs("MODE=%d",run_mode))begin end
  if($value$plusargs("CAMERA_FPS=%d",run_camera_fps))begin end
 end

 logic clk=0,reset=1;always #2.777777778 clk=~clk;
 logic csr_valid=0,csr_write=0;logic [11:0] csr_address=0;logic [31:0] csr_wdata=0;
 logic [3:0] csr_wstrb=15;logic [1:0] csr_target=0;
 wire csr_ready,csr_error,control_idle,n_irq,p_irq;wire [31:0] csr_rdata;
 axi_req_t n_raw,n_req,p_req,req[4],mem_req,camera_req;
 axi_rsp_t n_rsp,p_rsp,rsp[4],mem_rsp;
 wire display_urgent;integer cycle=0,frame_start=0,frame_cycles=0,rows=0,misses=0;
 integer a_ready[1080],b_ready[1080];
 integer min_margin_a=2147483647,min_margin_b=2147483647;
 wire [3:0] darid;wire[31:0] daraddr;wire[7:0] darlen;wire[2:0] darsize;wire[1:0] darburst;
 wire darvalid,drready;logic at=0,bt=0;logic[11:0] cmd_ay=0,cmd_by=0,wanted_ay=0,wanted_by=0;logic pending_a=0,pending_b=0;wire aa,ba,ad,bd;
 wire row_start,row_done,row_source,reader_error_a,reader_error_b;wire[11:0] row_y;logic[11:0] active_y=0;logic active_source=0;
 wire capture_urgent;integer cam_base_cycle=0,cam_bytes=0,cam_generated=0;
 style_pipeline_top pipe(.reset(reset),.csr_write(csr_write),.csr_error(csr_error),
  .csr_valid(csr_valid),
  .csr_address(csr_address),
  .csr_wdata(csr_wdata),
  .csr_wstrb(csr_wstrb),
  .csr_ready(csr_ready),
  .csr_rdata(csr_rdata),
  .csr_target(csr_target),
  .clk(clk),
  .control_idle(control_idle),
  .n_irq(n_irq),
  .n_m_axi_arid(n_raw.arid),
  .n_m_axi_araddr(n_raw.araddr),
  .n_m_axi_arlen(n_raw.arlen),
  .n_m_axi_arsize(n_raw.arsize),
  .n_m_axi_arburst(n_raw.arburst),
  .n_m_axi_arvalid(n_raw.arvalid),
  .n_m_axi_arready(n_rsp.arready),
  .n_m_axi_rid(n_rsp.rid),
  .n_m_axi_rdata(n_rsp.rdata),
  .n_m_axi_rresp(n_rsp.rresp),
  .n_m_axi_rlast(n_rsp.rlast),
  .n_m_axi_rvalid(n_rsp.rvalid),
  .n_m_axi_rready(n_raw.rready),
  .n_m_axi_awid(n_raw.awid),
  .n_m_axi_awaddr(n_raw.awaddr),
  .n_m_axi_awlen(n_raw.awlen),
  .n_m_axi_awsize(n_raw.awsize),
  .n_m_axi_awburst(n_raw.awburst),
  .n_m_axi_awvalid(n_raw.awvalid),
  .n_m_axi_awready(n_rsp.awready),
  .n_m_axi_wdata(n_raw.wdata),
  .n_m_axi_wstrb(n_raw.wstrb),
  .n_m_axi_wlast(n_raw.wlast),
  .n_m_axi_wvalid(n_raw.wvalid),
  .n_m_axi_wready(n_rsp.wready),
  .n_m_axi_bid(n_rsp.bid),
  .n_m_axi_bresp(n_rsp.bresp),
  .n_m_axi_bvalid(n_rsp.bvalid),
  .n_m_axi_bready(n_raw.bready),
  .p_irq(p_irq),
  .p_m_axi_arid(p_req.arid),
  .p_m_axi_awid(p_req.awid),
  .p_m_axi_araddr(p_req.araddr),
  .p_m_axi_awaddr(p_req.awaddr),
  .p_m_axi_arlen(p_req.arlen),
  .p_m_axi_awlen(p_req.awlen),
  .p_m_axi_arsize(p_req.arsize),
  .p_m_axi_awsize(p_req.awsize),
  .p_m_axi_arburst(p_req.arburst),
  .p_m_axi_awburst(p_req.awburst),
  .p_m_axi_arvalid(p_req.arvalid),
  .p_m_axi_awvalid(p_req.awvalid),
  .p_m_axi_rready(p_req.rready),
  .p_m_axi_wlast(p_req.wlast),
  .p_m_axi_wvalid(p_req.wvalid),
  .p_m_axi_bready(p_req.bready),
  .p_m_axi_arready(p_rsp.arready),
  .p_m_axi_awready(p_rsp.awready),
  .p_m_axi_rlast(p_rsp.rlast),
  .p_m_axi_rvalid(p_rsp.rvalid),
  .p_m_axi_wready(p_rsp.wready),
  .p_m_axi_bvalid(p_rsp.bvalid),
  .p_m_axi_rid(p_rsp.rid),
  .p_m_axi_bid(p_rsp.bid),
  .p_m_axi_rdata(p_rsp.rdata),
  .p_m_axi_rresp(p_rsp.rresp),
  .p_m_axi_bresp(p_rsp.bresp),
  .p_m_axi_wdata(p_req.wdata),
  .p_m_axi_wstrb(p_req.wstrb)
 );
 if(USE_BUFFER)begin:g_buffer
  demo_npu_read_buffer fifo(.clk,.reset,.up_req(n_raw),.up_rsp(n_rsp),.down_req(n_req),.down_rsp(rsp[1]));
 end else begin assign n_req=n_raw;assign n_rsp=rsp[1];end
 assign p_rsp=rsp[2];
 always_comb begin
  req[0]=camera_req;req[0].arid=darid;req[0].araddr=daraddr;req[0].arlen=darlen;
  req[0].arsize=darsize;req[0].arburst=darburst;req[0].arvalid=darvalid;req[0].rready=drready;
  req[1]=n_req;req[2]=p_req;req[3]='0;
 end
 demo_axi_merge #(.RESERVE_DISPLAY_ROW(VARIANT!=0 && RESERVE!=0),.PIPELINE_DISPLAY(VARIANT==2 && PIPE_READS==2),.URGENT_EMPTY_ONLY(FAIR)) merge(
  .clk,.reset,.ddr_ready(!reset),.display_urgent(VARIANT==0 || RESERVE==0?darvalid:display_urgent),.capture_urgent,
  .req,.rsp,.mem_req,.mem_rsp,.idle());
 display_controller_timing_model #(.PERF_PAYLOAD(1),.COMMAND_DEPTH(QUEUE_DEPTH),.CMD_QUANTUM(QUANTUM),.BANK_LSB(BANK_LSB),.BANK_XOR_LSB(BANK_XOR_LSB)) ddr(.clk,.rst_n(!reset),.generation(16'd0),.service_pause(1'b0),.req(mem_req),.rsp(mem_rsp));
`ifdef EXACT_FAST_READER
 reference_display_axi_shared_reader
`else
 display_axi_shared_reader
`endif
 #(.MAX_OUTSTANDING(VARIANT==2?PIPE_READS:1),.MAX_BURST_BEATS(DISPLAY_BURST)) reader(
  .axi_clk(clk),.axi_rst_n(!reset),.a_toggle(at),.b_toggle(bt),.a_base(32'd0),.b_base(32'h01800000),
  .a_stride(display_stride),.b_stride(display_stride),.a_width(display_width_a),.b_width(display_width_b),.a_y(cmd_ay),.b_y(cmd_by),
  .a_bank(1'b0),.b_bank(1'b0),.a_first(1'b0),.b_first(1'b0),.a_first_beat(8'd0),.b_first_beat(display_first_b),
  .a_ack(aa),.b_ack(ba),.a_done(ad),.b_done(bd),.error_a(reader_error_a),.error_b(reader_error_b),.idle(),.row_busy(),.read_reserve(display_urgent),
  .row_start,.row_done,.row_source,.row_bank(),.row_first(),.row_y,.write_valid(),.write_source(),.write_bank(),.write_index(),.write_width(),
  .m_axi_arid(darid),.m_axi_araddr(daraddr),.m_axi_arlen(darlen),.m_axi_arsize(darsize),.m_axi_arburst(darburst),.m_axi_arvalid(darvalid),.m_axi_arready(rsp[0].arready),
  .m_axi_rid(rsp[0].rid),.m_axi_rresp(rsp[0].rresp),.m_axi_rlast(rsp[0].rlast),.m_axi_rvalid(rsp[0].rvalid),.m_axi_rready(drready));
 always @(posedge clk)begin
  cycle<=cycle+1;
  if(reader_error_a || reader_error_b)$fatal(1,"display AXI response error");
  if(row_start)begin active_y<=row_y;active_source<=row_source;end
  if(row_done)begin if(active_source)b_ready[active_y]<=cycle;else a_ready[active_y]<=cycle;end
  if(pipe.u_n.frame_ctx.dispatch.row_cmd_take)rows++;
  if(cycle%1000000==0)$display("PIPE_PROGRESS cycle=%0d rows=%0d n_state=%0d",cycle,rows,pipe.u_n.u_task_control.u_frame_sequencer.state_q);
  if(pipe.u_n.status.task_error)$fatal(1,"NPU error %0d",pipe.u_n.status.error_code);
  if(cycle==100 && $isunknown(pipe.u_n.u_task_control.u_frame_sequencer.state_q))$fatal(1,"testbench reset did not initialize NPU");
  if(cycle>MAX_CYCLES)$fatal(1,"pipeline timeout");
 end
 task automatic wr(input integer target,address,input logic[31:0] data);
  @(negedge clk);csr_valid=1;csr_write=1;csr_target=target;csr_address=address;csr_wdata=data;
  do @(posedge clk);while(!csr_ready);
  if(csr_error)$fatal(1,"CSR write rejected target=%0d address=%h data=%h",target,address,data);
  @(negedge clk);csr_valid=0;
 endtask
 task automatic rd(input integer target,address,output logic[31:0] data);
  @(negedge clk);csr_valid=1;csr_write=0;csr_target=target;csr_address=address;
  do @(posedge clk);while(!csr_ready);
  if(csr_error)$fatal(1,"CSR read rejected");data=csr_rdata;
  @(negedge clk);csr_valid=0;
 endtask
 task automatic post(input integer x);
  integer width,lo,hi; width=(run_w-x)>480?480:(run_w-x);lo=x==0?0:8;hi=x+width<run_w?8:0;
  wr(1,'h14,'h01400000+2*x);wr(1,'h68,2*(x-lo));wr(1,'h4c,(hi<<8)|lo);
  wr(1,'h20,(run_h<<16)|(width+lo+hi));wr(1,'h24,(run_h<<16)|width);wr(1,'h08,9);
 endtask
 integer stride;logic[31:0] status;
 initial begin
  camera_req='0;for(integer i=0;i<1080;i++)begin a_ready[i]=-1;b_ready[i]=-1;end
  stride=((run_w*2+15)/16)*16;
  repeat(20)@(negedge clk);reset=0;repeat(30)@(negedge clk);
  wr(2,8,'h00c00000);wr(2,12,'h00c00000+stride*run_h);
  wr(1,'h50,1);for(integer i=0;i<768;i++)wr(1,'h58,(i%256)>>2);wr(1,'h50,2);
  wr(1,'h28,0);wr(1,'h2c,(256<<16)|256);wr(1,'h38,256);wr(1,'h70,256);wr(1,'h74,1);
  wr(0,'h0c,15);wr(0,'h2c,'h01c00000);wr(0,0,2);
  wait(pipe.u_n.status.model_loaded);wr(0,8,15);
  wr(0,'h10,((run_h/4)<<16)|(run_w/4));wr(0,'h14,0);wr(0,'h18,'h00c00000);wr(0,'h1c,'h01000000);
  wr(0,'h20,stride);wr(0,'h24,stride);wr(0,'h28,run_w*8);
  wr(1,'h1c,stride);wr(1,'h6c,stride);wr(1,'h08,12);
  if(run_start!=0)wait(cycle>=run_start);
  post(0);frame_start=cycle;wr(0,0,1);
  for(integer x=0;x<run_w;x+=480)begin
   wait(p_irq);rd(1,'h0c,status);if((status&'hf0)||!(status&2))$fatal(1,"IPX completion error %h",status);
   if(x+480<run_w)post(x+480);
  end
  wait(pipe.u_n.status.frame_done || !pipe.n_busy);
  wait(control_idle);frame_cycles=cycle-frame_start;
  $display("PIPE_FRAME variant=%0d W=%0d H=%0d mode=%0d cycles=%0d fps=%0f rows=%0d display_misses=%0d",VARIANT,run_w,run_h,run_mode,frame_cycles,180000000.0/frame_cycles,rows,misses);
  $display("PIPE_DISPLAY_MARGIN A_min=%0d B_min=%0d proc_cycles",min_margin_a,min_margin_b);
  $finish;
 end
 // Held descriptors remain stable until DONE, with one overwriteable pending row,
 // matching the production display producer's command/pending organization.
 always @(negedge clk)if(!reset && run_display)begin
  if(pending_a && at==aa && at==ad)begin cmd_ay=wanted_ay;at=~at;pending_a=0;end
  if(pending_b && bt==ba && bt==bd)begin cmd_by=wanted_by;bt=~bt;pending_b=0;end
 end
 // Display timing only, same shared reader. First row is prefetched in blanking.
 // Full pixel/color correctness is checked separately by the display viewport TB.
 initial begin
  wait(!reset);if(run_display)begin
   for(integer frame=0;;frame++)begin
    wait(cycle>=run_phase+frame*2970000+1000);
    for(integer i=0;i<1080;i++)begin a_ready[i]=-1;b_ready[i]=-1;end
    wanted_ay=0;wanted_by=0;pending_a=enable_a;pending_b=enable_b;
    for(integer line=0;line<output_lines;line++)begin
     wait(cycle>=run_phase+frame*2970000+(start_line+line)*line_period);
     if(enable_a && a_ready[(line*map_step)/65536]>=0 && cycle-6-a_ready[(line*map_step)/65536]<min_margin_a)min_margin_a=cycle-6-a_ready[(line*map_step)/65536];
     if(enable_a && (a_ready[(line*map_step)/65536]<0 || a_ready[(line*map_step)/65536]>cycle-6))begin
      misses++;if(VARIANT==2)$fatal(1,"candidate A deadline frame=%0d line=%0d cycle=%0d ready=%0d B_ready=%0d",frame,line,cycle,a_ready[(line*map_step)/65536],b_ready[(line*map_step)/65536]);
     end
     if(line<output_lines-1)begin
      wanted_ay=((line+1)*map_step)/65536;wanted_by=wanted_ay;
      pending_a=enable_a && a_ready[wanted_ay]<0;pending_b=enable_b && b_ready[wanted_by]<0;
     end
    end
   end
  end
 end
 initial begin
  wait(!reset);if(run_display && enable_b)for(integer frame=0;;frame++)for(integer line=0;line<output_lines;line++)begin
   wait(cycle>=run_phase+frame*2970000+(start_line+line)*line_period+b_offset);
   if(b_ready[(line*map_step)/65536]>=0 && cycle-6-b_ready[(line*map_step)/65536]<min_margin_b)min_margin_b=cycle-6-b_ready[(line*map_step)/65536];
   if(b_ready[(line*map_step)/65536]<0 || b_ready[(line*map_step)/65536]>cycle-6)begin
    misses++;if(VARIANT==2)$fatal(1,"candidate B deadline frame=%0d line=%0d cycle=%0d ready=%0d A_ready=%0d",frame,line,cycle,b_ready[(line*map_step)/65536],a_ready[(line*map_step)/65536]);
   end
  end
 end

 integer camera_wbeats=0,camera_target=0,camera_elapsed=0,camera_backlog=0,max_camera_backlog=0;
 assign capture_urgent=run_camera && camera_backlog>=2048;
 always @(posedge clk)if(!reset && run_camera)begin
  if(camera_req.wvalid && rsp[0].wready)camera_wbeats++;
  camera_elapsed=cycle-cam_base_cycle;
  cam_generated=(camera_elapsed/camera_frame_cycles)*camera_frame_bursts+((camera_elapsed%camera_frame_cycles)/153>camera_frame_bursts?camera_frame_bursts:(camera_elapsed%camera_frame_cycles)/153);
  camera_backlog=cam_generated*256-camera_wbeats*16;
  if(camera_backlog>max_camera_backlog)max_camera_backlog=camera_backlog;
  if(camera_backlog>4096)$fatal(1,"camera FIFO overflow %0d",camera_backlog);
 end
 initial begin
  wait(!reset);cam_base_cycle=cycle;
  if(run_camera)for(integer cf=0;;cf++)for(integer burst=0;burst<camera_frame_bursts;burst++)begin
   camera_target=cam_base_cycle+cf*camera_frame_cycles+(burst+1)*153;
   wait(cycle>=camera_target);@(negedge clk);
   camera_req.awid=2;camera_req.awaddr=32'h00800000+burst*256;
   camera_req.awlen=15;camera_req.awsize=4;camera_req.awburst=1;camera_req.awvalid=1;
   do @(posedge clk);while(!rsp[0].awready);
   @(negedge clk);camera_req.awvalid=0;camera_req.wvalid=1;
   for(integer beat=0;beat<16;beat++)begin
    camera_req.wdata=128'(burst*16+beat);camera_req.wstrb='1;camera_req.wlast=beat==15;
    do @(posedge clk);while(!rsp[0].wready);
    @(negedge clk);
   end
   camera_req.wvalid=0;camera_req.bready=1;
   do @(posedge clk);while(!rsp[0].bvalid);
   @(negedge clk);camera_req.bready=0;
  end
 end
 integer trace_fd=0;string trace_path;
 integer debug_rows=0;
 integer dbg_nr=0,dbg_nw=0;
 always @(posedge clk)begin
  if(ddr.axi_user_en && ddr.axi_user_ready)begin
   if(ddr.axi_user_cmd==1)dbg_nr++;else dbg_nw++;
  end
 end
 initial if($value$plusargs("DEBUG_ROWS=%d",debug_rows))begin end
`ifndef EXACT_FAST_READER
 always @(posedge clk)if(debug_rows && cycle>=830000 && cycle<836000)begin
  if(row_start || row_done)$display("DBG_ROW %0d start=%b done=%b src=%b y=%0d pending=%b%b reserve=%b",cycle,row_start,row_done,row_source,row_y,reader.pending_a,reader.pending_b,display_urgent);
  if(mem_req.arvalid && mem_rsp.arready)$display("DBG_AR %0d owner=%0d addr=%h len=%0d",cycle,merge.rc,mem_req.araddr,mem_req.arlen+1);
  if(mem_rsp.rvalid && mem_req.rready && mem_rsp.rlast)$display("DBG_LAST %0d owner=%0d",cycle,merge.read_owner[merge.read_head]);
  if(cycle%200==0)$display("DBG_STATE %0d src=%b y=%0d issue=%0d left=%0d offered=%0d rc=%0d urgent=%b p=%b%b at=%b%b%b bt=%b%b%b",cycle,reader.owner_b,reader.active_y,reader.issue_left,reader.beats_left,reader.offered,merge.read_count,display_urgent,reader.pending_a,reader.pending_b,at,aa,ad,bt,ba,bd);
  if(cycle%100==0)$display("DBG_NATIVE %0d R=%0d W=%0d en=%b cmd=%0d addr=%h ready=%b active=%b%b prefer=%b reserved=%0d",cycle,dbg_nr,dbg_nw,ddr.axi_user_en,ddr.axi_user_cmd,ddr.axi_user_addr,ddr.axi_user_ready,ddr.u_axi.read_active,ddr.u_axi.write_active,ddr.u_axi.prefer_write,ddr.u_axi.reserved);
 end
`endif
 initial if($value$plusargs("TRACE=%s",trace_path))trace_fd=$fopen(trace_path,"w");
 always @(posedge clk)if(trace_fd!=0 && !reset)begin
  if(pipe.u_n.frame_ctx.dispatch.row_cmd_take)$fwrite(trace_fd,"%0d ROW %0d %0d %0d %0d\n",cycle,pipe.u_n.frame_ctx.row.layer,pipe.u_n.frame_ctx.row.id,pipe.u_n.frame_ctx.row.x,pipe.u_n.frame_ctx.row.count);
  for(integer i=0;i<3;i++)begin
   if(req[i].arvalid&&rsp[i].arready)$fwrite(trace_fd,"%0d AR %0d %h %0d\n",cycle,i,req[i].araddr,req[i].arlen+1);
   if(req[i].awvalid&&rsp[i].awready)$fwrite(trace_fd,"%0d AW %0d %h %0d\n",cycle,i,req[i].awaddr,req[i].awlen+1);
   if(rsp[i].rvalid&&req[i].rready)$fwrite(trace_fd,"%0d R %0d %0d\n",cycle,i,rsp[i].rlast);
   if(rsp[i].bvalid&&req[i].bready)$fwrite(trace_fd,"%0d B %0d\n",cycle,i);
  end
 end
 final $display("PIPE_CAMERA max_backlog=%0d bytes",max_camera_backlog);

endmodule


