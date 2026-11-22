`timescale 1ns/1ps
module tb_weight_dma_segmented #(parameter bit WRAPPED=0);
    logic clk=0,reset=1,abort=0;
    always #5 clk=~clk;
    logic start_valid=0,start_ready,done,error,busy;
    logic [31:0] start_address=32'h2000_0ff0,read_address;
    logic read_valid,read_ready,read_data_valid,read_data_ready,read_done,read_error;
    logic [15:0] read_length,read_keep;
    logic [127:0] read_data;
    logic reload_valid,reload_ready=0;
    logic [11:0] reload_addr;
    logic [39:0] reload_data;
    logic [31:0] araddr;
    logic [7:0] arlen;
    logic arvalid,arready=0,rvalid=0,rready,rlast=0,idle;
    logic [127:0] rdata=0;
    logic [1:0] rresp=0;
    int left=0,beat_index=0,checks=0,items=0,bursts=0,cycle=0,run=0;
    logic [31:0] burst_address;
    logic held=0;
    logic [39:0] held_data;
    logic [11:0] held_addr;
    generate if(!WRAPPED)begin:g_direct
    ngm_weight_dma dut(.scratch_write(1'b0),.scratch_value(),.*); // 本TB不使用帧X0低拍，只验证装载协议。
    ngm_axi_master axi(.clk(clk),.reset(reset),.abort(abort),
        .read_valid(read_valid),.read_ready(read_ready),.read_address(read_address),.read_length(read_length),
        .read_data_valid(read_data_valid),.read_data_ready(read_data_ready),.read_data(read_data),.read_keep(read_keep),
        .read_done(read_done),.read_error(read_error),.write_valid(1'b0),.write_address(32'b0),.write_length(16'b0),
        .write_data_valid(1'b0),.write_data(128'b0),.write_keep(16'b0),.idle(idle),
        .m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rid(4'b0),.m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready),
        .m_axi_awready(1'b0),.m_axi_wready(1'b0),.m_axi_bid(4'd1),.m_axi_bresp(2'b0),.m_axi_bvalid(1'b0),
        .write_ready(),.write_data_ready(),.write_done(),.write_error(),.read_last(),
        .m_axi_arid(),.m_axi_arsize(),.m_axi_arburst(),.m_axi_awid(),.m_axi_awaddr(),.m_axi_awlen(),
        .m_axi_awsize(),.m_axi_awburst(),.m_axi_awvalid(),.m_axi_wdata(),.m_axi_wstrb(),.m_axi_wlast(),.m_axi_wvalid(),.m_axi_bready());
    end else begin:g_wrapped
        logic load_ok,load_failed;
        assign done=load_ok || load_failed;assign error=load_failed;
        assign busy=u_host.weight_busy;
        ngm_host_if u_host(.scratch_write(1'b0),.scratch_value(),.irq(),
        .clk(clk),
        .reset(reset),
        .csr_valid(1'b0),.csr_write(1'b0),.csr_address(12'd0),
        .csr_wdata(32'd0),.csr_wstrb(4'd0),.csr_ready(),.csr_error(),.csr_rdata(),
        .frame_valid(),
        .model_valid(),
        .frame_ready('0),
        .model_ready('0),
        .frame_width4(),
        .frame_height4(),
        .frame_input_base(),
        .frame_output_base(),
        .frame_x0_base(),
        .model_base(),
        .frame_input_stride(),
        .frame_output_stride(),
        .frame_x0_stride(),
        .busy('0),
        .model_loaded('0),
        .frame_done('0),
        .frame_aborted('0),
        .model_done('0),
        .task_error('0),
        .error_code('0),
        .read_valid('0),
        .read_ready(),
        .read_address('0),
        .read_length('0),
        .read_data_valid(),
        .read_data_ready('0),
        .read_data(),
        .read_keep(),
        .read_last(),
        .read_done(),
        .read_error(),
        .write_valid('0),
        .write_ready(),
        .write_address('0),
        .write_length('0),
        .write_data_valid('0),
        .write_data_ready(),
        .write_data('0),
        .write_keep('0),
        .write_done(),
        .write_error(),
        .idle(idle),
        .m_axi_arid(),
        .m_axi_araddr(araddr),
        .m_axi_arlen(arlen),
        .m_axi_arsize(),
        .m_axi_arburst(),
        .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),
        .m_axi_rid(4'b0),
        .m_axi_rdata(rdata),
        .m_axi_rresp(rresp),
        .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid),
        .m_axi_rready(rready),
        .m_axi_awid(),
        .m_axi_awaddr(),
        .m_axi_awlen(),
        .m_axi_awsize(),
        .m_axi_awburst(),
        .m_axi_awvalid(),
        .m_axi_awready('0),
        .m_axi_wdata(),
        .m_axi_wstrb(),
        .m_axi_wlast(),
        .m_axi_wvalid(),
        .m_axi_wready('0),
        .m_axi_bid(4'd1),
        .m_axi_bresp('0),
        .m_axi_bvalid('0),
        .m_axi_bready(),
        .load_valid(start_valid),
        .load_ready(start_ready),
        .load_address(start_address),
        .load_done(load_ok),
        .load_error(load_failed),
        .reload_valid(reload_valid),
        .reload_ready(reload_ready),
        .reload_addr(reload_addr),
        .reload_data(reload_data),
        .abort(abort)
        );
    end endgenerate
    function automatic logic [7:0] byte_at(input int offset);
        return 8'((offset*37)^(offset>>3)^8'ha6);
    endfunction
    function automatic logic [39:0] item_at(input int index);
        for(int b=0;b<5;b++)item_at[b*8+:8]=byte_at(index*5+b);
    endfunction
    task automatic check(input bit good,input string label);
        checks++;if(!good)$fatal(1,"%s items=%0d",label,items);
    endtask
    always @(negedge clk)if(!reset)begin
        cycle++;
        arready=left==0 && cycle%7!=0;
        reload_ready=cycle%9>2;
        if(left>0 && !rvalid && cycle%5!=0)begin
            for(int b=0;b<16;b++)rdata[b*8+:8]=byte_at(int'(burst_address-start_address)+beat_index*16+b);
            rvalid=1;rlast=left==1;rresp=(run==2 && burst_address==start_address+32'd16 && beat_index==2) ? 2 : 0;
        end
    end
    always @(posedge clk)if(!reset)begin
        if(arvalid && arready)begin
            check(left==0,"one outstanding burst");check(arlen<8,"bounded burst");
            check(int'(araddr[11:0])+(int'(arlen)+1)*16<=4096,"4K boundary");
            left=int'(arlen)+1;burst_address=araddr;beat_index=0;bursts++;
        end
        if(rvalid && rready)begin left--;beat_index++;rvalid<=0;end
        if(held && !abort)check(reload_valid && reload_data===held_data && reload_addr==held_addr,"reload held under pressure");
        held=reload_valid && !reload_ready && !abort;held_data=reload_data;held_addr=reload_addr;
        if(reload_valid && reload_ready)begin
            check(reload_addr==items,"ascending reload address");check(reload_data===item_at(items),"little-endian five bytes across AXI beats");items++;
        end
        if(done)check(items==2560 && idle,"done waits table and AXI completion");
    end
    task automatic launch;
        @(negedge clk);items=0;held=0;start_valid=1;
        do @(posedge clk);while(!start_ready);
        @(negedge clk);start_valid=0;
    endtask
    initial begin
        repeat(3)@(negedge clk);reset=0;
        launch();wait(items>71);@(negedge clk);abort=1;
        repeat(3)@(negedge clk);check(!reload_valid && !done,"abort suppresses partial item");
        wait(idle);@(negedge clk);abort=0;
        run=1;launch();wait(done);@(negedge clk);check(!error,"clean load result");
        run=2;launch();wait(done);@(negedge clk);check(error,"DDR read error recorded");
        $display("TB PASS: WEIGHT_DMA %0d checks %0d bursts",checks,bursts);$finish;
    end
    initial begin #1000000;$fatal(1,"weight timeout");end
endmodule
