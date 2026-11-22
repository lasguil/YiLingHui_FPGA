module tb_axi;
logic  clk,reset,abort;
logic  read_valid;
logic  read_ready;
logic [32-1:0] read_address;
logic [15:0] read_length;
logic  read_data_valid;
logic  read_data_ready;
logic [127:0] read_data;
logic [15:0] read_keep;
logic  read_last,read_done,read_error;
logic  write_valid;
logic  write_ready;
logic [32-1:0] write_address;
logic [15:0] write_length;
logic  write_data_valid;
logic  write_data_ready;
logic [127:0] write_data;
logic [15:0] write_keep;
logic  write_done,write_error,idle;
logic [4-1:0] m_axi_arid;
logic [32-1:0] m_axi_araddr;
logic [7:0] m_axi_arlen;
logic [2:0] m_axi_arsize;
logic [1:0] m_axi_arburst;
logic  m_axi_arvalid;
logic  m_axi_arready;
logic [4-1:0] m_axi_rid;
logic [127:0] m_axi_rdata;
logic [1:0] m_axi_rresp;
logic  m_axi_rlast,m_axi_rvalid;
logic  m_axi_rready;
logic [4-1:0] m_axi_awid;
logic [32-1:0] m_axi_awaddr;
logic [7:0] m_axi_awlen;
logic [2:0] m_axi_awsize;
logic [1:0] m_axi_awburst;
logic  m_axi_awvalid;
logic  m_axi_awready;
logic [127:0] m_axi_wdata;
logic [15:0] m_axi_wstrb;
logic  m_axi_wlast,m_axi_wvalid;
logic  m_axi_wready;
logic [4-1:0] m_axi_bid;
logic [1:0] m_axi_bresp;
logic  m_axi_bvalid;
logic  m_axi_bready;
    ngm_axi_master #(.MAX_READ_BURST(16)) dut(.*);
    int checks=0,tick=0,r_rem=0,w_rem=0,b_delay=0,read_bytes=0,w_sent=0,ar_count=0,aw_count=0;
    int expected_r_addr=0,r_bus_addr=0,w_bus_addr=0,expected_w_addr=0,r_total=0,w_total=0;
    bit block_ar=0,block_aw=0,block_w=0,block_read=0,inject_r=0,inject_b=0;
    logic [44:0] held_ar,held_aw;logic [144:0] held_w;bit was_ar_stall=0,was_aw_stall=0,was_w_stall=0;
    function automatic logic [127:0] bytes_at(input int address);
        logic [127:0] value;for(int i=0;i<16;i++)value[i*8+:8]=8'((address+i)^(address>>7)^(i*29));return value;
    endfunction
    task automatic ck(input bit ok,input string what);checks++;if(!ok)$fatal(1,"AXI TB %s tick=%0d",what,tick);endtask
    always #5 clk=~clk;
    always_comb begin
        m_axi_arready=!block_ar && r_rem==0 && tick%3!=0;
        m_axi_awready=!block_aw && w_rem==0 && !m_axi_bvalid && b_delay==0 && tick%5!=0;
        m_axi_wready=!block_w && w_rem>0 && tick%4!=1;
        m_axi_rvalid=r_rem>0 && tick%4!=0;
        m_axi_rdata=bytes_at(r_bus_addr);m_axi_rid=0;m_axi_rlast=r_rem==1;
        m_axi_rresp=inject_r && r_rem==3 ? 2 : 0;m_axi_bresp=inject_b ? 2 : 0;m_axi_bid=1;
        read_data_ready=!block_read && tick%5!=1;
        write_data_valid=1;write_data=bytes_at(expected_w_addr);
        write_keep=w_sent+16>=w_total && (w_total%16)!=0 ? 16'hffff>>(16-(w_total%16)) : 16'hffff;
    end
    always @(negedge clk)if(!reset)begin
        tick++;ck(tick<30000,"watchdog");
        if(b_delay>0)begin b_delay--;if(b_delay==0)m_axi_bvalid=1;end
    end
    always @(posedge clk)if(!reset)begin
        if(was_ar_stall)ck(m_axi_arvalid && held_ar==={m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst},"AR held under abort/backpressure");
        if(was_aw_stall)ck(m_axi_awvalid && held_aw==={m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst},"AW held under abort/backpressure");
        if(was_w_stall)ck(m_axi_wvalid && held_w==={m_axi_wdata,m_axi_wstrb,m_axi_wlast},"W held under abort/backpressure");
        was_ar_stall=m_axi_arvalid && !m_axi_arready;held_ar={m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst};
        was_aw_stall=m_axi_awvalid && !m_axi_awready;held_aw={m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst};
        was_w_stall=m_axi_wvalid && !m_axi_wready;held_w={m_axi_wdata,m_axi_wstrb,m_axi_wlast};
        if(m_axi_arvalid && m_axi_arready)begin
            ck(m_axi_arlen<16 && m_axi_arsize==4 && m_axi_arburst==1,"actual INCR read burst");
            ck(m_axi_araddr[11:0]+16*(int'(m_axi_arlen)+1)<=4096,"read never crosses 4KiB");
            ck(r_rem==0,"one outstanding read burst");r_rem=int'(m_axi_arlen)+1;r_bus_addr=m_axi_araddr;ar_count++;
        end
        if(read_data_valid && read_data_ready)begin
            ck(!abort && read_data===bytes_at(expected_r_addr),"all read bytes/address order");
            ck(read_last==(read_bytes+16>=r_total),"logical last separate from RLAST");
            ck(read_keep==((read_bytes+16>=r_total && r_total%16!=0) ? (16'hffff>>(16-r_total%16)) : 16'hffff),"tail byte keep");
            read_bytes+=16;expected_r_addr+=16;
        end
        if(m_axi_rvalid && m_axi_rready)begin r_rem--;r_bus_addr+=16;end
        if(m_axi_awvalid && m_axi_awready)begin
            ck(m_axi_awlen<64 && m_axi_awsize==4 && m_axi_awburst==1,"actual INCR write burst");
            ck(m_axi_awaddr[11:0]+16*(int'(m_axi_awlen)+1)<=4096,"write never crosses 4KiB");
            ck(w_rem==0,"one outstanding write burst");w_rem=int'(m_axi_awlen)+1;w_bus_addr=m_axi_awaddr;aw_count++;
        end
        if(m_axi_wvalid && m_axi_wready)begin
            ck(w_bus_addr==expected_w_addr && m_axi_wdata===bytes_at(w_bus_addr),"all write lanes/address order");
            ck(m_axi_wlast==(w_rem==1),"WLAST correct");
            ck(m_axi_wstrb===write_keep,"all byte enables");w_rem--;w_bus_addr+=16;w_sent+=16;expected_w_addr+=16;
            if(w_rem==0)b_delay=7;
        end
        if(m_axi_bvalid && m_axi_bready)m_axi_bvalid=0;
        #1;if(write_done)ck(b_delay==0 && w_rem==0,"done waits actual B response");
    end
    task automatic begin_read(input int addr,n);
        @(negedge clk);expected_r_addr=addr;r_total=n;read_bytes=0;read_address=addr;read_length=n;read_valid=1;
        do @(posedge clk);while(!read_ready);@(negedge clk);read_valid=0;
    endtask
    task automatic begin_write(input int addr,n);
        @(negedge clk);expected_w_addr=addr;w_total=n;w_sent=0;write_address=addr;write_length=n;write_valid=1;
        do @(posedge clk);while(!write_ready);@(negedge clk);write_valid=0;
    endtask
    initial begin
        int before_ar,before_aw;
        clk=0;reset=1;abort=0;read_valid=0;write_valid=0;read_address=0;read_length=0;write_address=0;write_length=0;m_axi_bvalid=0;
        repeat(3)@(posedge clk);@(negedge clk);reset=0;
        fork begin_read('hf80,7001);begin_write('h17ff0,7021);join
        wait(read_done || dut.r_state_q==dut.R_IDLE);wait(write_done || dut.w_state_q==dut.W_IDLE);@(negedge clk);
        ck(read_bytes==((7001+15)/16)*16 && w_sent==((7021+15)/16)*16,"complete long commands");ck(ar_count>4 && aw_count>4,"multiple bursts, not singleton pixel transfers");
        inject_r=1;begin_read('h2000,128);wait(read_done);#1;ck(read_error,"RRESP error sticky");inject_r=0;
        inject_b=1;begin_write('h20000,128);wait(write_done);#1;ck(write_error,"BRESP error sticky");inject_b=0;
        for(int which=0;which<3;which++)begin
            @(negedge clk);abort=0;before_ar=ar_count;before_aw=aw_count;
            block_ar=which==0;block_aw=which==1;block_w=which==2;
            fork begin_read('h3000,3000);begin_write('h21000,3000);join
            case(which)
                0:wait(m_axi_arvalid && !m_axi_arready);
                1:wait(m_axi_awvalid && !m_axi_awready);
                2:wait(m_axi_wvalid && !m_axi_wready);
            endcase
            @(negedge clk);abort=1;repeat(4)@(posedge clk);
            @(negedge clk);block_ar=0;block_aw=0;block_w=0;
            wait(idle);@(negedge clk);
            ck(ar_count==before_ar+1 && aw_count==before_aw+1,"abort drains accepted burst but stops remaining bursts");
            ck(!read_ready && !write_ready,"abort refuses commands");
        end
        @(negedge clk);abort=0;begin_read('h4000,47);wait(read_done);#1;ck(read_bytes==48 && !read_error,"recover and tail read");
        begin_write('h22000,47);wait(write_done);#1;ck(w_sent==48 && !write_error,"recover and tail write");
        $display("AXI TB PASS checks=%0d read_bursts=%0d write_bursts=%0d",checks,ar_count,aw_count);$finish;
    end
endmodule
