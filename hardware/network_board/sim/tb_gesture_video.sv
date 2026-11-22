`timescale 1ns/1ps
module tb_gesture_video;
    import demo_bus_pkg::*;
    localparam int SW=48, SH=48, DW=16, DH=16;
    logic proc_clk=0, pclk=0, reset=1;
    always #3.5 proc_clk=~proc_clk;
    always #5.5 pclk=~pclk;

    logic vs=0,de=0;
    logic [7:0] r=0,g=0,b=0;
    logic frame_valid,published_slot,ovf,caperr,video_lost;
    logic [30:0] published_seq;
    logic roi_lock,roi_lock_slot,busy,done_sticky,error_sticky;
    logic clear_capture_errors;
    logic [31:0] frame0_base,frame1_base;
    logic [30:0] selected_seq;
    axi_req_t cap_req,roi_req;
    axi_rsp_t cap_rsp,roi_rsp;
    csr_req_t csr_req;
    csr_rsp_t csr_rsp;

    gesture_frame_capture #(.SRC_W(SW),.SRC_H(SH),.DECIM(3),.FIFO_ADDR_W(5)) u_cap(
      .net_lock(1'b0),.net_lock_slot(1'b0),.proc_clk,.pclk,.reset,.hdmi_vs(vs),.hdmi_de(de),.hdmi_r(r),.hdmi_g(g),.hdmi_b(b),
      .frame0_base,.frame1_base,.roi_lock,.roi_lock_slot,.clear_errors(clear_capture_errors),
      .frame_valid,.published_slot,.published_seq,.overflow_sticky(ovf),.error_sticky(caperr),
      .video_lost,.axi_req(cap_req),.axi_rsp(cap_rsp));

    gesture_roi_resize #(.SRC_W(DW),.SRC_H(DH),.ROW_BYTES(DW*3),.FIFO_ADDR_W(6),.WATCHDOG_CYCLES(50000)) u_roi(
      .clk(proc_clk),.reset,.csr_req,.csr_rsp,.frame_valid,.published_slot,.published_seq,
      .capture_overflow(ovf),.capture_error(caperr),.clear_capture_errors,
      .capture_video_lost(video_lost),
      .roi_lock,.roi_lock_slot,.frame0_base,.frame1_base,.axi_req(roi_req),.axi_rsp(roi_rsp),
      .busy,.done_sticky,.error_sticky,.selected_seq);

    byte unsigned src_mem[0:8191];
    byte unsigned out_mem[0:1605631];
    integer lfsr=32'hc001d00d;
    function automatic integer source_offset(input logic [31:0] addr);
      if(addr>=32'h03100000) source_offset=4096+(addr-32'h03100000);
      else source_offset=addr-32'h03000000;
    endfunction
    function automatic [7:0] src_byte(input logic [31:0] addr);
      integer ix; begin ix=source_offset(addr); if(ix>=0&&ix<8192) src_byte=src_mem[ix]; else src_byte=0; end
    endfunction

    logic c_awready,c_wready,c_bvalid,c_awactive,c_bpending;
    logic [31:0] c_awaddr;
    logic [7:0] c_awlen;
    integer c_windex;
    logic [3:0] c_delay;
    logic q_arready,q_rvalid,q_awready,q_wready,q_bvalid;
    logic q_aractive,q_awactive,q_bpending;
    logic block_roi_ar=0,inject_rresp=0,inject_bresp=0,tail_seen=0;
    logic [31:0] q_araddr,q_awaddr;
    logic [7:0] q_arleft,q_awlen;
    integer q_windex;
    logic [3:0] q_delay;
    logic [127:0] q_rdata;

    always_comb begin
      cap_rsp='0; cap_rsp.awready=c_awready; cap_rsp.wready=c_wready;
      cap_rsp.bvalid=c_bvalid; cap_rsp.bid=2; cap_rsp.bresp=0;
      roi_rsp='0; roi_rsp.arready=q_arready; roi_rsp.rvalid=q_rvalid;
      roi_rsp.rdata=q_rdata; roi_rsp.rresp=(inject_rresp&&u_roi.out_y==1)?2'b10:2'b00; roi_rsp.rlast=(q_arleft==1);
      roi_rsp.rid=3; roi_rsp.awready=q_awready; roi_rsp.wready=q_wready;
      roi_rsp.bvalid=q_bvalid; roi_rsp.bid=3; roi_rsp.bresp=(inject_bresp&&q_bvalid)?2'b10:2'b00;
    end

    always @(posedge proc_clk) begin
      if(reset) begin
        lfsr<=32'hc001d00d;
        c_awready<=0;c_wready<=0;c_bvalid<=0;c_awactive<=0;c_bpending<=0;
        c_awaddr<=0;c_awlen<=0;c_windex<=0;c_delay<=0;
        q_arready<=0;q_rvalid<=0;q_awready<=0;q_wready<=0;q_bvalid<=0;tail_seen<=0;
        q_aractive<=0;q_awactive<=0;q_bpending<=0;q_araddr<=0;q_awaddr<=0;
        q_arleft<=0;q_awlen<=0;q_windex<=0;q_delay<=0;q_rdata<=0;
      end else begin
        lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        c_awready<=lfsr[0]&&!c_awactive&&!c_bpending;
        c_wready<=lfsr[3]&&c_awactive;
        if(cap_req.awvalid&&cap_rsp.awready) begin
          c_awaddr<=cap_req.awaddr;c_awlen<=cap_req.awlen;c_awactive<=1;c_windex<=0;
          if(cap_req.awaddr[11:0]+((cap_req.awlen+1)*16)>4096) $fatal(1,"capture burst crossed 4KB");
        end
        if(cap_req.wvalid&&cap_rsp.wready) begin
          for(integer k=0;k<16;k++) begin
            integer ix; ix=source_offset(c_awaddr)+c_windex*16+k;
            if(ix>=0&&ix<8192) src_mem[ix]<=cap_req.wdata[k*8+:8];
          end
          if(cap_req.wlast) begin c_awactive<=0;c_bpending<=1;c_delay<=2+lfsr[7:6]; end
          else c_windex<=c_windex+1;
        end
        if(c_bpending) begin
          if(c_delay!=0) c_delay<=c_delay-1;
          else c_bvalid<=1;
        end
        if(c_bvalid&&cap_req.bready) begin c_bvalid<=0;c_bpending<=0; end

        q_arready<=!block_roi_ar&&lfsr[5]&&!q_aractive;
        q_awready<=lfsr[6]&&!q_awactive&&!q_bpending;
        q_wready<=lfsr[9]&&q_awactive;
        if(roi_req.arvalid&&roi_rsp.arready) begin
          q_aractive<=1;q_araddr<=roi_req.araddr;q_arleft<=roi_req.arlen+1'b1;
        end
        q_rvalid<=q_aractive && lfsr[11] && !(q_rvalid&&roi_req.rready);
        if(q_rvalid&&roi_req.rready) begin
          q_araddr<=q_araddr+16;q_arleft<=q_arleft-1'b1;
          if(q_arleft==1) q_aractive<=0;
        end
        for(integer k=0;k<16;k++) q_rdata[k*8+:8]<=src_byte(q_araddr+k);

        if(roi_req.awvalid&&roi_rsp.awready) begin
          q_awaddr<=roi_req.awaddr;q_awlen<=roi_req.awlen;q_awactive<=1;q_windex<=0;
          if(roi_req.awaddr[11:0]+((roi_req.awlen+1)*16)>4096) $fatal(1,"ROI burst crossed 4KB");
        end
        if(roi_req.wvalid&&roi_rsp.wready) begin
          for(integer k=0;k<16;k++) begin
            integer ix; ix=q_awaddr-32'h02129000+q_windex*16+k;
            if(ix>=0&&ix<1605632) out_mem[ix]<=roi_req.wdata[k*8+:8];
          end
          if(roi_req.wstrb!==16'hffff) $fatal(1,"ROI WSTRB not full");
          if(roi_req.wlast) begin q_awactive<=0;q_bpending<=1;q_delay<=1+lfsr[13:12]; end
          else q_windex<=q_windex+1;
        end
        if(q_bpending) begin
          if(q_delay!=0) q_delay<=q_delay-1;
          else q_bvalid<=1;
        end
        if(q_bvalid&&roi_req.bready) begin q_bvalid<=0;q_bpending<=0; end
        if(error_sticky && busy && !roi_req.awvalid &&
           u_roi.out_fifo_count>0 && u_roi.out_fifo_count<16) tail_seen<=1;
      end
    end

    task automatic pixel(input integer x,input integer y,input integer fid);
      begin
        @(negedge pclk); de=1;
        r=(x*3+y+fid*17)&255;g=(y*5+fid*31)&255;b=(x^y^(fid*7))&255;
      end
    endtask
    task automatic blank(input integer n);
      repeat(n) begin @(negedge pclk); de=0; end
    endtask
    task automatic send_frame(input integer fid);
      begin
        blank(3); vs=1; blank(2); vs=0; blank(2);
        for(integer yy=0;yy<SH;yy++) begin
          for(integer xx=0;xx<SW;xx++) pixel(xx,yy,fid);
          blank(2);
        end
        blank(5);
      end
    endtask
    task automatic csr_write(input logic [11:0] addr,input logic [31:0] data);
      begin
        @(negedge proc_clk);csr_req.valid=1;csr_req.write=1;csr_req.address=addr;csr_req.wdata=data;
        @(negedge proc_clk);csr_req='0;
      end
    endtask
    task automatic check_roi_case(input integer x0,input integer y0,input integer side);
      integer base_addr,sx,sy;
      logic [7:0] er,eg,eb;
      begin
        csr_write(12'h014,32'(x0));
        csr_write(12'h018,32'(y0));
        csr_write(12'h01c,32'(side));
        csr_write(12'h000,2);
        csr_write(12'h000,1);
        wait(done_sticky || error_sticky);
        if(error_sticky || !done_sticky)
          $fatal(1,"ROI failed for origin=(%0d,%0d) side=%0d",x0,y0,side);
        for(integer oy=0;oy<224;oy++) begin
          sy=y0+(oy*side)/224;
          if(sy<0)sy=0;if(sy>=DH)sy=DH-1;
          for(integer ox=0;ox<224;ox++) begin
            sx=x0+(ox*side)/224;
            if(sx<0)sx=0;if(sx>=DW)sx=DW-1;
            base_addr=u_roi.selected_base_q+sy*DW*3+sx*3;
            er=src_byte(base_addr);eg=src_byte(base_addr+1);eb=src_byte(base_addr+2);
            base_addr=(oy*224+ox)*32;
            if(out_mem[base_addr]!==er || out_mem[base_addr+1]!==eg || out_mem[base_addr+2]!==eb)
              $fatal(1,"ROI mismatch origin=(%0d,%0d) side=%0d pixel=(%0d,%0d) got=%h,%h,%h expected=%h,%h,%h",x0,y0,side,ox,oy,out_mem[base_addr],out_mem[base_addr+1],out_mem[base_addr+2],er,eg,eb);
            for(integer pad=3;pad<32;pad++) if(out_mem[base_addr+pad]!==0)
              $fatal(1,"ROI padding mismatch origin=(%0d,%0d) side=%0d pixel=(%0d,%0d) byte=%0d",x0,y0,side,ox,oy,pad);
          end
        end
        $display("PASS: ROI reference origin=(%0d,%0d) side=%0d",x0,y0,side);
      end
    endtask

    initial begin
      csr_req='0;
      foreach(src_mem[i]) src_mem[i]=0;
      foreach(out_mem[i]) out_mem[i]=8'hff;
      repeat(8) @(negedge proc_clk);reset=0;
      send_frame(1);
      send_frame(2);
      wait(frame_valid && published_seq!=0);
      if(published_slot!==0) $fatal(1,"expected first complete frame in slot0");
      if(ovf||caperr) $fatal(1,"capture unexpectedly flagged a valid frame");
      repeat(40) @(posedge proc_clk); // emulate CPU latency after publication
      csr_write(12'h014,32'hffff_fffd); // x=-3
      csr_write(12'h018,32'hffff_fffe); // y=-2
      csr_write(12'h01c,20);
      csr_write(12'h000,1);
      fork
        begin wait(done_sticky || error_sticky); end
        begin
          send_frame(3);send_frame(4);send_frame(5);send_frame(6);
        end
      join
      if(error_sticky || !done_sticky) $fatal(1,"ROI failed error=%b",error_sticky);
      for(integer oy=0;oy<224;oy++) begin
        integer sy;
        sy=-2+(oy*20)/224;if(sy<0)sy=0;if(sy>=DH)sy=DH-1;
        for(integer ox=0;ox<224;ox++) begin
          integer sx,px,py,base;logic [7:0] er,eg,eb;
          sx=-3+(ox*20)/224;if(sx<0)sx=0;if(sx>=DW)sx=DW-1;
          px=1+sx*3;py=1+sy*3;base=(oy*224+ox)*32;
          er=(px*3+py+17)&255;eg=(py*5+31)&255;eb=(px^py^7)&255;
          if(out_mem[base]!==er||out_mem[base+1]!==eg||out_mem[base+2]!==eb)
            $fatal(1,"RGB mismatch at output %0d,%0d got %h %h %h expected %h %h %h",ox,oy,out_mem[base],out_mem[base+1],out_mem[base+2],er,eg,eb);
          for(integer pad=3;pad<32;pad++) if(out_mem[base+pad]!==0)
            $fatal(1,"C32 padding nonzero at output %0d,%0d byte %0d",ox,oy,pad);
        end
      end
      // Exercise nonintegral scales and both image-edge clamps against an
      // independent floor-coordinate reference using the published DDR frame.
      check_roi_case(-9,-5,217);
      check_roi_case(7,5,305);
      check_roi_case(7,5,1);
      check_roi_case(-200,400,1024);
      csr_write(12'h000,2);
      tail_seen=0;inject_bresp=1;
      csr_write(12'h000,1);
      wait(error_sticky&&!busy);
      if(done_sticky) $fatal(1,"ROI marked failed BRESP transaction done");
      if(!tail_seen) $fatal(1,"BRESP failure did not exercise dropping a sub-burst FIFO tail");
      inject_bresp=0;
      csr_write(12'h000,2);
      csr_write(12'h000,1);
      wait(done_sticky||error_sticky);
      if(error_sticky||!done_sticky) $fatal(1,"ROI retry after BRESP failure failed");
      csr_write(12'h000,2);
      inject_rresp=1;
      csr_write(12'h000,1);
      wait(error_sticky&&!busy);
      if(done_sticky) $fatal(1,"ROI marked failed RRESP transaction done");
      inject_rresp=0;
      csr_write(12'h000,2);
      csr_write(12'h000,1);
      wait(done_sticky||error_sticky);
      if(error_sticky||!done_sticky) $fatal(1,"ROI retry after RRESP failure failed");
      csr_write(12'h000,2);
      block_roi_ar=1;
      csr_write(12'h000,1);
      wait(error_sticky&&!busy);
      block_roi_ar=0;
      csr_write(12'h000,2);
      csr_write(12'h000,1);
      wait(done_sticky||error_sticky);
      if(error_sticky||!done_sticky) $fatal(1,"ROI retry after AR timeout failed");
      $display("PASS: async capture, AXI backpressure, 4KB bursts, signed ROI edge clamp, RGB C32 and all padding bytes");
      $finish;
    end
    initial begin #30000000; $fatal(1,"simulation timeout"); end
endmodule
