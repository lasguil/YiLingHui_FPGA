`timescale 1ns/1ps
module tb_gesture_net_integration;
    import demo_bus_pkg::*;
    localparam int SW=48, SH=48, DW=16, DH=16;
    localparam logic [31:0] FRAME0=32'h0300_0000, FRAME1=32'h0310_0000;
    localparam logic [31:0] ROI_BASE=32'h0212_9000;
    localparam logic [31:0] NPU_BASE=32'h0500_0000, CPU_BASE=32'h0600_0000;
    localparam int ROI_BYTES=224*224*32;

    logic clk=0,pclk=0,reset=1;
    always #5 clk=~clk;
    always #5.5 pclk=~pclk;

    logic vs=0,de=0;
    logic [7:0] pix_r=0,pix_g=0,pix_b=0;
    logic frame_valid,published_slot,cap_overflow,cap_error,video_lost;
    logic [30:0] published_seq;
    logic roi_lock,roi_lock_slot,roi_busy,roi_done,roi_error,clear_capture_errors;
    logic [31:0] frame0_base,frame1_base;
    logic [30:0] selected_seq;
    csr_req_t roi_csr_req;
    csr_rsp_t roi_csr_rsp;
    axi_req_t cap_req,roi_req,client_req[5],mem_req;
    axi_rsp_t cap_rsp,roi_rsp,client_rsp[5],mem_rsp;

    logic [7:0] cpu_awid,cpu_bid,cpu_arid,cpu_rid;
    logic [31:0] cpu_awaddr,cpu_wdata,cpu_araddr,cpu_rdata;
    logic [7:0] cpu_awlen,cpu_arlen;
    logic [2:0] cpu_awsize,cpu_arsize;
    logic [1:0] cpu_awburst,cpu_arburst,cpu_bresp,cpu_rresp;
    logic cpu_awvalid,cpu_awready,cpu_wvalid,cpu_wready,cpu_wlast,cpu_bvalid,cpu_bready;
    logic [3:0] cpu_wstrb;
    logic cpu_arvalid,cpu_arready,cpu_rvalid,cpu_rready,cpu_rlast;
    axi_req_t cpu_axi_req;
    axi_rsp_t cpu_axi_rsp;

    axi_req_t npu_req;
    axi_rsp_t npu_rsp;
    logic netclk=0;always #20 netclk=~netclk;
    logic net_begin=0,net_end=0,net_pop=0;
    wire net_lock,net_lock_slot,net_avail,net_busy,net_error,net_valid;
    wire [15:0] net_pixel;wire [31:0] net_count;
    axi_req_t net_req;axi_rsp_t net_rsp;
    integer net_ar_up=0;
    integer locked_capture_skips=0;
    always @(posedge clk)if(!reset && u_capture.pix_fifo_rd && u_capture.pix_fifo_data[24] &&
        ((roi_lock && roi_lock_slot==u_capture.candidate_slot) ||
         (net_lock && net_lock_slot==u_capture.candidate_slot)))locked_capture_skips<=locked_capture_skips+1;
    gesture_net_reader #(.SRC_W(DW),.SRC_H(DH),.OUT_W(7),.OUT_H(5),.FIFO_AW(3)) u_net(
      .proc_clk(clk),.net_clk(netclk),.reset,.frame_valid,.video_lost,.published_slot,.published_seq,
      .frame0_base,.frame1_base,.net_lock,.net_lock_slot,.axi_req(net_req),.axi_rsp(net_rsp),
      .frame_begin(net_begin),.frame_end(net_end),.pixel_pop(net_pop),.available(net_avail),
      .busy(net_busy),.error(net_error),.pixel_data(net_pixel),.pixel_valid(net_valid),.frame_count(net_count));
    logic merge_idle;

    gesture_frame_capture #(.SRC_W(SW),.SRC_H(SH),.DECIM(3),.FIFO_ADDR_W(5)) u_capture(
        .net_lock(net_lock),.net_lock_slot(net_lock_slot),.proc_clk(clk),.pclk,.reset,.hdmi_vs(vs),.hdmi_de(de),.hdmi_r(pix_r),.hdmi_g(pix_g),.hdmi_b(pix_b),
        .frame0_base,.frame1_base,.roi_lock,.roi_lock_slot,.clear_errors(clear_capture_errors),
        .frame_valid,.published_slot,.published_seq,.overflow_sticky(cap_overflow),.error_sticky(cap_error),
        .video_lost,.axi_req(cap_req),.axi_rsp(cap_rsp));

    gesture_roi_resize #(.SRC_W(DW),.SRC_H(DH),.ROW_BYTES(DW*3),.FIFO_ADDR_W(6),.WATCHDOG_CYCLES(1_000_000)) u_roi(
        .clk,.reset,.csr_req(roi_csr_req),.csr_rsp(roi_csr_rsp),.frame_valid,.published_slot,.published_seq,
        .capture_overflow(cap_overflow),.capture_error(cap_error),.capture_video_lost(video_lost),
        .clear_capture_errors,.roi_lock,.roi_lock_slot,.frame0_base,.frame1_base,
        .axi_req(roi_req),.axi_rsp(roi_rsp),.busy(roi_busy),.done_sticky(roi_done),
        .error_sticky(roi_error),.selected_seq);

    cpu_axi32_ddr128 u_cpu_bridge(
        .clk,.reset,.s_awid(cpu_awid),.s_awaddr(cpu_awaddr),.s_awlen(cpu_awlen),.s_awsize(cpu_awsize),
        .s_awburst(cpu_awburst),.s_awvalid(cpu_awvalid),.s_awready(cpu_awready),.s_wdata(cpu_wdata),
        .s_wstrb(cpu_wstrb),.s_wlast(cpu_wlast),.s_wvalid(cpu_wvalid),.s_wready(cpu_wready),
        .s_bid(cpu_bid),.s_bresp(cpu_bresp),.s_bvalid(cpu_bvalid),.s_bready(cpu_bready),
        .s_arid(cpu_arid),.s_araddr(cpu_araddr),.s_arlen(cpu_arlen),.s_arsize(cpu_arsize),
        .s_arburst(cpu_arburst),.s_arvalid(cpu_arvalid),.s_arready(cpu_arready),.s_rid(cpu_rid),
        .s_rdata(cpu_rdata),.s_rresp(cpu_rresp),.s_rlast(cpu_rlast),.s_rvalid(cpu_rvalid),.s_rready(cpu_rready),
        .m_req(cpu_axi_req),.m_rsp(cpu_axi_rsp));

    always_comb begin
        client_req[4]=net_req;net_rsp=client_rsp[4];
        client_req[0]=cap_req; client_req[1]=npu_req;
        client_req[2]=roi_req; client_req[3]=cpu_axi_req;
        cap_rsp=client_rsp[0]; npu_rsp=client_rsp[1];
        roi_rsp=client_rsp[2]; cpu_axi_rsp=client_rsp[3];
    end

    demo_axi_merge #(.CLIENTS(5)) u_merge(.clk,.reset,.ddr_ready(1'b1),.display_urgent(1'b0),
        .capture_urgent(cap_req.awvalid),.req(client_req),.rsp(client_rsp),
        .mem_req,.mem_rsp,.idle(merge_idle));

    // Sparse DDR byte model. Unwritten addresses return deterministic data.
    byte unsigned ddr_mem[longint unsigned];
    function automatic [7:0] mem_byte(input logic [31:0] addr);
        longint unsigned key;
        begin
            key={32'b0,addr};
            if(ddr_mem.exists(key)) mem_byte=ddr_mem[key];
            else mem_byte=(addr[7:0] ^ addr[15:8] ^ addr[23:16] ^ 8'h5a);
        end
    endfunction

    logic [31:0] lfsr=32'h173a_c9e5;
    logic arready_q,awready_q,wready_q;
    logic rd_active,rd_pending,rd_valid_q;
    logic [31:0] rd_addr_q,rd_pending_addr;
    logic [7:0] rd_len_q,rd_beat_q,rd_pending_len;
    logic [3:0] rd_delay_q;
    logic wr_active,b_pending,bvalid_q;
    logic [31:0] wr_addr_q;
    logic [7:0] wr_len_q,wr_beat_q;
    logic [3:0] wr_id_q,bdelay_q;
    integer ddr_ar_count=0,ddr_aw_count=0;
    integer cap_aw_up=0,roi_ar_up=0,roi_aw_up=0,npu_ar_up=0,npu_aw_up=0,cpu_ar_up=0,cpu_aw_up=0;
    integer cap_aw_mem=0,roi_ar_mem=0,roi_aw_mem=0,npu_ar_mem=0,npu_aw_mem=0,cpu_ar_mem=0,cpu_aw_mem=0;
    integer max_reads_pending=0;
    integer ar_owner_mask=0,aw_owner_mask=0;
    integer ar_stall_count=0,aw_stall_count=0,w_stall_count=0,r_stall_count=0;

    always_comb begin
        mem_rsp='0;
        mem_rsp.arready=arready_q && !rd_pending;
        mem_rsp.awready=awready_q && !wr_active && !bvalid_q;
        mem_rsp.wready=wready_q && wr_active;
        mem_rsp.bvalid=bvalid_q;
        mem_rsp.bid=wr_id_q;
        mem_rsp.bresp=2'b00;
        mem_rsp.rvalid=rd_valid_q;
        mem_rsp.rid=4'd0;
        mem_rsp.rresp=2'b00;
        mem_rsp.rlast=(rd_beat_q==rd_len_q);
        for(integer k=0;k<16;k++) mem_rsp.rdata[k*8+:8]=mem_byte(rd_addr_q+32'(rd_beat_q*16+k));
    end

    always @(posedge clk) begin
        if(reset) begin
            lfsr<=32'h173a_c9e5; arready_q<=0;awready_q<=0;wready_q<=0;
            rd_active<=0;rd_pending<=0;rd_valid_q<=0;rd_addr_q<=0;rd_pending_addr<=0;
            rd_len_q<=0;rd_beat_q<=0;rd_pending_len<=0;rd_delay_q<=0;
            wr_active<=0;b_pending<=0;bvalid_q<=0;wr_addr_q<=0;wr_len_q<=0;wr_beat_q<=0;wr_id_q<=0;bdelay_q<=0;
            ddr_ar_count<=0;ddr_aw_count<=0;
            cap_aw_up<=0;roi_ar_up<=0;roi_aw_up<=0;npu_ar_up<=0;npu_aw_up<=0;cpu_ar_up<=0;cpu_aw_up<=0;
            cap_aw_mem<=0;roi_ar_mem<=0;roi_aw_mem<=0;npu_ar_mem<=0;npu_aw_mem<=0;cpu_ar_mem<=0;cpu_aw_mem<=0;
            max_reads_pending<=0;ar_owner_mask<=0;aw_owner_mask<=0;
            ar_stall_count<=0;aw_stall_count<=0;w_stall_count<=0;r_stall_count<=0;
        end else begin
            lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            arready_q<=lfsr[0]||lfsr[4];
            awready_q<=lfsr[1]||lfsr[6];
            wready_q<=lfsr[2]||lfsr[9];
            if(mem_req.arvalid&&!mem_rsp.arready) ar_stall_count<=ar_stall_count+1;
            if(mem_req.awvalid&&!mem_rsp.awready) aw_stall_count<=aw_stall_count+1;
            if(mem_req.wvalid&&!mem_rsp.wready) w_stall_count<=w_stall_count+1;
            if(mem_rsp.rvalid&&!mem_req.rready) r_stall_count<=r_stall_count+1;

            if(cap_req.awvalid&&cap_rsp.awready) cap_aw_up<=cap_aw_up+1;
            if(net_req.arvalid&&net_rsp.arready)net_ar_up<=net_ar_up+1;
            if(roi_req.arvalid&&roi_rsp.arready) roi_ar_up<=roi_ar_up+1;
            if(roi_req.awvalid&&roi_rsp.awready) roi_aw_up<=roi_aw_up+1;
            if(npu_req.arvalid&&npu_rsp.arready) npu_ar_up<=npu_ar_up+1;
            if(npu_req.awvalid&&npu_rsp.awready) npu_aw_up<=npu_aw_up+1;
            if(cpu_axi_req.arvalid&&cpu_axi_rsp.arready) cpu_ar_up<=cpu_ar_up+1;
            if(cpu_axi_req.awvalid&&cpu_axi_rsp.awready) cpu_aw_up<=cpu_aw_up+1;

            if(mem_req.arvalid&&mem_rsp.arready) begin
                if(mem_req.arid!=0 || mem_req.araddr[3:0]!=0 || mem_req.arsize!=4 || mem_req.arburst!=1)
                    $fatal(1,"merge emitted malformed DDR AR id=%0d addr=%h size=%0d",mem_req.arid,mem_req.araddr,mem_req.arsize);
                if(mem_req.araddr[11:0]+((mem_req.arlen+1)*16)>4096) $fatal(1,"DDR AR crossed 4KiB");
                if(rd_active) begin rd_pending<=1;rd_pending_addr<=mem_req.araddr;rd_pending_len<=mem_req.arlen;end
                else begin rd_pending<=1;rd_pending_addr<=mem_req.araddr;rd_pending_len<=mem_req.arlen;end
                ddr_ar_count<=ddr_ar_count+1;
                if(mem_req.araddr>=FRAME0 && mem_req.araddr<FRAME1) begin roi_ar_mem<=roi_ar_mem+1;ar_owner_mask<=ar_owner_mask|4'b0100;end
                else if(mem_req.araddr>=FRAME1 && mem_req.araddr<FRAME1+32'h0010_0000) begin roi_ar_mem<=roi_ar_mem+1;ar_owner_mask<=ar_owner_mask|4'b0100;end
                else if(mem_req.araddr>=NPU_BASE && mem_req.araddr<NPU_BASE+32'h10000) begin npu_ar_mem<=npu_ar_mem+1;ar_owner_mask<=ar_owner_mask|4'b0010;end
                else if(mem_req.araddr>=CPU_BASE && mem_req.araddr<CPU_BASE+32'h10000) begin cpu_ar_mem<=cpu_ar_mem+1;ar_owner_mask<=ar_owner_mask|4'b1000;end
                else $fatal(1,"unexpected DDR read address %h",mem_req.araddr);
            end
            if(!rd_active && rd_pending) begin
                rd_active<=1;rd_addr_q<=rd_pending_addr;rd_len_q<=rd_pending_len;rd_beat_q<=0;
                rd_pending<=0;rd_delay_q<=1+lfsr[12:11];rd_valid_q<=0;
            end
            if(rd_active && !rd_valid_q) begin
                if(rd_delay_q!=0) rd_delay_q<=rd_delay_q-1;
                else if(lfsr[14]) rd_valid_q<=1;
            end
            if(rd_valid_q && mem_req.rready) begin
                rd_valid_q<=0;
                if(rd_beat_q==rd_len_q) rd_active<=0;
                else begin rd_beat_q<=rd_beat_q+1;rd_delay_q<=lfsr[12:11];end
            end

            if(mem_req.awvalid&&mem_rsp.awready) begin
                if(mem_req.awaddr[3:0]!=0 || mem_req.awsize!=4 || mem_req.awburst!=1)
                    $fatal(1,"merge emitted malformed DDR AW addr=%h size=%0d",mem_req.awaddr,mem_req.awsize);
                if(mem_req.awaddr[11:0]+((mem_req.awlen+1)*16)>4096) $fatal(1,"DDR AW crossed 4KiB");
                wr_active<=1;wr_addr_q<=mem_req.awaddr;wr_len_q<=mem_req.awlen;wr_beat_q<=0;wr_id_q<=mem_req.awid;
                ddr_aw_count<=ddr_aw_count+1;
                if(mem_req.awaddr>=FRAME0 && mem_req.awaddr<FRAME1+32'h0010_0000) begin cap_aw_mem<=cap_aw_mem+1;aw_owner_mask<=aw_owner_mask|4'b0001;end
                else if(mem_req.awaddr>=ROI_BASE && mem_req.awaddr<ROI_BASE+ROI_BYTES) begin roi_aw_mem<=roi_aw_mem+1;aw_owner_mask<=aw_owner_mask|4'b0100;end
                else if(mem_req.awaddr>=NPU_BASE && mem_req.awaddr<NPU_BASE+32'h10000) begin npu_aw_mem<=npu_aw_mem+1;aw_owner_mask<=aw_owner_mask|4'b0010;end
                else if(mem_req.awaddr>=CPU_BASE && mem_req.awaddr<CPU_BASE+32'h10000) begin cpu_aw_mem<=cpu_aw_mem+1;aw_owner_mask<=aw_owner_mask|4'b1000;end
                else $fatal(1,"unexpected DDR write address %h",mem_req.awaddr);
                if(mem_req.awaddr>=FRAME0 && mem_req.awaddr<FRAME1+32'h0010_0000 && mem_req.awid!=2)
                    $fatal(1,"capture AWID mismatch");
                if(mem_req.awaddr>=ROI_BASE && mem_req.awaddr<ROI_BASE+ROI_BYTES && mem_req.awid!=3)
                    $fatal(1,"ROI AWID mismatch");
                if(mem_req.awaddr>=NPU_BASE && mem_req.awaddr<NPU_BASE+32'h10000 && mem_req.awid!=5)
                    $fatal(1,"NPU AWID mismatch");
                if(mem_req.awaddr>=CPU_BASE && mem_req.awaddr<CPU_BASE+32'h10000 && mem_req.awid!=0)
                    $fatal(1,"CPU adapter AWID mismatch");
            end
            if(mem_req.wvalid&&mem_rsp.wready) begin
                if(mem_req.wlast!=(wr_beat_q==wr_len_q)) $fatal(1,"DDR WLAST mismatch");
                for(integer k=0;k<16;k++) if(mem_req.wstrb[k])
                    ddr_mem[{32'b0,wr_addr_q+32'(wr_beat_q*16+k)}]=mem_req.wdata[k*8+:8];
                if(mem_req.wlast) begin wr_active<=0;b_pending<=1;bdelay_q<=1+lfsr[18:17];end
                else wr_beat_q<=wr_beat_q+1;
            end
            if(b_pending && !bvalid_q) begin
                if(bdelay_q!=0)bdelay_q<=bdelay_q-1;
                else bvalid_q<=1;
            end
            if(bvalid_q && mem_req.bready) begin bvalid_q<=0;b_pending<=0;end
        end
    end

    // CPU's 32-bit AXI-A test master.
    task automatic cpu_write_words(input logic [31:0] addr,input integer words,input logic [7:0] id,input logic [31:0] seed);
        begin
            @(negedge clk);cpu_awid=id;cpu_awaddr=addr;cpu_awlen=words-1;cpu_awsize=2;cpu_awburst=1;cpu_awvalid=1;
            do @(posedge clk); while(!cpu_awready);
            @(negedge clk);cpu_awvalid=0;
            for(integer n=0;n<words;n++) begin
                cpu_wdata=seed+n*32'h0101_0101;cpu_wstrb=4'hf;cpu_wlast=(n==words-1);cpu_wvalid=1;
                do @(posedge clk); while(!cpu_wready);
                @(negedge clk);cpu_wvalid=0;
            end
            cpu_bready=1;do @(posedge clk); while(!cpu_bvalid);
            if(cpu_bid!=id||cpu_bresp!=0) $fatal(1,"CPU B response changed by merge");
            @(negedge clk);cpu_bready=0;
        end
    endtask
    task automatic cpu_read_words(input logic [31:0] addr,input integer words,input logic [7:0] id,input logic [31:0] seed);
        logic [31:0] expected;
        begin
            @(negedge clk);cpu_arid=id;cpu_araddr=addr;cpu_arlen=words-1;cpu_arsize=2;cpu_arburst=1;cpu_arvalid=1;
            do @(posedge clk); while(!cpu_arready);
            @(negedge clk);cpu_arvalid=0;cpu_rready=1;
            for(integer n=0;n<words;n++) begin
                do @(posedge clk); while(!cpu_rvalid);
                expected=seed+n*32'h0101_0101;
                if(cpu_rid!=id||cpu_rresp!=0||cpu_rdata!==expected||cpu_rlast!=(n==words-1))
                    $fatal(1,"CPU read mismatch n=%0d id=%h data=%h expected=%h",n,cpu_rid,cpu_rdata,expected);
            end
            @(negedge clk);cpu_rready=0;
        end
    endtask

    task automatic npu_write_burst;
        begin
            @(negedge clk);npu_req.awid=5;npu_req.awaddr=NPU_BASE;npu_req.awlen=3;npu_req.awsize=4;npu_req.awburst=1;npu_req.awvalid=1;
            do @(posedge clk); while(!npu_rsp.awready);
            @(negedge clk);npu_req.awvalid=0;
            for(integer n=0;n<4;n++) begin
                npu_req.wdata={4{32'h4a00_1000+n}};npu_req.wstrb=16'hffff;npu_req.wlast=(n==3);npu_req.wvalid=1;
                do @(posedge clk); while(!npu_rsp.wready);
                @(negedge clk);npu_req.wvalid=0;
            end
            npu_req.bready=1;do @(posedge clk);while(!npu_rsp.bvalid);
            if(npu_rsp.bid!=5||npu_rsp.bresp!=0)$fatal(1,"NPU B response owner/ID mismatch");
            @(negedge clk);npu_req.bready=0;
        end
    endtask
    task automatic npu_read_burst;
        logic [127:0] expected;
        begin
            @(negedge clk);npu_req.arid=5;npu_req.araddr=NPU_BASE;npu_req.arlen=3;npu_req.arsize=4;npu_req.arburst=1;npu_req.arvalid=1;
            do @(posedge clk);while(!npu_rsp.arready);
            @(negedge clk);npu_req.arvalid=0;npu_req.rready=0;
            repeat(16)@(negedge clk); // Exercise DDR R-channel backpressure from an AXI client.
            npu_req.rready=1;
            for(integer n=0;n<4;n++) begin
                do @(posedge clk);while(!npu_rsp.rvalid);
                expected={4{32'h4a00_1000+n}};
                if(npu_rsp.rid!=5||npu_rsp.rresp!=0||npu_rsp.rdata!==expected||npu_rsp.rlast!=(n==3))
                    $fatal(1,"NPU R response owner/ID/data mismatch beat=%0d got=%h expected=%h",n,npu_rsp.rdata,expected);
            end
            @(negedge clk);npu_req.rready=0;
        end
    endtask

    function automatic [7:0] expected_r(input integer x,input integer y,input integer fid);
        expected_r=(x*3+y+fid*17)&255;
    endfunction
    function automatic [7:0] expected_g(input integer x,input integer y,input integer fid);
        expected_g=(y*5+fid*31)&255;
    endfunction
    function automatic [7:0] expected_b(input integer x,input integer y,input integer fid);
        expected_b=(x^y^(fid*7))&255;
    endfunction
    task automatic send_pixel(input integer x,input integer y,input integer fid);
        begin
            @(negedge pclk);de=1;
            pix_r=(x*3+y+fid*17)&255;pix_g=(y*5+fid*31)&255;pix_b=(x^y^(fid*7))&255;
        end
    endtask
    task automatic blank_pixels(input integer n);
        repeat(n) begin @(negedge pclk);de=0;end
    endtask
    task automatic send_frame(input integer fid);
        begin
            blank_pixels(3);vs=1;blank_pixels(2);vs=0;blank_pixels(2);
            for(integer y=0;y<SH;y++) begin
                for(integer x=0;x<SW;x++) send_pixel(x,y,fid);
                blank_pixels(2);
            end
            blank_pixels(4);
        end
    endtask
    task automatic roi_csr_write(input logic [11:0] addr,input logic [31:0] data);
        begin
            @(negedge clk);roi_csr_req.valid=1;roi_csr_req.write=1;roi_csr_req.address=addr;roi_csr_req.wdata=data;roi_csr_req.wstrb=4'hf;
            @(posedge clk); if(!roi_csr_rsp.ready)$fatal(1,"ROI CSR was not ready");
            @(negedge clk);roi_csr_req='0;
        end
    endtask

    logic [31:0] cpu_seed=32'h9a21_00f3;
    initial begin
        roi_csr_req='0;npu_req='0;
        cpu_awid=0;cpu_awaddr=0;cpu_awlen=0;cpu_awsize=2;cpu_awburst=1;cpu_awvalid=0;
        cpu_wdata=0;cpu_wstrb=0;cpu_wlast=0;cpu_wvalid=0;cpu_bready=0;
        cpu_arid=0;cpu_araddr=0;cpu_arlen=0;cpu_arsize=2;cpu_arburst=1;cpu_arvalid=0;cpu_rready=0;
        repeat(8)@(negedge clk);reset=0;

        // Capture two complete frames, then lock the most recently published slot for ROI.
        send_frame(1);
        fork
            begin send_frame(2); end
            begin
                wait(frame_valid && published_seq>=1);
                if(published_slot!=0 || cap_overflow || cap_error) $fatal(1,"capture publication/validity failure");
                roi_csr_write(12'h014,0);roi_csr_write(12'h018,0);roi_csr_write(12'h01c,DW);
                roi_csr_write(12'h000,1);
            end
            begin
                wait(net_avail);
                @(negedge netclk);net_begin=1;@(negedge netclk);net_begin=0;
                for(integer n=0;n<35;n++)begin
                    integer sx,sy;logic [7:0] er,eg,eb;logic [15:0] expected;
                    repeat(100)@(negedge netclk);
                    while(!net_valid)@(negedge netclk);
                    sx=1+((n%7)*DW/7)*3;sy=1+((n/7)*DH/5)*3;
                    er=expected_r(sx,sy,1);eg=expected_g(sx,sy,1);eb=expected_b(sx,sy,1);
                    expected={er[7:3],eg[7:2],eb[7:3]};
                    if(net_error||net_pixel!==expected)$fatal(1,"network pixel %0d got %h expected %h",n,net_pixel,expected);
                    net_pop=1;@(negedge netclk);net_pop=0;
                end
                net_end=1;@(negedge netclk);net_end=0;
                wait(!net_busy);
            end
        join
        fork
            begin send_frame(3); end
            begin
                cpu_write_words(CPU_BASE,4,8'h39,cpu_seed);
                cpu_read_words(CPU_BASE,4,8'hc2,cpu_seed);
            end
            begin npu_write_burst(); npu_read_burst(); end
            begin wait(roi_done || roi_error); end
        join
        if(roi_error||!roi_done)$fatal(1,"integrated ROI DMA failed");
        if(cap_error || (cap_overflow && locked_capture_skips==0))
            $fatal(1,"unexpected capture error during shared DDR arbitration");
        if(locked_capture_skips==0)$fatal(1,"locked-slot skip was not exercised");

        // Verify every RGB pixel and all C32 padding bytes from the exact published frame.
        for(integer oy=0;oy<224;oy++) begin
            integer sy; sy=(oy*DW)/224;
            for(integer ox=0;ox<224;ox++) begin
                integer sx; logic [7:0] er,eg,eb; logic [31:0] base; integer x,y;
                sx=(ox*DW)/224;x=1+sx*3;y=1+sy*3;base=ROI_BASE+((oy*224+ox)*32);
                er=expected_r(x,y,1);eg=expected_g(x,y,1);eb=expected_b(x,y,1);
                if(mem_byte(base)!==er||mem_byte(base+1)!==eg||mem_byte(base+2)!==eb)
                    $fatal(1,"integrated ROI RGB mismatch (%0d,%0d) got %h,%h,%h expected %h,%h,%h",ox,oy,mem_byte(base),mem_byte(base+1),mem_byte(base+2),er,eg,eb);
                for(integer p=3;p<32;p++) if(mem_byte(base+p)!==0)
                    $fatal(1,"integrated C32 padding mismatch (%0d,%0d) byte %0d",ox,oy,p);
            end
        end
        if(cap_aw_up!=cap_aw_mem || roi_ar_up+net_ar_up!=roi_ar_mem || roi_aw_up!=roi_aw_mem ||
           npu_ar_up!=npu_ar_mem || npu_aw_up!=npu_aw_mem || cpu_ar_up!=cpu_ar_mem || cpu_aw_up!=cpu_aw_mem)
            $fatal(1,"AXI duplicate/drop counters: up capAW=%0d roiAR=%0d roiAW=%0d npuAR/AW=%0d/%0d cpuAR/AW=%0d/%0d mem=%0d/%0d/%0d/%0d/%0d/%0d/%0d",
              cap_aw_up,roi_ar_up,roi_aw_up,npu_ar_up,npu_aw_up,cpu_ar_up,cpu_aw_up,
              cap_aw_mem,roi_ar_mem,roi_aw_mem,npu_ar_mem,npu_aw_mem,cpu_ar_mem,cpu_aw_mem);
        if((ar_owner_mask&4'b1110)!=4'b1110 || (aw_owner_mask&4'b1111)!=4'b1111)
            $fatal(1,"not all expected client classes reached DDR: AR=%b AW=%b",ar_owner_mask,aw_owner_mask);
        if(cap_aw_up!=6) $fatal(1,"expected two 768B capture frames as six bursts, got %0d",cap_aw_up);
        if(roi_aw_up!=6272) $fatal(1,"expected complete 224x224 C32 output, got %0d bursts",roi_aw_up);
        if(npu_aw_up!=1||npu_ar_up!=1||cpu_aw_up!=4||cpu_ar_up!=4)
            $fatal(1,"client command counts unexpected");
        if(ar_stall_count==0||aw_stall_count==0||w_stall_count==0||r_stall_count==0)
            $fatal(1,"DDR backpressure was not exercised AR/AW/W/R=%0d/%0d/%0d/%0d",ar_stall_count,aw_stall_count,w_stall_count,r_stall_count);
        if(net_ar_up!=5)$fatal(1,"network row DMA count mismatch: %0d",net_ar_up);
        if(!merge_idle)$fatal(1,"merge still owns a transaction after completion");
        $display("PASS: five-client DDR/network RGB565 pixel checking and shared AXI integration; capture/ROI/NPU/CPU ownership, IDs, readback, backpressure AR/AW/W/R=%0d/%0d/%0d/%0d, and complete C32 output verified; AR=%0d AW=%0d",ar_stall_count,aw_stall_count,w_stall_count,r_stall_count,ddr_ar_count,ddr_aw_count);
        $finish;
    end
    initial begin #20_000_000;$fatal(1,"shared DDR integration timeout");end
endmodule
