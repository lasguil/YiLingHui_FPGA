`timescale 1ns/1ps
module tb_cpu_axi32_ddr128_cdc;
    import demo_bus_pkg::*;
    logic s_clk=0, s_reset=1, m_clk=0, m_reset=1, m_enable=0;
    always #5 s_clk=~s_clk;
    initial begin #1.3; forever #2.7777778 m_clk=~m_clk; end

    logic [7:0] s_awid,s_bid,s_arid,s_rid;
    logic [31:0] s_awaddr,s_wdata,s_araddr,s_rdata;
    logic [7:0] s_awlen,s_arlen;
    logic [2:0] s_awsize,s_arsize;
    logic [1:0] s_awburst,s_arburst,s_bresp,s_rresp;
    logic s_awvalid,s_awready,s_wvalid,s_wready,s_wlast,s_bvalid,s_bready;
    logic [3:0] s_wstrb;
    logic s_arvalid,s_arready,s_rlast,s_rvalid,s_rready;
    axi_req_t m_req;
    axi_rsp_t m_rsp;

    cpu_axi32_ddr128_cdc dut(
        .s_clk(s_clk), .s_reset(s_reset), .m_clk(m_clk), .m_reset(m_reset), .m_enable(m_enable),
        .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen),
        .s_awsize(s_awsize), .s_awburst(s_awburst), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen),
        .s_arsize(s_arsize), .s_arburst(s_arburst), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
        .m_req(m_req), .m_rsp(m_rsp)
    );

    byte unsigned ddr_mem[0:65535];
    byte unsigned golden[0:65535];
    logic [31:0] lfsr=32'h2d35a71b;
    logic awready_q,wready_q,bvalid_q,arready_q,rvalid_q;
    logic wactive,bpending,ractive;
    logic [31:0] waddr_q,raddr_q;
    logic [7:0] wlen_q;
    integer wbeat_q;
    logic [3:0] bdelay_q,rdelay_q;
    logic inject_write_error=0,inject_read_error=0;
    integer test_stage=0;
    logic wide_src_valid=0,wide_src_ready,wide_dst_valid,wide_dst_ready=0;
    logic [144:0] wide_src_data=0,wide_dst_data;
    logic [15:0] wide_strobe_seen=0;

    axi_cdc_mailbox #(.WIDTH(145)) u_wide_mailbox_test (
        .s_reset(s_reset), .s_clk(s_clk), .s_valid(wide_src_valid),
        .s_ready(wide_src_ready), .s_data(wide_src_data), .m_reset(m_reset), .m_clk(m_clk),
        .m_valid(wide_dst_valid), .m_ready(wide_dst_ready), .m_data(wide_dst_data)
    );

    always_comb begin
        m_rsp='0;
        m_rsp.awready=awready_q;
        m_rsp.wready=wready_q;
        m_rsp.bvalid=bvalid_q;
        m_rsp.bid=4'd0;
        m_rsp.bresp=inject_write_error?2'b10:2'b00;
        m_rsp.arready=arready_q;
        m_rsp.rvalid=rvalid_q;
        m_rsp.rid=4'd0;
        m_rsp.rlast=1'b1;
        m_rsp.rresp=inject_read_error?2'b10:2'b00;
        for(integer i=0;i<16;i++) begin
            integer ix; ix=(raddr_q+i)&16'hffff;
            m_rsp.rdata[i*8+:8]=ddr_mem[ix];
        end
    end

    always @(posedge m_clk) begin
        if(s_reset) begin
            lfsr<=32'h2d35a71b;
            awready_q<=0;wready_q<=0;bvalid_q<=0;arready_q<=0;rvalid_q<=0;
            wactive<=0;bpending<=0;ractive<=0;waddr_q<=0;raddr_q<=0;
            wlen_q<=0;wbeat_q<=0;bdelay_q<=0;rdelay_q<=0;
        end else begin
            lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            awready_q<=lfsr[0]&&!wactive&&!bpending;
            wready_q<=lfsr[3]&&wactive;
            arready_q<=lfsr[5]&&!ractive;
            if(m_req.awvalid&&m_rsp.awready) begin
                if(m_req.awid!=0) $fatal(1,"downstream AWID must use merge client-local ID zero");
                if(m_req.awlen!=0||m_req.awsize!=4||m_req.awaddr[3:0]!=0)
                    $fatal(1,"downstream write was not one aligned 128-bit transfer");
                if(m_req.awaddr[11:0]+((m_req.awlen+1)*16)>4096)
                    $fatal(1,"downstream AW crossed 4KiB boundary");
                waddr_q<=m_req.awaddr;wlen_q<=m_req.awlen;wbeat_q<=0;wactive<=1;
            end
            if(m_req.wvalid&&m_rsp.wready) begin
                for(integer k=0;k<16;k++) if(m_req.wstrb[k])
                    ddr_mem[(waddr_q+wbeat_q*16+k)&16'hffff]<=m_req.wdata[k*8+:8];
                if(m_req.wlast!=(wbeat_q==wlen_q)) $fatal(1,"downstream WLAST mismatch");
                if(m_req.wlast) begin wactive<=0;bpending<=1;bdelay_q<=2+lfsr[7:6]; end
                else wbeat_q<=wbeat_q+1;
            end
            if(bpending) begin
                if(bdelay_q!=0)bdelay_q<=bdelay_q-1;
                else bvalid_q<=1;
            end
            if(bvalid_q&&m_req.bready) begin bvalid_q<=0;bpending<=0;end

            if(m_req.arvalid&&m_rsp.arready) begin
                if(m_req.arid!=0) $fatal(1,"downstream ARID must use merge client-local ID zero");
                if(m_req.arlen!=0||m_req.arsize!=4||m_req.araddr[3:0]!=0)
                    $fatal(1,"downstream read was not one aligned 128-bit transfer");
                if(m_req.araddr[11:0]+((m_req.arlen+1)*16)>4096)
                    $fatal(1,"downstream AR crossed 4KiB boundary");
                raddr_q<=m_req.araddr;ractive<=1;rdelay_q<=1+lfsr[9:8];
            end
            if(ractive&&!rvalid_q) begin
                if(rdelay_q!=0)rdelay_q<=rdelay_q-1;
                else if(lfsr[11])rvalid_q<=1;
            end
            if(rvalid_q&&m_req.rready) begin rvalid_q<=0;ractive<=0;end
        end
    end

    function automatic [3:0] strobe_for(input logic [31:0] addr,input logic [2:0] size,input integer beat);
        case(size)
          0:strobe_for=4'b0001<<addr[1:0];
          1:strobe_for=4'b0011<<addr[1:0];
          default:case(beat%4)
            0:strobe_for=4'b1111;1:strobe_for=4'b0101;2:strobe_for=4'b1010;default:strobe_for=4'b0000;
          endcase
        endcase
    endfunction
    function automatic [31:0] data_for(input logic [31:0] addr,input integer beat);
        reg [31:0] v; begin
            for(integer k=0;k<4;k++)v[k*8+:8]=(addr[7:0]+beat*29+k*43)&255;
            data_for=v;
        end
    endfunction

    task automatic cpu_write_burst(input logic [31:0] addr,input logic [2:0] size,
         input logic [1:0] burst,input integer beats,input logic [7:0] id,
         input logic [1:0] expected_resp);
        logic [31:0] beat_addr,data;
        logic [3:0] strb;
        begin
            @(negedge s_clk);s_awid=id;s_awaddr=addr;s_awlen=beats-1;s_awsize=size;s_awburst=burst;s_awvalid=1;
            do @(posedge s_clk); while(!s_awready);
            @(negedge s_clk);s_awvalid=0;
            for(integer n=0;n<beats;n++) begin
                beat_addr=addr+((burst==2'b01)?(n*(1<<size)):0);
                strb=strobe_for(beat_addr,size,n);data=data_for(beat_addr,n);
                s_wdata=data;s_wstrb=strb;s_wlast=(n==beats-1);s_wvalid=1;
                do @(posedge s_clk); while(!s_wready);
                for(integer j=0;j<4;j++) if(strb[j])
                    golden[((beat_addr&32'hffff_fffc)+j)&16'hffff]<=data[j*8+:8];
                @(negedge s_clk);s_wvalid=0;
            end
            s_bready=0;
            do begin @(negedge s_clk);s_bready=lfsr[13];@(posedge s_clk);end while(!s_bvalid||!s_bready);
            if(s_bid!==id||s_bresp!==expected_resp)
                $fatal(1,"B response mismatch id=%h/%h resp=%h/%h",s_bid,id,s_bresp,expected_resp);
            @(negedge s_clk);s_bready=0;
        end
    endtask

    task automatic cpu_read_burst(input logic [31:0] addr,input logic [2:0] size,
         input logic [1:0] burst,input integer beats,input logic [7:0] id,
         input logic [1:0] expected_resp);
        logic [31:0] beat_addr,expected;
        begin
            @(negedge s_clk);s_arid=id;s_araddr=addr;s_arlen=beats-1;s_arsize=size;s_arburst=burst;s_arvalid=1;
            do @(posedge s_clk); while(!s_arready);
            @(negedge s_clk);s_arvalid=0;s_rready=0;
            for(integer n=0;n<beats;n++) begin
                beat_addr=addr+((burst==2'b01)?(n*(1<<size)):0);
                do begin @(negedge s_clk);s_rready=lfsr[15];@(posedge s_clk);end while(!s_rvalid||!s_rready);
                expected={golden[((beat_addr&32'hffff_fffc)+3)&16'hffff],
                          golden[((beat_addr&32'hffff_fffc)+2)&16'hffff],
                          golden[((beat_addr&32'hffff_fffc)+1)&16'hffff],
                          golden[(beat_addr&32'hffff_fffc)&16'hffff]};
                if(s_rid!==id||s_rdata!==expected||s_rresp!==expected_resp||s_rlast!==(n==beats-1))
                    $fatal(1,"R mismatch beat=%0d id=%h/%h data=%h/%h resp=%h/%h last=%b",n,s_rid,id,s_rdata,expected,s_rresp,expected_resp,s_rlast);
            end
            @(negedge s_clk);s_rready=0;
        end
    endtask

    initial begin
        s_awid=0;s_awaddr=0;s_awlen=0;s_awsize=0;s_awburst=1;s_awvalid=0;
        s_wdata=0;s_wstrb=0;s_wlast=0;s_wvalid=0;s_bready=0;
        s_arid=0;s_araddr=0;s_arlen=0;s_arsize=0;s_arburst=1;s_arvalid=0;s_rready=0;
        foreach(ddr_mem[i])begin ddr_mem[i]=(i*7+3)&255;golden[i]=ddr_mem[i];end
        repeat(8)@(negedge s_clk);s_reset=0;m_reset=0;

        test_stage=1;
        fork
            cpu_write_burst(32'h0800,2,2'b01,1,8'hd7,0);
            begin
                repeat(24) @(posedge m_clk);
                if(m_req.awvalid || m_req.wvalid || m_req.arvalid || m_req.bready || m_req.rready)
                    $fatal(1,"DDR request escaped while calibration gate was low");
                @(negedge m_clk); m_enable=1;
            end
        join
        test_stage=2;

        for(integer a=0;a<16;a++) cpu_write_burst(32'h1000+a,0,2'b01,1,8'ha7,0);
        test_stage=3;
        for(integer a=0;a<16;a+=2) cpu_write_burst(32'h1100+a,1,2'b01,1,8'h81,0);
        for(integer a=0;a<16;a+=4) cpu_write_burst(32'h1200+a,2,2'b01,1,8'h36,0);
        cpu_write_burst(32'h1ff0,2,2'b01,8,8'hc3,0); // crosses the 4 KiB page
        cpu_write_burst(32'h1300,2,2'b00,6,8'h5a,0); // FIXED address, partial WSTRB

        for(integer a=32'h1000;a<32'h1020;a+=4) cpu_read_burst(a,2,2'b01,1,8'hd2,0);
        for(integer a=32'h1100;a<32'h1110;a+=4) cpu_read_burst(a,2,2'b01,1,8'h32,0);
        for(integer a=32'h1200;a<32'h1210;a+=4) cpu_read_burst(a,2,2'b01,1,8'hf1,0);
        for(integer a=32'h1000;a<32'h1010;a++) cpu_read_burst(a,0,2'b01,1,8'h63,0);
        for(integer a=32'h1100;a<32'h1110;a+=2) cpu_read_burst(a,1,2'b01,1,8'h2e,0);
        cpu_read_burst(32'h1ff0,2,2'b01,8,8'h6c,0);
        cpu_read_burst(32'h1300,2,2'b00,1,8'hc9,0);
        test_stage=4;

        fork
            cpu_write_burst(32'h3000,2,2'b01,12,8'h9e,0);
            cpu_read_burst(32'h1ff0,2,2'b01,8,8'h74,0);
        join
        test_stage=5;
        cpu_read_burst(32'h3000,2,2'b01,12,8'h44,0);

        inject_write_error=1;cpu_write_burst(32'h4000,2,2'b01,1,8'hb6,2'b10);inject_write_error=0;
        inject_read_error=1;cpu_read_burst(32'h1000,2,2'b01,1,8'h29,2'b10);inject_read_error=0;
        test_stage=6;

        // Reset while an accepted CPU write is parked behind DDR calibration.
        m_enable=0;
        @(negedge s_clk);s_awid=8'h51;s_awaddr=32'h5000;s_awlen=0;s_awsize=2;s_awburst=1;s_awvalid=1;
        do @(posedge s_clk); while(!s_awready);
        @(negedge s_clk);s_awvalid=0;s_wdata=32'hcafe1234;s_wstrb=4'hf;s_wlast=1;s_wvalid=1;
        do @(posedge s_clk); while(!s_wready);
        @(negedge s_clk);s_wvalid=0;
        repeat(12) @(posedge m_clk);
        if(m_req.awvalid||m_req.wvalid) $fatal(1,"parked request escaped before reset");
        @(negedge s_clk);s_reset=1;m_reset=1;
        repeat(5) @(negedge s_clk);
        s_reset=0;
        repeat(3) @(negedge m_clk);m_reset=0;
        repeat(12) @(posedge s_clk);
        if(s_bvalid||s_rvalid) $fatal(1,"reset replayed a parked response");
        m_enable=1;
        repeat(12) @(posedge m_clk);
        if(m_req.awvalid||m_req.wvalid||m_req.arvalid) $fatal(1,"reset replayed a parked DDR request");

        // Reset after the DDR B response crossed back but before CPU consumes it.
        @(negedge s_clk);s_awid=8'h52;s_awaddr=32'h5100;s_awlen=0;s_awsize=2;s_awburst=1;s_awvalid=1;
        do @(posedge s_clk); while(!s_awready);
        @(negedge s_clk);s_awvalid=0;s_wdata=32'h12345678;s_wstrb=4'hf;s_wlast=1;s_wvalid=1;
        do @(posedge s_clk); while(!s_wready);
        @(negedge s_clk);s_wvalid=0;s_bready=0;
        do @(posedge s_clk); while(!s_bvalid);
        @(negedge s_clk);s_reset=1;m_reset=1;
        repeat(5) @(negedge s_clk);
        s_reset=0;
        repeat(3) @(negedge m_clk);m_reset=0;
        repeat(12) @(posedge s_clk);
        if(s_bvalid||s_rvalid) $fatal(1,"reset returned a stale response");
        cpu_write_burst(32'h5200,2,2'b01,1,8'h53,0);
        test_stage=7;

        // Exercise every WSTRB bit and nonzero high WDATA lanes through the
        // full 145-bit mailbox payload under independent random backpressure.
        for(integer t=0;t<64;t++) begin
            @(negedge s_clk);
            wide_src_data[144:17] = {$urandom,$urandom,$urandom,$urandom};
            wide_src_data[16:1] = 16'h0001 << (t%16);
            wide_src_data[0] = t[0];
            wide_strobe_seen |= wide_src_data[16:1];
            wide_src_valid=1;
            do @(posedge s_clk); while(!wide_src_ready);
            @(negedge s_clk);wide_src_valid=0;
            do begin
                @(negedge m_clk);wide_dst_ready=lfsr[2]||lfsr[7];
                @(posedge m_clk);
            end while(!(wide_dst_valid&&wide_dst_ready));
            if(wide_dst_data!==wide_src_data)
                $fatal(1,"wide mailbox payload mismatch beat=%0d got=%h expected=%h",t,wide_dst_data,wide_src_data);
            @(negedge m_clk);wide_dst_ready=0;
        end
        if(wide_strobe_seen!==16'hffff) $fatal(1,"wide mailbox did not exercise every WSTRB lane: %h",wide_strobe_seen);

        $display("PASS: async CPU100/DDR180 CDC, calibration park, full 145-bit mailbox/WSTRB, narrow lanes, burst/page, FIXED/INCR, IDs/errors, concurrent R/W, randomized backpressure, reset recovery");
        $finish;
    end
    initial begin #5000000;$fatal(1,"CDC timeout stage=%0d ready=%b/%b rst=%b%b up=%b%b clk=%b/%b en=%b c_req=%b%b%b sready=%b%b%b awmb=%b/%b wmb=%b/%b mreq=%b%b br=%b%b state=%0d",test_stage,dut.s_domain_ready,dut.m_domain_ready,dut.s_reset_pipe_q,dut.m_reset_pipe_q,dut.m_up_sync2_q,dut.s_up_sync2_q,s_clk,m_clk,m_enable,dut.c_req.awvalid,dut.c_req.wvalid,dut.c_req.arvalid,s_awready,s_wready,s_arready,dut.aw_s_ready,dut.aw_m_valid,dut.w_s_ready,dut.w_m_valid,m_req.awvalid,m_req.wvalid,s_bvalid,s_rvalid,dut.u_cpu_bridge.wstate_q);end
endmodule
