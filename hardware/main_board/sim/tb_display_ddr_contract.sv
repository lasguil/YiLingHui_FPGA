`timescale 1ns/1ps
// Exercise the production merge and AXI/native bridge together. The native
// transport is an ordered, bounded queue; the DDR PHY/CDC is not modelled.
module tb_display_ddr_contract #(parameter PIPELINED=0, RESERVE_ROW=1, FAIR=0);
    import demo_bus_pkg::*;
    logic clk=0,reset=1,urgent=0;
    always #2.7778 clk=~clk;
    axi_req_t req[4],mem_req;
    axi_rsp_t rsp[4],mem_rsp;
    logic idle;
    demo_axi_merge #(.RESERVE_DISPLAY_ROW(RESERVE_ROW),.PIPELINE_DISPLAY(PIPELINED),.URGENT_EMPTY_ONLY(FAIR)) merge(
        .clk,.reset,.ddr_ready(!reset),.display_urgent(urgent),
        .capture_urgent(1'b1),.req,.rsp,.mem_req,.mem_rsp,.idle);
    wire native_en,native_wren,native_end;
    wire [2:0] native_cmd;
    wire [29:0] native_addr;
    wire [127:0] native_wdata;
    wire [15:0] native_mask;
    integer cycle=0,head=0,tail=0,count=0,max_reserved=0;
    integer reads=0,writes=0,checks=0,locked_checks=0,blocked_peers=0;
    logic [31:0] native_queue[512];
    wire native_ready=!reset && cycle%7!=0 && cycle%19!=0;
    wire native_wrdy=!reset && cycle%11!=0;
    wire native_valid=count!=0;
    wire native_push=native_en && native_ready && native_cmd==1;
    wire native_pop=native_valid && native_end;
    function automatic [127:0] pattern(input logic [31:0] addr);
        for(int k=0;k<4;k++)pattern[k*32+:32]=(addr+32'(k)*32'h1234567)^32'hd85b912f;
    endfunction
    axi4_bus_ctl #(.AXI_AW(32),.AXI_DW(128),.MC_DW(128),.CK_RATIO(4),.CMD_QUANTUM(64)) bridge(
        .aclk(clk),.aresetn(!reset),
        .s_axi_awid(mem_req.awid),.s_axi_awaddr(mem_req.awaddr),.s_axi_awlen(mem_req.awlen),
        .s_axi_awsize(mem_req.awsize),.s_axi_awburst(mem_req.awburst),.s_axi_awlock(1'b0),
        .s_axi_awcache(4'd0),.s_axi_awprot(3'd0),.s_axi_awqos(4'd0),
        .s_axi_awvalid(mem_req.awvalid),.s_axi_awready(mem_rsp.awready),
        .s_axi_wdata(mem_req.wdata),.s_axi_wstrb(mem_req.wstrb),.s_axi_wlast(mem_req.wlast),
        .s_axi_wvalid(mem_req.wvalid),.s_axi_wready(mem_rsp.wready),
        .s_axi_bid(mem_rsp.bid),.s_axi_bresp(mem_rsp.bresp),.s_axi_bvalid(mem_rsp.bvalid),.s_axi_bready(mem_req.bready),
        .s_axi_arid(mem_req.arid),.s_axi_araddr(mem_req.araddr),.s_axi_arlen(mem_req.arlen),
        .s_axi_arsize(mem_req.arsize),.s_axi_arburst(mem_req.arburst),.s_axi_arlock(1'b0),
        .s_axi_arcache(4'd0),.s_axi_arprot(3'd0),.s_axi_arqos(4'd0),
        .s_axi_arvalid(mem_req.arvalid),.s_axi_arready(mem_rsp.arready),
        .s_axi_rid(mem_rsp.rid),.s_axi_rdata(mem_rsp.rdata),.s_axi_rresp(mem_rsp.rresp),
        .s_axi_rlast(mem_rsp.rlast),.s_axi_rvalid(mem_rsp.rvalid),.s_axi_rready(mem_req.rready),
        .mc_user_en(native_en),.mc_user_cmd(native_cmd),.mc_user_addr(native_addr),.mc_user_ready(native_ready),
        .mc_user_wren(native_wren),.mc_user_mask(native_mask),.mc_user_wdata(native_wdata),.mc_user_end(native_end),
        .mc_user_wrdy(native_wrdy),.mc_user_rd_valid(native_valid),
        .mc_user_rd_data(pattern(native_queue[head])),.mc_user_rd_end(1'b1),
        .mc_user_ecc_err(1'b0),.mc_init_done(!reset));
    logic was_ar_stalled=0;
    logic [45:0] held_ar;
    logic was_r_stalled=0,was_b_stalled=0;
    logic [134:0] held_r;
    logic [5:0] held_b;
    always @(posedge clk)begin
        if(reset)begin
            cycle<=0;head<=0;tail<=0;count<=0;was_ar_stalled<=0;
            was_r_stalled<=0;was_b_stalled<=0;
        end else begin
            cycle<=cycle+1;
            if(native_push)begin
                if(count==512)$fatal(1,"native queue overflow");
                native_queue[tail]<={2'b0,native_addr}<<1;
                tail<=(tail+1)%512;reads<=reads+1;
            end
            if(native_pop)head<=(head+1)%512;
            case({native_push,native_pop})
                2'b10:count<=count+1;
                2'b01:count<=count-1;
            endcase
            if(native_wren)begin
                if(!native_ready || !native_wrdy || native_cmd!=0 || native_mask!=0)
                    $fatal(1,"invalid native write grant");
                if(native_wdata!==pattern({2'b0,native_addr}<<1))$fatal(1,"native write data/address mismatch");
                writes<=writes+1;
            end
            if(bridge.reserved>max_reserved)max_reserved<=bridge.reserved;
            if(bridge.reserved>248 || bridge.descriptor_count>2 || merge.read_count>2)
                $fatal(1,"read reservation/descriptor overflow");
            if(was_ar_stalled)begin
                if(!mem_req.arvalid || {mem_req.arid,mem_req.araddr,mem_req.arlen,mem_req.arburst}!==held_ar)
                    $fatal(1,"locked AR changed under backpressure/urgency");
                locked_checks<=locked_checks+1;
            end
            was_ar_stalled<=mem_req.arvalid&&!mem_rsp.arready;
            held_ar<={mem_req.arid,mem_req.araddr,mem_req.arlen,mem_req.arburst};
            if(was_r_stalled && (!mem_rsp.rvalid ||
               {mem_rsp.rid,mem_rsp.rdata,mem_rsp.rresp,mem_rsp.rlast}!==held_r))
                $fatal(1,"R response changed under backpressure");
            if(was_b_stalled && (!mem_rsp.bvalid || {mem_rsp.bid,mem_rsp.bresp}!==held_b))
                $fatal(1,"B response changed under backpressure");
            was_r_stalled<=mem_rsp.rvalid&&!mem_req.rready;
            held_r<={mem_rsp.rid,mem_rsp.rdata,mem_rsp.rresp,mem_rsp.rlast};
            was_b_stalled<=mem_rsp.bvalid&&!mem_req.bready;
            held_b<={mem_rsp.bid,mem_rsp.bresp};
            if(RESERVE_ROW && merge.display_urgent_q && !merge.ar_locked && !req[0].arvalid &&
               (req[1].arvalid || req[2].arvalid || req[3].arvalid))begin
                if(mem_req.arvalid)$fatal(1,"new peer AR entered protected row gap");
                blocked_peers<=blocked_peers+1;
            end
        end
    end
    task automatic read_one(input integer client,beats,hold_cycles,input logic [31:0] addr);
        integer got;
        @(negedge clk);
        req[client].arid=4'(client+5);req[client].araddr=addr;
        req[client].arlen=8'(beats-1);req[client].arsize=4;req[client].arburst=1;
        req[client].arvalid=1;req[client].rready=0;
        do @(posedge clk);while(!rsp[client].arready);
        @(negedge clk);req[client].arvalid=0;
        repeat(hold_cycles)@(negedge clk);
        got=0;
        while(got<beats)begin
            req[client].rready=cycle%5!=0 && cycle%17!=0;
            @(posedge clk);
            if(rsp[client].rvalid && req[client].rready)begin
                if(rsp[client].rdata!==pattern(addr+32'(got)*16) || rsp[client].rid!=client+5 ||
                   rsp[client].rresp!=0 || rsp[client].rlast!=(got==beats-1))
                    $fatal(1,"read corruption client=%0d beat=%0d/%0d id=%0d",client,got,beats,rsp[client].rid);
                got++;checks++;
            end
            @(negedge clk);
        end
        req[client].rready=0;
    endtask
    task automatic write_one(input integer client,beats,input logic [31:0] addr);
        @(negedge clk);
        req[client].awid=4'(client+1);req[client].awaddr=addr;
        req[client].awlen=8'(beats-1);req[client].awsize=4;req[client].awburst=1;
        req[client].awvalid=1;req[client].bready=0;
        do @(posedge clk);while(!rsp[client].awready);
        @(negedge clk);req[client].awvalid=0;
        for(int i=0;i<beats;i++)begin
            req[client].wdata=pattern(addr+32'(i)*16);req[client].wstrb='1;
            req[client].wlast=i==beats-1;req[client].wvalid=1;
            do @(posedge clk);while(!rsp[client].wready);
            @(negedge clk);
        end
        req[client].wvalid=0;
        repeat(7)@(negedge clk);
        req[client].bready=1;
        do @(posedge clk);while(!rsp[client].bvalid);
        if(rsp[client].bresp!=0 || rsp[client].bid!=client+1)$fatal(1,"bad write response");
        @(negedge clk);req[client].bready=0;
    endtask
    initial begin
        for(int i=0;i<4;i++)req[i]='0;
        repeat(5)@(negedge clk);reset=0;
        // Fill beyond 248 total accepted beats, with a blocked head consumer.
        fork
            read_one(0,240,1000,32'h10000000);
            begin repeat(20)@(negedge clk);read_one(1,64,0,32'h20000000);end
            begin for(int j=0;j<5;j++)write_one(0,16,32'h30000000+j*256);end
            begin for(int j=0;j<5;j++)write_one(3,64,32'h40000000+j*1024);end
        join
        if(max_reserved!=248)$fatal(1,"reservation watermark not reached: %0d",max_reserved);
        fork
            begin for(int j=0;j<12;j++)read_one(0,j%2 ? 240 : 16,0,32'h10001000+j*4096);end
            begin for(int j=0;j<12;j++)read_one(1,64,0,32'h20001000+j*4096);end
            begin for(int j=0;j<12;j++)read_one(2,8,0,32'h30001000+j*4096);end
            begin for(int j=0;j<12;j++)read_one(3,1,0,32'h40001000+j*4096);end
            begin repeat(1200)begin @(negedge clk);urgent=cycle%73<37;end urgent=0;end
        join
        repeat(20)@(negedge clk);
        if(!idle || count!=0 || bridge.reserved!=0 || bridge.descriptor_count!=0)
            $fatal(1,"did not drain after traffic");
        if(locked_checks==0 || (RESERVE_ROW && blocked_peers==0) || writes!=400 || reads!=checks)
            $fatal(1,"missing protocol coverage locked=%0d protected=%0d writes=%0d reads=%0d/%0d",locked_checks,blocked_peers,writes,reads,checks);
        $display("PASS DDR_CONTRACT read_beats=%0d write_beats=%0d max_reserved=%0d locked_checks=%0d protected_gap_cycles=%0d",checks,writes,max_reserved,locked_checks,blocked_peers);
        if(PIPELINED)begin
            fork
                begin
                    for(integer burst=0;burst<2;burst++)begin
                        @(negedge clk);
                        req[0].arid=4'(9+burst);req[0].araddr=32'h10010000+burst*2048;
                        req[0].arlen=burst==0?127:111;req[0].arsize=4;req[0].arburst=1;req[0].arvalid=1;
                        do @(posedge clk);while(!rsp[0].arready);
                        @(negedge clk);req[0].arvalid=0;
                    end
                end
                begin
                    wait(merge.read_count==2);
                    repeat(150)@(negedge clk);
                    for(integer beat=0;beat<240;)begin
                        @(negedge clk);req[0].rready=cycle%7!=0;
                        @(posedge clk);
                        if(rsp[0].rvalid && req[0].rready)begin
                            if(rsp[0].rdata!==pattern(32'h10010000+beat*16) || rsp[0].rid!=(beat<128?9:10) ||
                               rsp[0].rresp!=0 || rsp[0].rlast!=(beat==127 || beat==239))
                                $fatal(1,"pipelined response corruption beat=%0d",beat);
                            beat++;
                        end
                    end
                    @(negedge clk);req[0].rready=0;
                end
            join
            repeat(10)@(negedge clk);
            if(!idle || count!=0 || bridge.reserved!=0)$fatal(1,"pipelined drain failed");
            $display("PASS DDR_PIPELINE_SAME_CLIENT 2 descriptors 128+112 beats backpressure IDs LAST");
        end
        // Reset with an incomplete long read and native returns in flight;
        // the post-reset client must never see any old descriptor/data.
        @(negedge clk);
        req[0].araddr=32'h10000000;req[0].arlen=239;req[0].arsize=4;
        req[0].arburst=1;req[0].arvalid=1;req[0].rready=0;
        wait(bridge.reserved>=32);
        @(negedge clk);reset=1;
        for(int i=0;i<4;i++)req[i]='0;
        repeat(5)@(negedge clk);reset=0;
        read_one(1,240,0,32'h20000000);
        repeat(10)@(negedge clk);
        if(!idle || count!=0 || bridge.reserved!=0 || bridge.descriptor_count!=0)
            $fatal(1,"post-reset long read did not drain");
        $display("PASS DDR_RESET_INFLIGHT post_reset_read_beats=240");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule

