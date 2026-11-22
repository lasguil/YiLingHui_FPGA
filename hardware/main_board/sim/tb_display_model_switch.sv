// Display subsystem scene check: two DDR sources, one shared line cache.
//
// A stub AXI read slave serves two frame buffers (A at 0x1000_0000, B at
// 0x2000_0000, 128-byte rows). The CPU port programs a small 64x8 scene, then
// every visible pixel of wipe and side-by-side frames is compared against the
// source that should be shown there, so the shared cache's pixel-side source
// selection is checked end to end.
`timescale 1ns/1ps
module tb_display_model_switch #(parameter integer STEP=65536,STEP_X=STEP,STEP_Y=STEP,DYNAMIC=0,READ_GAP=2,SOURCE_X=0,STALL_ONCE=0,TEST_WIDTH=64,TEST_HEIGHT=8,ONE_PASS=0,MERGE_COMPETITOR=0,NPU_BURST_GAP=0,WRITE_COMPETITOR=0,CAMERA_BEAT_GAP=0,PEER_WRITE_COMPETITOR=0,EXPECT_UNDERFLOW=0,GEOMETRY_SWITCH=0,CHECK_DIAGNOSTICS=0,CHECK_EVENT_Y=0,TRACE_COMMANDS=0,
                         parameter real AXI_HALF_NS=5.0);
    localparam integer H_ACTIVE=TEST_WIDTH,V_ACTIVE=TEST_HEIGHT;
    // Blanking is far larger than the visible area on purpose: it emulates the
    // ~14.8us 1080p line time the row prefetch is designed against, while the
    // checked scene stays small enough to compare pixel by pixel.
    localparam integer H_FRONT=TEST_WIDTH==64 ? 1000 : 2200-TEST_WIDTH-192;
    localparam integer H_SYNC=TEST_WIDTH==64 ? 20 : 44,H_BACK=TEST_WIDTH==64 ? 600 : 148;
    localparam integer V_FRONT=4,V_SYNC=2,V_BACK=8;
    localparam integer H_TOTAL=H_ACTIVE+H_FRONT+H_SYNC+H_BACK;
    localparam integer V_TOTAL=V_ACTIVE+V_FRONT+V_SYNC+V_BACK;
    localparam logic [31:0] BASE_A=32'h1000_0000;
    localparam logic [31:0] BASE_B=32'h2000_0000;
    localparam integer SRC_W=(H_ACTIVE*STEP_X+65535)/65536;
    localparam integer SRC_H=(V_ACTIVE*STEP_Y+65535)/65536;
    localparam integer MAPPED_SOURCE_ROWS=(STEP_Y<=65536)?(((V_ACTIVE-1)*STEP_Y)/65536+1):V_ACTIVE;
    localparam integer STRIDE=((SRC_W+SOURCE_X+7)/8)*16;

    logic cfg_clk=0,axi_clk=0,pix_clk=0;
    always #5 cfg_clk=~cfg_clk;
    always #(AXI_HALF_NS) axi_clk=~axi_clk;
    always #3.367 pix_clk=~pix_clk;
    logic cfg_rst_n=0,axi_rst_n=0,pix_rst_n=0;

    logic cfg_valid=0,cfg_write=0;
    logic [11:0] cfg_addr=0;
    logic [31:0] cfg_wdata=0;
    logic [3:0] cfg_wstrb=4'hf;
    logic cfg_ready,cfg_error;
    logic [31:0] cfg_rdata;

    logic [3:0] m_axi_arid,m_axi_rid;
    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic [3:0] m_axi_arcache;
    logic [2:0] m_axi_arprot;
    logic m_axi_arlock,m_axi_arvalid,m_axi_arready;
    logic [3:0] m_axi_arqos;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast,m_axi_rvalid,m_axi_rready;
    logic axi_error_a,axi_error_b;
    logic [9:0] tmds_clk_data,tmds_data0,tmds_data1,tmds_data2;
    logic tmds_tx_oe,tmds_tx_reset;
    logic [15:0] debug_rgb565;
    logic debug_de,debug_hs,debug_vs;

    import demo_bus_pkg::*;
    axi_req_t req[4],fake_npu_req,capture_req,peer_wr_req,mem_req;
    axi_rsp_t rsp[4],mem_rsp;
    logic merge_idle;
    integer capture_aw_wait=0;
    wire CAPTURE_URGENT_MODEL=WRITE_COMPETITOR && capture_req.awvalid && capture_aw_wait>=4;

    always_comb begin
        for(int i=0;i<4;i++)req[i]='0;
        req[0].arid=m_axi_arid;req[0].araddr=m_axi_araddr;req[0].arlen=m_axi_arlen;
        req[0].arsize=m_axi_arsize;req[0].arburst=m_axi_arburst;
        req[0].arvalid=m_axi_arvalid;req[0].rready=m_axi_rready;
        req[1]=fake_npu_req;
        req[2]=capture_req;
        req[3]=peer_wr_req;
    end
    assign m_axi_arready=rsp[0].arready;
    assign m_axi_rid=rsp[0].rid;assign m_axi_rdata=rsp[0].rdata;
    assign m_axi_rresp=rsp[0].rresp;assign m_axi_rlast=rsp[0].rlast;
    assign m_axi_rvalid=rsp[0].rvalid;

    demo_axi_merge #(.LIMIT_URGENT_BURSTS(1'b1)) merge(
        .clk(axi_clk),.reset(!axi_rst_n),.ddr_ready(axi_rst_n),
        .display_urgent(req[0].arvalid),.capture_urgent(CAPTURE_URGENT_MODEL),
        .req,.rsp,.mem_req,.mem_rsp,.idle(merge_idle));

    display_system_top #(
        .H_ACTIVE(H_ACTIVE),.V_ACTIVE(V_ACTIVE),
        .H_FRONT(H_FRONT),.H_SYNC(H_SYNC),.H_BACK(H_BACK),
        .V_FRONT(V_FRONT),.V_SYNC(V_SYNC),.V_BACK(V_BACK),
        .MAX_WIDTH(1920),.AXI_DATA_WIDTH(128),.AXI_ID_WIDTH(4)
    ) dut(
        .cfg_clk,.cfg_rst_n,.cfg_valid,.cfg_write,.cfg_addr,.cfg_wdata,.cfg_wstrb,
        .cfg_ready,.cfg_error,.cfg_rdata,
        .axi_clk,.axi_rst_n,.pix_clk,.pix_rst_n,.axi_error_a,.axi_error_b,
        .m_axi_arid,.m_axi_araddr,.m_axi_arlen,.m_axi_arsize,.m_axi_arburst,
        .m_axi_arcache,.m_axi_arprot,.m_axi_arlock,.m_axi_arqos,
        .m_axi_arvalid,.m_axi_arready,
        .m_axi_rid,.m_axi_rdata,.m_axi_rresp,.m_axi_rlast,.m_axi_rvalid,.m_axi_rready,
        .tmds_clk_data,.tmds_data0,.tmds_data1,.tmds_data2,.tmds_tx_oe,.tmds_tx_reset,
        .debug_rgb565,.debug_de,.debug_hs,.debug_vs,.active_base_a(),.active_base_b());

    logic line_y_sample_pending=0;
    logic [11:0] line_y_sample=0,line_y_raster=0;
    logic trace_cmd_a_toggle=0,trace_cmd_b_toggle=0;
    integer line_y_equiv_samples=0,line_y_first_samples=0,line_y_last_samples=0;
    integer trace_pix_cycle=0,geometry_active_line_samples=0;
    logic geometry_new_seen=0,geometry_vs_observed=0;

    // x=0 selects a special y accumulator value and commits it by NBA on that
    // edge. At the following pixel, x=1 must expose the same mapped current
    // source row; the compact row scheduler consumes this live value instead
    // of storing another 12-bit copy. This checks every active row, including
    // destination endpoints and repeated/skipped source rows.
    always @(negedge pix_clk)begin
        if(!pix_rst_n)begin
            line_y_sample_pending=0;line_y_equiv_samples=0;line_y_first_samples=0;line_y_last_samples=0;
            trace_cmd_a_toggle=0;trace_cmd_b_toggle=0;trace_pix_cycle=0;
        end else begin
            trace_pix_cycle=trace_pix_cycle+1;
            if(line_y_sample_pending)begin
                if(!dut.in_de || dut.x!=12'd1 || dut.y!=line_y_raster || dut.src_a_y!==line_y_sample)
                    $fatal(1,"current source y changed between line-start x0/x1 y=%0d x1=%0d was=%0d now=%0d",line_y_raster,dut.x,line_y_sample,dut.src_a_y);
                line_y_equiv_samples=line_y_equiv_samples+1;
                line_y_sample_pending=0;
            end
            if(dut.in_de && dut.x==12'd0)begin
                line_y_sample_pending=1;line_y_sample=dut.src_a_y;line_y_raster=dut.y;
                if(dut.y==dut.dest_y)line_y_first_samples=line_y_first_samples+1;
                if(({1'b0,dut.y}+13'd1)==({1'b0,dut.dest_y}+{1'b0,dut.dest_height}))
                    line_y_last_samples=line_y_last_samples+1;
                if(GEOMETRY_SWITCH&&geometry_new_seen&&dut.y>=dut.dest_y&&
                   {1'b0,dut.y}<{1'b0,dut.dest_y}+{1'b0,dut.dest_height})
                    geometry_active_line_samples=geometry_active_line_samples+1;
            end
            if(TRACE_COMMANDS)begin
                if(dut.cmd_a_toggle!=trace_cmd_a_toggle)begin
                    $display("CMDTRACE A cycle=%0d base=%08x stride=%0d width=%0d y=%0d bank=%0d first=%0d beat=%0d",trace_pix_cycle,dut.cmd_a_base,dut.cmd_a_stride,dut.cmd_a_width,dut.cmd_a_y,dut.cmd_a_bank,dut.cmd_a_first,12'd0);
                    trace_cmd_a_toggle=dut.cmd_a_toggle;
                end
                if(dut.cmd_b_toggle!=trace_cmd_b_toggle)begin
                    $display("CMDTRACE B cycle=%0d base=%08x stride=%0d width=%0d y=%0d bank=%0d first=%0d beat=%0d",trace_pix_cycle,dut.cmd_b_base,dut.cmd_b_stride,dut.cmd_b_width,dut.cmd_b_y,dut.cmd_b_bank,dut.cmd_b_first,dut.cmd_b_first_beat);
                    trace_cmd_b_toggle=dut.cmd_b_toggle;
                end
            end
        end
    end

    // Bounded two-address DDR model. Each accepted address reserves a queue
    // slot; R data is returned in order with a configurable inter-beat gap.
    logic [31:0] queued_addr[2];
    logic [7:0] queued_left[2];
    logic queue_head=0,queue_tail=0;
    integer queue_count=0;
    integer rdelay=0;
    integer stall_remaining=0;
    integer turnaround_remaining=0;
    logic last_dir_valid=0,last_dir_write=0;
    logic stalled=0;
    logic write_bvalid=0;
    integer capture_write_bursts=0,peer_write_bursts=0,max_capture_aw_wait=0;
    integer capture_write_beats=0,peer_write_beats=0;
    integer underflow_frame2=0,underflow_frame3=0;
    logic geometry_switch_waiting=0;
    integer geometry_switches=0;
    logic axi_frame_vs_q=0;
    integer display_row,display_col;
    integer repeated_source_rows=0,skipped_source_rows=0,previous_source_row=0;
    localparam integer LINE_CYCLES=$rtoi((H_TOTAL*6.734)/(2.0*AXI_HALF_NS));
    integer axi_cycle_count=0,max_pair_cycles=0,pairs_completed=0,max_display_burst=0,display_bursts=0,npu_bursts=0,max_npu_burst=0;
    logic [1:0] pair_started[0:2047],pair_done[0:2047];
    integer pair_start_cycle[0:2047],pair_latency;
    integer pix_cycle_count=0,max_cache_deadline_a=0,max_cache_deadline_b=0;
    integer cache_issue_a[0:2047],cache_issue_b[0:2047],cache_ready_a[0:2047],cache_ready_b[0:2047];
    integer cache_deadline_a_samples=0,cache_deadline_b_samples=0;
    integer last_deadline_a_y=-1,last_deadline_b_y=-1;
    integer display_ar_wait=0,max_display_ar_wait=0,npu_ar_wait=0,max_npu_ar_wait=0;
    integer vs_count=0;
    logic vs_q=0;
    function automatic [15:0] generation();
        generation=DYNAMIC ? 16'(vs_count)*16'h0100 : 16'd0;
    endfunction
    function automatic [15:0] mem_at(input logic [31:0] addr);
        logic [31:0] off;
        integer src,y,x;
        begin
            if(addr[31:28]==4'h2) begin src=1;off=addr-BASE_B;end
            else begin src=0;off=addr-BASE_A;end
            y=int'(off/STRIDE);
            x=int'((off%STRIDE)/2);
            mem_at=16'h4000+16'h2000*16'(src)+16'h0080*16'(y)+16'(x)+generation();
        end
    endfunction
    always_comb begin
        mem_rsp='0;
        mem_rsp.arready=(queue_count<2)&&(stall_remaining==0)&&axi_rst_n&&
                        !(last_dir_valid&&last_dir_write&&turnaround_remaining!=0);
        mem_rsp.rvalid=(queue_count!=0)&&(rdelay==0)&&(stall_remaining==0);
        mem_rsp.rlast=(queue_count!=0)&&(queued_left[queue_head]==1);
        // Bounded write-channel backpressure and one-cycle B response after
        // each accepted WLAST exercise the merge's real AW/W/B owner lock.
        mem_rsp.awready=axi_rst_n && ((axi_cycle_count%7)!=0)&&
                        !(last_dir_valid&&!last_dir_write&&turnaround_remaining!=0);
        mem_rsp.wready=axi_rst_n && ((axi_cycle_count%13)!=0);
        mem_rsp.bvalid=write_bvalid;mem_rsp.bid=4'd0;mem_rsp.bresp=2'd0;
        for(integer lane=0;lane<8;lane++)
            mem_rsp.rdata[lane*16+:16]=mem_at(queued_addr[queue_head]+2*lane);
    end
    always_ff @(posedge axi_clk or negedge axi_rst_n) begin
        if(!axi_rst_n) begin
            queued_addr[0]<=0;queued_addr[1]<=0;queued_left[0]<=0;queued_left[1]<=0;
            queue_head<=0;queue_tail<=0;queue_count<=0;rdelay<=0;stall_remaining<=0;stalled<=0;
            turnaround_remaining<=0;last_dir_valid<=0;last_dir_write<=0;
            axi_cycle_count<=0;max_pair_cycles<=0;pairs_completed<=0;max_display_burst<=0;display_bursts<=0;npu_bursts<=0;max_npu_burst<=0;axi_frame_vs_q<=0;
            write_bvalid<=0;capture_write_bursts<=0;peer_write_bursts<=0;max_capture_aw_wait<=0;capture_aw_wait<=0;capture_write_beats<=0;peer_write_beats<=0;
            display_ar_wait<=0;max_display_ar_wait<=0;npu_ar_wait<=0;max_npu_ar_wait<=0;
            for(int i=0;i<2048;i++)begin pair_started[i]<=0;pair_done[i]<=0;pair_start_cycle[i]<=0;end
        end else begin
            axi_cycle_count<=axi_cycle_count+1;
            if(turnaround_remaining!=0)turnaround_remaining<=turnaround_remaining-1;
            if(mem_req.arvalid&&mem_rsp.arready)begin
                if(last_dir_valid&&last_dir_write)turnaround_remaining<=4;
                last_dir_valid<=1;last_dir_write<=0;
            end
            if(mem_req.awvalid&&mem_rsp.awready)begin
                if(last_dir_valid&&!last_dir_write)turnaround_remaining<=4;
                last_dir_valid<=1;last_dir_write<=1;
            end
            if(WRITE_COMPETITOR && capture_req.awvalid && !rsp[2].awready)capture_aw_wait<=capture_aw_wait+1;
            if(WRITE_COMPETITOR && capture_req.awvalid && rsp[2].awready)begin
                if(capture_aw_wait>max_capture_aw_wait)max_capture_aw_wait<=capture_aw_wait;
                capture_aw_wait<=0;
                capture_write_bursts<=capture_write_bursts+1;
            end
            if(req[0].arvalid && !rsp[0].arready)display_ar_wait<=display_ar_wait+1;
            else begin
                if(req[0].arvalid && display_ar_wait>max_display_ar_wait)max_display_ar_wait<=display_ar_wait;
                display_ar_wait<=0;
            end
            if(req[1].arvalid && !rsp[1].arready)npu_ar_wait<=npu_ar_wait+1;
            else begin
                if(req[1].arvalid && npu_ar_wait>max_npu_ar_wait)max_npu_ar_wait<=npu_ar_wait;
                npu_ar_wait<=0;
            end
            if(PEER_WRITE_COMPETITOR && peer_wr_req.awvalid && rsp[3].awready)peer_write_bursts<=peer_write_bursts+1;
            if(WRITE_COMPETITOR && mem_req.wvalid && mem_rsp.wready && mem_req.wlast)write_bvalid<=1;
            if(WRITE_COMPETITOR && mem_rsp.bvalid && mem_req.bready)write_bvalid<=0;
            if(WRITE_COMPETITOR && req[2].wvalid && rsp[2].wready)capture_write_beats<=capture_write_beats+1;
            if(PEER_WRITE_COMPETITOR && req[3].wvalid && rsp[3].wready)peer_write_beats<=peer_write_beats+1;
            axi_frame_vs_q<=dut.in_vs;
            if(dut.in_vs&&!axi_frame_vs_q)
                for(int i=0;i<2048;i++)begin pair_started[i]<=0;pair_done[i]<=0;pair_start_cycle[i]<=0;end
            if(dut.row_start)begin
                if(pair_started[dut.row_y]==0)pair_start_cycle[dut.row_y]<=axi_cycle_count;
                pair_started[dut.row_y][dut.row_source]<=1;
            end
            if(dut.row_done)begin
                pair_done[dut.row_y][dut.row_source]<=1;
                if(pair_done[dut.row_y][!dut.row_source])begin
                    pair_latency=axi_cycle_count-pair_start_cycle[dut.row_y];
                    if(pair_latency>max_pair_cycles)max_pair_cycles<=pair_latency;
                    pairs_completed<=pairs_completed+1;
                end
            end
            if(stall_remaining!=0)stall_remaining<=stall_remaining-1;
            else begin
                if(rdelay!=0)rdelay<=rdelay-1;
                if(mem_req.arvalid&&mem_rsp.arready)begin
                    queued_addr[queue_tail]<=mem_req.araddr;queued_left[queue_tail]<=mem_req.arlen+1'b1;
                    queue_tail<=!queue_tail;
                    if(queue_count==0)rdelay<=READ_GAP;
                    if(mem_req.araddr[31:28]==4'h1||mem_req.araddr[31:28]==4'h2)begin
                        display_bursts<=display_bursts+1;
                        if(int'(mem_req.arlen)+1>max_display_burst)max_display_burst<=int'(mem_req.arlen)+1;
                        display_row=int'((mem_req.araddr-(mem_req.araddr[31:28]==4'h2 ? BASE_B : BASE_A))/STRIDE);
                        display_col=int'(((mem_req.araddr-(mem_req.araddr[31:28]==4'h2 ? BASE_B : BASE_A))%STRIDE)/2);
                        if(display_row<0||display_row>=SRC_H||display_col<0||display_col>=(STRIDE/2))
                            $fatal(1,"Display DMA address outside source: addr=%h row=%0d col=%0d source=%0dx%0d",mem_req.araddr,display_row,display_col,SRC_W,SRC_H);
                    if(STALL_ONCE && mem_req.araddr[31:28]==4'h1 && display_row<8)
                        $display("STALL_CANDIDATE frame=%0d row=%0d addr=%h cycle=%0d",vs_count,display_row,mem_req.araddr,axi_cycle_count);
                    end
                    if(mem_req.araddr[31:28]==4'h3)begin
                        npu_bursts<=npu_bursts+1;
                        if(int'(mem_req.arlen)+1>max_npu_burst)max_npu_burst<=int'(mem_req.arlen)+1;
                    end
                    if(STALL_ONCE && !stalled && vs_count==2 &&
                       mem_req.araddr[31:28]==1 && (mem_req.araddr-BASE_A)/STRIDE==(SRC_H>2 ? SRC_H-3 : SRC_H-1))begin
                        stall_remaining<=12000;stalled<=1;
                        $display("INJECT DDR service overdeadline at frame=%0d source_row=%0d cycles=%0d",vs_count,(mem_req.araddr-BASE_A)/STRIDE,axi_cycle_count);
                    end
                end
                if(mem_rsp.rvalid&&mem_req.rready)begin
                    if(queued_left[queue_head]==1)queue_head<=!queue_head;
                    else begin queued_left[queue_head]<=queued_left[queue_head]-1'b1;queued_addr[queue_head]<=queued_addr[queue_head]+16;end
                    rdelay<=READ_GAP;
                end
                case({mem_req.arvalid&&mem_rsp.arready,mem_rsp.rvalid&&mem_req.rready&&mem_rsp.rlast})
                    2'b10:queue_count<=queue_count+1;
                    2'b01:queue_count<=queue_count-1;
                    default:begin end
                endcase
            end
        end
    end


    // The real model transport, not an always-ready synthetic NPU reader.
    logic load_valid=0,load_ready,load_done,load_error,weight_busy;
    logic read_valid,read_ready,data_valid,data_ready,read_done,read_error;
    logic [31:0] read_address,model_araddr;
    logic [15:0] read_length;
    logic [127:0] read_data;
    logic [7:0] model_arlen;
    logic model_arvalid,model_rready;
    logic [11:0] reload_addr;
    logic [39:0] reload_data;
    logic reload_valid;
    ngm_weight_dma weight(
        .clk(axi_clk),.reset(!axi_rst_n),.abort(1'b0),
        .scratch_write(1'b0),.scratch_value(),
        .start_valid(load_valid),.start_ready(load_ready),.start_address(32'h30000000),
        .done(load_done),.error(load_error),.busy(weight_busy),
        .read_valid,.read_ready,.read_address,.read_length,
        .read_data_valid(data_valid),.read_data_ready(data_ready),.read_data,.read_done,.read_error,
        .reload_valid,.reload_ready(1'b1),.reload_addr,.reload_data);
    ngm_axi_master model_bus(
        .clk(axi_clk),.reset(!axi_rst_n),.abort(1'b0),
        .read_valid,.read_ready,.read_address,.read_length,.read_data_valid(data_valid),
        .read_data_ready(data_ready),.read_data,.read_keep(),.read_last(),.read_done,.read_error,
        .write_valid(1'b0),.write_ready(),.write_address(32'd0),.write_length(16'd0),
        .write_data_valid(1'b0),.write_data_ready(),.write_data(128'd0),.write_keep(16'd0),
        .write_done(),.write_error(),.idle(),
        .m_axi_arid(),.m_axi_araddr(model_araddr),.m_axi_arlen(model_arlen),
        .m_axi_arsize(),.m_axi_arburst(),.m_axi_arvalid(model_arvalid),.m_axi_arready(rsp[1].arready),
        .m_axi_rid(rsp[1].rid),.m_axi_rdata(rsp[1].rdata),.m_axi_rresp(rsp[1].rresp),
        .m_axi_rlast(rsp[1].rlast),.m_axi_rvalid(rsp[1].rvalid),.m_axi_rready(model_rready),
        .m_axi_awid(),.m_axi_awaddr(),.m_axi_awlen(),.m_axi_awsize(),.m_axi_awburst(),.m_axi_awvalid(),
        .m_axi_awready(1'b0),.m_axi_wdata(),.m_axi_wstrb(),.m_axi_wlast(),.m_axi_wvalid(),.m_axi_wready(1'b0),
        .m_axi_bid(4'd1),.m_axi_bresp(2'd0),.m_axi_bvalid(1'b0),.m_axi_bready());
    always_comb begin
        fake_npu_req='0;
        fake_npu_req.araddr=model_araddr;fake_npu_req.arlen=model_arlen;
        fake_npu_req.arsize=4;fake_npu_req.arburst=1;
        fake_npu_req.arvalid=model_arvalid;fake_npu_req.rready=model_rready;
    end
    integer model_items=0;
    logic model_finished=0;
    always @(posedge axi_clk)begin
        if(reload_valid)model_items<=model_items+1;
        if(load_done)begin
            if(load_error||model_items!=2560)$fatal(1,"model transport failed items=%0d",model_items);
            model_finished<=1;
            $display("MODEL_LOAD_DONE items=%0d",model_items);
        end
    end
    initial begin
        if(MERGE_COMPETITOR)begin
        wait(vs_count==3);wait(dut.in_de&&dut.x==0&&dut.y==2);
        @(negedge axi_clk);load_valid=1;
        do @(posedge axi_clk);while(!load_ready);
        @(negedge axi_clk);load_valid=0;
        $display("MODEL_LOAD_START during visible raster");
        end
    end

    // Camera producer uses the actual 16-beat AW contract.  A second client
    // continuously offers the actual 64-beat peer maximum.  Requests and data
    // remain stable through backpressure; each next AW waits for B completion.
    initial begin
        capture_req='0;
        if(WRITE_COMPETITOR)begin
            wait(axi_rst_n);
            forever begin
                @(negedge axi_clk);
                capture_req.awid=4'h2;capture_req.awaddr=32'h4000_0000;
                capture_req.awlen=8'd15;capture_req.awsize=3'd4;capture_req.awburst=2'd1;
                capture_req.awvalid=1;
                do @(posedge axi_clk); while(!rsp[2].awready);
                @(negedge axi_clk);capture_req.awvalid=0;capture_req.wvalid=1;
                capture_req.wdata=128'hcafe0000_00000000_00000000_00000000;
                for(integer beat=0;beat<16;beat++)begin
                    capture_req.wlast=(beat==15);
                    do @(posedge axi_clk); while(!rsp[2].wready);
                    @(negedge axi_clk);capture_req.wdata=capture_req.wdata+1'b1;
                    if(beat!=15 && CAMERA_BEAT_GAP!=0)begin
                        capture_req.wvalid=0;
                        repeat(CAMERA_BEAT_GAP) @(posedge axi_clk);
                        @(negedge axi_clk);capture_req.wvalid=1;
                    end
                    if(beat==15)capture_req.wvalid=0;
                end
                capture_req.wvalid=0;capture_req.wlast=0;capture_req.bready=1;
                do @(posedge axi_clk); while(!rsp[2].bvalid);
                @(negedge axi_clk);capture_req.bready=0;
            end
        end
    end
    initial begin
        peer_wr_req='0;
        if(PEER_WRITE_COMPETITOR)begin
            wait(axi_rst_n);
            forever begin
                @(negedge axi_clk);
                peer_wr_req.awid=4'h3;peer_wr_req.awaddr=32'h5000_0000;
                peer_wr_req.awlen=8'd63;peer_wr_req.awsize=3'd4;peer_wr_req.awburst=2'd1;
                peer_wr_req.awvalid=1;
                do @(posedge axi_clk); while(!rsp[3].awready);
                @(negedge axi_clk);peer_wr_req.awvalid=0;peer_wr_req.wvalid=1;
                peer_wr_req.wdata=128'hbeef0000_00000000_00000000_00000000;
                for(integer beat=0;beat<64;beat++)begin
                    peer_wr_req.wlast=(beat==63);
                    do @(posedge axi_clk); while(!rsp[3].wready);
                    @(negedge axi_clk);peer_wr_req.wdata=peer_wr_req.wdata+1'b1;
                end
                peer_wr_req.wvalid=0;peer_wr_req.wlast=0;peer_wr_req.bready=1;
                do @(posedge axi_clk); while(!rsp[3].bvalid);
                @(negedge axi_clk);peer_wr_req.bready=0;
            end
        end
    end

    task automatic csr_write(input logic [11:0] addr,input logic [31:0] data);
        @(negedge cfg_clk);
        cfg_valid=1;cfg_write=1;cfg_addr=addr;cfg_wdata=data;cfg_wstrb=4'hf;
        #1;
        if(cfg_error) $fatal(1,"CSR write rejected addr=%h",addr);
        @(posedge cfg_clk);
        @(negedge cfg_clk);
        cfg_valid=0;cfg_write=0;
        @(negedge cfg_clk);
    endtask

    // Expected content of the scene at (x,y): the compositor draws white on the
    // scene border and on the wipe seam, and one source's mapped pixel elsewhere.
    integer mode_tb=2,wipe_tb=H_ACTIVE/2;
    function automatic [15:0] expect_pixel(input integer x,input integer y);
        integer src,col;
        begin
            if(mode_tb==2) begin
                src=(x<wipe_tb) ? 0 : 1;
                col=x;
                expect_pixel=16'h4000+16'h2000*16'(src)+16'h0080*16'(y*STEP_Y/65536)+16'(SOURCE_X+col*STEP_X/65536)+generation();
            end else if(mode_tb==3) begin
                src=(x<H_ACTIVE/2) ? 0 : 1;
                col=(x<H_ACTIVE/2) ? x : x-H_ACTIVE/2;
                expect_pixel=16'h4000+16'h2000*16'(src)+16'h0080*16'(y*STEP_Y/65536)+16'(SOURCE_X+col*STEP_X/65536)+generation();
            end else begin
                src=mode_tb;
                expect_pixel=16'h4000+16'h2000*16'(src)+16'h0080*16'(y*STEP_Y/65536)+16'(SOURCE_X+x*STEP_X/65536)+generation();
            end
        end
    endfunction

    integer checks=0,fails=0;
    // The compositor output for the pixel presented in cycle N appears in cycle
    // N+1, so sample the coordinates one cycle before comparing.
    logic [11:0] cx0=0,cy0=0,cx=0,cy=0;
    logic cde0=0,cde=0;
    always_ff @(posedge pix_clk or negedge pix_rst_n) begin
        if(!pix_rst_n) begin cx0<=0;cy0<=0;cde0<=0;cx<=0;cy<=0;cde<=0;end
        else begin cx0<=dut.x;cy0<=dut.y;cde0<=dut.in_de;cx<=cx0;cy<=cy0;cde<=cde0;end
    end
    always_ff @(posedge pix_clk or negedge pix_rst_n) begin
        if(!pix_rst_n) begin vs_q<=0;vs_count<=0;end
        else begin vs_q<=dut.in_vs;if(dut.in_vs && !vs_q) vs_count<=vs_count+1;end
    end
    always @(negedge pix_clk)begin
        if(GEOMETRY_SWITCH&&geometry_switch_waiting)begin
            if(dut.in_vs)geometry_vs_observed=1;
            if(dut.source_width==1280&&dut.source_height==6&&dut.source_x==16&&dut.source_y==1&&
               dut.dest_x==4&&dut.dest_y==2&&dut.dest_width==1912&&dut.dest_height==4&&
               dut.stride_a==2592&&dut.stride_b==2592&&dut.x_step==43863&&dut.y_step==109227)begin
                if(!geometry_vs_observed)$fatal(1,"geometry bundle changed before a VS boundary");
                if(!geometry_new_seen)begin geometry_switches=geometry_switches+1;geometry_new_seen=1;end
            end else if(!(dut.source_width==SRC_W&&dut.source_height==SRC_H&&dut.source_x==SOURCE_X&&dut.source_y==0&&
                          dut.dest_x==0&&dut.dest_y==0&&dut.dest_width==H_ACTIVE&&dut.dest_height==V_ACTIVE&&
                          dut.stride_a==STRIDE&&dut.stride_b==STRIDE&&dut.x_step==STEP_X&&dut.y_step==STEP_Y))
                $fatal(1,"mixed old/new display geometry observed while waiting for VS commit: src=%0d,%0d crop=%0d,%0d dest=%0d,%0d,%0d,%0d stride=%0d/%0d step=%0d/%0d vs=%b applied=%b",dut.source_width,dut.source_height,dut.source_x,dut.source_y,dut.dest_x,dut.dest_y,dut.dest_width,dut.dest_height,dut.stride_a,dut.stride_b,dut.x_step,dut.y_step,dut.in_vs,dut.config_applied);
        end
    end
    // End-to-end prefetch deadline starts at the renderer's pixel-domain line
    // decision and ends only after AXI row data has crossed back to the pixel
    // domain and the cache's registered tag says the row is published.
    always_ff @(posedge pix_clk or negedge pix_rst_n)begin
        if(!pix_rst_n)begin
            pix_cycle_count<=0;max_cache_deadline_a<=0;max_cache_deadline_b<=0;
            cache_deadline_a_samples<=0;cache_deadline_b_samples<=0;
            last_deadline_a_y<=-1;last_deadline_b_y<=-1;
            for(integer yidx=0;yidx<2048;yidx++)begin
                cache_issue_a[yidx]<=-1;cache_issue_b[yidx]<=-1;
                cache_ready_a[yidx]<=-1;cache_ready_b[yidx]<=-1;
            end
        end else begin
            pix_cycle_count<=pix_cycle_count+1;
            if(dut.in_de&&dut.x==0&&dut.y>=dut.dest_y&&dut.y<dut.dest_y+dut.dest_height)begin
                if(dut.fetch_enable_a_q && dut.next_source_y<SRC_H &&
                   !((dut.cache_a_rows_valid[0]&&dut.cache_a_y0==dut.next_source_y)||
                     (dut.cache_a_rows_valid[1]&&dut.cache_a_y1==dut.next_source_y)))
                    cache_issue_a[dut.next_source_y]<=pix_cycle_count;
                if(dut.fetch_enable_b_q && dut.next_source_y<SRC_H &&
                   !((dut.cache_b_rows_valid[0]&&dut.cache_b_y0==dut.next_source_y)||
                     (dut.cache_b_rows_valid[1]&&dut.cache_b_y1==dut.next_source_y)))
                    cache_issue_b[dut.next_source_y]<=pix_cycle_count;
            end
            if(dut.cache_a_rows_valid[0]&&cache_issue_a[dut.cache_a_y0]>=0&&cache_ready_a[dut.cache_a_y0]<0)
                cache_ready_a[dut.cache_a_y0]<=pix_cycle_count;
            if(dut.cache_a_rows_valid[1]&&cache_issue_a[dut.cache_a_y1]>=0&&cache_ready_a[dut.cache_a_y1]<0)
                cache_ready_a[dut.cache_a_y1]<=pix_cycle_count;
            if(dut.cache_b_rows_valid[0]&&cache_issue_b[dut.cache_b_y0]>=0&&cache_ready_b[dut.cache_b_y0]<0)
                cache_ready_b[dut.cache_b_y0]<=pix_cycle_count;
            if(dut.cache_b_rows_valid[1]&&cache_issue_b[dut.cache_b_y1]>=0&&cache_ready_b[dut.cache_b_y1]<0)
                cache_ready_b[dut.cache_b_y1]<=pix_cycle_count;
            if(dut.in_de&&dut.src_a_req&&dut.src_a_y<SRC_H&&cache_issue_a[dut.src_a_y]>=0&&dut.src_a_y!=last_deadline_a_y)begin
                last_deadline_a_y<=dut.src_a_y;
                if(cache_ready_a[dut.src_a_y]<0 &&
                   !((dut.cache_a_rows_valid[0]&&dut.cache_a_y0==dut.src_a_y)||
                     (dut.cache_a_rows_valid[1]&&dut.cache_a_y1==dut.src_a_y)) &&
                   !EXPECT_UNDERFLOW)begin
                    $display("ROW_DEADLINE_A y=%0d cache=%b/%0d,%b/%0d issue=%0d cmd=%0d busy=%b pending=%b frame=%b xy=%0d,%0d",dut.src_a_y,dut.cache_a_rows_valid[0],dut.cache_a_y0,dut.cache_a_rows_valid[1],dut.cache_a_y1,cache_issue_a[dut.src_a_y],dut.cmd_a_y,dut.cmd_a_busy,dut.pending_a,dut.frame_load_pending[0],dut.x,dut.y);
                    $fatal(1,"A row %0d reached demand before cache publication",dut.src_a_y);
                end
                else begin
                    if(((cache_ready_a[dut.src_a_y]>=0 ? cache_ready_a[dut.src_a_y] : pix_cycle_count)-cache_issue_a[dut.src_a_y])>max_cache_deadline_a)
                        max_cache_deadline_a<=(cache_ready_a[dut.src_a_y]>=0 ? cache_ready_a[dut.src_a_y] : pix_cycle_count)-cache_issue_a[dut.src_a_y];
                    cache_deadline_a_samples<=cache_deadline_a_samples+1;
                end
            end
            if(dut.in_de&&dut.src_b_req&&dut.src_b_y<SRC_H&&cache_issue_b[dut.src_b_y]>=0&&dut.src_b_y!=last_deadline_b_y)begin
                last_deadline_b_y<=dut.src_b_y;
                if(cache_ready_b[dut.src_b_y]<0 &&
                   !((dut.cache_b_rows_valid[0]&&dut.cache_b_y0==dut.src_b_y)||
                     (dut.cache_b_rows_valid[1]&&dut.cache_b_y1==dut.src_b_y)) &&
                   !EXPECT_UNDERFLOW)begin
                    $display("ROW_DEADLINE_B y=%0d cache=%b/%0d,%b/%0d issue=%0d cmd=%0d busy=%b pending=%b frame=%b xy=%0d,%0d",dut.src_b_y,dut.cache_b_rows_valid[0],dut.cache_b_y0,dut.cache_b_rows_valid[1],dut.cache_b_y1,cache_issue_b[dut.src_b_y],dut.cmd_b_y,dut.cmd_b_busy,dut.pending_b,dut.frame_load_pending[1],dut.x,dut.y);
                    $fatal(1,"B row %0d reached demand before cache publication",dut.src_b_y);
                end
                else begin
                    if(((cache_ready_b[dut.src_b_y]>=0 ? cache_ready_b[dut.src_b_y] : pix_cycle_count)-cache_issue_b[dut.src_b_y])>max_cache_deadline_b)
                        max_cache_deadline_b<=(cache_ready_b[dut.src_b_y]>=0 ? cache_ready_b[dut.src_b_y] : pix_cycle_count)-cache_issue_b[dut.src_b_y];
                    cache_deadline_b_samples<=cache_deadline_b_samples+1;
                end
            end
        end
    end
    always @(negedge pix_clk) begin
        if(cde && debug_de) begin
            if((ONE_PASS && (vs_count==3 || (EXPECT_UNDERFLOW&&vs_count==2))) ||
               (!ONE_PASS && ((vs_count>=3 && vs_count<6) || (vs_count>=7 && vs_count<9) ||
               (vs_count>=10 && vs_count<12) || (vs_count>=13 && vs_count<15)))) begin
                checks=checks+1;
                if(EXPECT_UNDERFLOW&&((dut.req_a_q&&!dut.cache_a_valid)||(dut.req_b_q&&!dut.cache_b_valid)))begin
                    if(vs_count==2)underflow_frame2=underflow_frame2+1;
                    if(vs_count==3)underflow_frame3=underflow_frame3+1;
                    if(debug_rgb565!==dut.overlay_q)fails=fails+1;
                end else if(debug_rgb565!==expect_pixel(cx,cy)) begin
                    fails=fails+1;
                    if(fails<8)begin
                        $display("MISMATCH mode=%0d x=%0d y=%0d got=%h exp=%h",
                            mode_tb,cx,cy,debug_rgb565,expect_pixel(cx,cy));
                        $display("CACHE A valid=%b tags=%0d/%0d B valid=%b tags=%0d/%0d req=%b%b ready=%b%b",
                            dut.cache_a_rows_valid,dut.cache_a_y0,dut.cache_a_y1,
                            dut.cache_b_rows_valid,dut.cache_b_y0,dut.cache_b_y1,
                            dut.req_a_q,dut.req_b_q,dut.cache_a_valid,dut.cache_b_valid);
                    end
                end
                if((cx*STEP_X/65536)>=SRC_W||(cy*STEP_Y/65536)>=SRC_H)
                    $fatal(1,"Rendered source coordinate outside configured input x=%0d y=%0d",cx,cy);
                if(cx==0)begin
                    if(cy==0)begin repeated_source_rows=0;skipped_source_rows=0;previous_source_row=0;end
                    else begin
                        if((cy*STEP_Y/65536)==previous_source_row)repeated_source_rows=repeated_source_rows+1;
                        if((cy*STEP_Y/65536)>previous_source_row+1)skipped_source_rows=skipped_source_rows+1;
                        previous_source_row=cy*STEP_Y/65536;
                    end
                end
            end
        end
    end

    initial begin
        // Keep the pixel side in reset while the shadow bank is programmed, so
        // the first commit lands on the first VS edge instead of mid-frame.
        repeat(4) @(negedge cfg_clk);
        cfg_rst_n=1;
        @(negedge cfg_clk);
        csr_write(12'h000,32'd2);              // scene_mode: vertical wipe
        csr_write(12'h004,BASE_A);
        csr_write(12'h008,BASE_B);
        csr_write(12'h00c,32'(SRC_H)<<16|32'(SRC_W));
        csr_write(12'h010,32'(SOURCE_X));
        csr_write(12'h014,32'd0);              // dest x/y
        csr_write(12'h018,32'(V_ACTIVE)<<16|32'(H_ACTIVE));
        csr_write(12'h01c,32'(STRIDE));
        csr_write(12'h020,32'(STRIDE));
        csr_write(12'h024,32'(STEP_X));
        csr_write(12'h028,32'(STEP_Y));
        csr_write(12'h030,32'd0);              // status_ok=0, ui_enable=0
        csr_write(12'h034,32'(wipe_tb));
        csr_write(12'h038,32'd1);              // commit
        repeat(4) @(negedge axi_clk);
        axi_rst_n=1;pix_rst_n=1;
        if(ONE_PASS)begin
            wait(vs_count>=4);
            if(fails!=0)$fatal(1,"single full viewport mismatches=%0d of %0d",fails,checks);
            if(checks<H_ACTIVE*V_ACTIVE)$fatal(1,"only %0d pixels checked for %0dx%0d viewport",checks,H_ACTIVE,V_ACTIVE);
            if(STEP_Y<65536 && repeated_source_rows==0)$fatal(1,"expected repeated source rows were not exercised");
            if(STEP_Y<=65536 && skipped_source_rows!=0)$fatal(1,"non-upscale mapping skipped source rows: %0d",skipped_source_rows);
            if(!EXPECT_UNDERFLOW&&pairs_completed<MAPPED_SOURCE_ROWS-1)$fatal(1,"only %0d complete A/B source rows fetched, expected at least %0d",pairs_completed,MAPPED_SOURCE_ROWS-1);
            if(!EXPECT_UNDERFLOW&&max_pair_cycles>=LINE_CYCLES)$fatal(1,"A/B prefetch exceeded one output-line lead: %0d cycles >= %0d",max_pair_cycles,LINE_CYCLES);
            if(cache_deadline_a_samples<MAPPED_SOURCE_ROWS-1||cache_deadline_b_samples<MAPPED_SOURCE_ROWS-1)
                $fatal(1,"pixel-domain row publication coverage too small A=%0d B=%0d expected >=%0d",cache_deadline_a_samples,cache_deadline_b_samples,MAPPED_SOURCE_ROWS-1);
            if(!EXPECT_UNDERFLOW&&(max_cache_deadline_a>=H_TOTAL||max_cache_deadline_b>=H_TOTAL))
                $fatal(1,"pixel-domain row publish exceeded line deadline A=%0d B=%0d line=%0d",max_cache_deadline_a,max_cache_deadline_b,H_TOTAL);
            if(max_display_burst>64)$fatal(1,"display burst exceeded merge slot contract: %0d beats",max_display_burst);
            if(MERGE_COMPETITOR&&(npu_bursts==0||max_npu_burst>64))$fatal(1,"NPU competitor did not exercise full burst: count=%0d max=%0d",npu_bursts,max_npu_burst);
            if(WRITE_COMPETITOR)begin
                if(capture_write_bursts==0)$fatal(1,"camera writer did not progress: capture=%0d",capture_write_bursts);
                if(capture_write_beats<(capture_write_bursts-1)*16||capture_write_beats>capture_write_bursts*16)
                    $fatal(1,"capture write beat/AW contract mismatch cap=%0d/%0d",capture_write_beats,capture_write_bursts);
                if(max_capture_aw_wait>160)$fatal(1,"capture AW wait exceeded bounded competitor envelope: %0d cycles",max_capture_aw_wait);
            end
            if(PEER_WRITE_COMPETITOR)begin
                if(peer_write_bursts==0)$fatal(1,"peer writer did not progress: peer=%0d",peer_write_bursts);
                if(
                   peer_write_beats<(peer_write_bursts-1)*64||peer_write_beats>peer_write_bursts*64)
                    $fatal(1,"peer write beat/AW contract mismatch peer=%0d/%0d",peer_write_beats,peer_write_bursts);
            end
            if(MERGE_COMPETITOR&&!model_finished)$fatal(1,"model did not finish in tested frame");
            if(axi_error_a||axi_error_b)$fatal(1,"display flagged an AXI protocol error");
            if(CHECK_DIAGNOSTICS)begin
                repeat(4)@(negedge cfg_clk);cfg_valid=1;cfg_write=0;cfg_addr=12'h03c;#1;
                if(EXPECT_UNDERFLOW)begin
                    if(cfg_error||cfg_rdata[1:0]==0||cfg_rdata[3:2]!=0)$fatal(1,"Expected sticky underflow with clean AXI status, got %h error=%b",cfg_rdata,cfg_error);
                    if(underflow_frame2==0||underflow_frame3!=0)$fatal(1,"Expected loss/recovery across adjacent frames, misses=%0d/%0d injected=%b",underflow_frame2,underflow_frame3,stalled);
                    $display("PASS DISPLAY_OVERDEADLINE sticky=%h missing_pixels=%0d recovered_next_frame_misses=%0d",cfg_rdata,underflow_frame2,underflow_frame3);
                end else if(cfg_error||cfg_rdata!==0)$fatal(1,"Display sticky underflow/AXI diagnostics=%h error=%b",cfg_rdata,cfg_error);
            end
            if(CHECK_EVENT_Y)begin
                if(line_y_equiv_samples<V_ACTIVE||line_y_first_samples==0||line_y_last_samples==0)
                    $fatal(1,"x0/x1 mapped-y coverage incomplete samples=%0d first=%0d last=%0d",line_y_equiv_samples,line_y_first_samples,line_y_last_samples);
                $display("PASS DISPLAY_EVENT_Y x0/x1=%0d first=%0d last=%0d switched_lines=%0d",line_y_equiv_samples,line_y_first_samples,line_y_last_samples,geometry_active_line_samples);
            end
            $display("PASS DISPLAY_VIEWPORT source=%0dx%0d dest=%0dx%0d step=%0d/%0d pixels=%0d repeated_rows=%0d skipped_rows=%0d row_pairs=%0d max_pair=%0d/%0d AXI cycles cache_publish=%0d/%0d pix_cycles line=%0d deadline_rows=%0d/%0d display_ar_wait=%0d NPU_ar_wait=%0d display_bursts=%0d max_burst=%0d NPU_bursts=%0d max_npu=%0d capture_aw=%0d peer_aw=%0d camera_aw_wait=%0d",
                SRC_W,SRC_H,H_ACTIVE,V_ACTIVE,STEP_X,STEP_Y,checks,repeated_source_rows,skipped_source_rows,
                pairs_completed,max_pair_cycles,LINE_CYCLES,max_cache_deadline_a,max_cache_deadline_b,H_TOTAL,
                cache_deadline_a_samples,cache_deadline_b_samples,max_display_ar_wait,max_npu_ar_wait,display_bursts,max_display_burst,npu_bursts,max_npu_burst,
                capture_write_bursts,peer_write_bursts,max_capture_aw_wait);
            if(GEOMETRY_SWITCH)begin
                csr_write(12'h00c,(32'd6<<16)|32'd1280);
                csr_write(12'h010,(32'd1<<16)|32'd16);
                csr_write(12'h014,(32'd2<<16)|32'd4);
                csr_write(12'h018,(32'd4<<16)|32'd1912);
                csr_write(12'h01c,32'd2592);csr_write(12'h020,32'd2592);
                csr_write(12'h024,32'd43863);csr_write(12'h028,32'd109227);
                csr_write(12'h034,32'd956);
                geometry_switch_waiting=1;
                csr_write(12'h038,32'd1);
                wait(dut.config_applied==0);wait(dut.config_applied==1);
                repeat(2)@(negedge pix_clk);
                if(geometry_switches!=1)$fatal(1,"VS atomic geometry commit count=%0d",geometry_switches);
                wait(geometry_active_line_samples>=4);
                if(geometry_active_line_samples<4)$fatal(1,"VS-committed crop/scale mapped-y coverage incomplete: %0d/4",geometry_active_line_samples);
                geometry_switch_waiting=0;
                $display("PASS DISPLAY_GEOMETRY_VS_ATOMIC source=1280x6 crop=16,1 stride=2592 dest=1912x4@4,2 step=43863/109227 changes=%0d",geometry_switches);
            end
            $finish;
        end
        // Wipe frames.
        wait(vs_count==6);
        if(fails!=0) $fatal(1,"wipe frame mismatches=%0d of %0d",fails,checks);
        // Side-by-side frames.
        mode_tb=3;
        csr_write(12'h000,32'd3);
        csr_write(12'h038,32'd1);
        wait(vs_count>=9);
        if(fails!=0) $fatal(1,"side-by-side frame mismatches=%0d of %0d",fails,checks);
        mode_tb=0;
        csr_write(12'h000,32'd0);csr_write(12'h038,32'd1);
        wait(vs_count>=12);
        if(fails!=0) $fatal(1,"original frame mismatches=%0d of %0d",fails,checks);
        mode_tb=1;
        csr_write(12'h000,32'd1);csr_write(12'h038,32'd1);
        wait(vs_count>=15);
        if(fails!=0) $fatal(1,"processed frame mismatches=%0d of %0d",fails,checks);
        if(checks<600) $fatal(1,"only %0d pixels checked",checks);
        if(axi_error_a||axi_error_b) $fatal(1,"display flagged an AXI protocol error");
        if(STALL_ONCE && !stalled)$fatal(1,"cross-VS busy scenario was not exercised");
        if(CHECK_DIAGNOSTICS)begin
            repeat(4)@(negedge cfg_clk);
            cfg_valid=1;cfg_write=0;cfg_addr=12'h03c;
            #1;
            if(cfg_error || cfg_rdata!==0)$fatal(1,"Display sticky underflow/AXI diagnostics=%h error=%b",cfg_rdata,cfg_error);
            $display("PASS DISPLAY_DIAGNOSTICS no requested pixel underflow or AXI error since reset");
        end
        $display("PASS DISPLAY_SCENE original=1 processed=1 wipe=1 side_by_side=1 pixels=%0d",checks);
        $finish;
    end
    initial begin #(ONE_PASS ? 50000000 : 12000000); $fatal(1,"timeout"); end
endmodule
