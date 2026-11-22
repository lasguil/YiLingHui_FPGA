`timescale 1ns/1ps
// Native command/return transport model around the production AXI bridge.
// Models backpressure and ordered return capacity; excludes PHY and CDC timing.
module display_native_bridge_model #(parameter integer STRIDE=3840,READ_GAP=2)(
 input logic clk,rst_n,input logic [15:0] generation,
 input demo_bus_pkg::axi_req_t req,output demo_bus_pkg::axi_rsp_t rsp);
 wire native_en,native_wren,native_end;
 wire [2:0] native_cmd;wire [29:0] native_addr;
 wire [127:0] native_wdata;wire [15:0] native_mask;
 integer cycle=0,head=0,tail=0,count=0,delay_count=0;
 logic [31:0] native_queue[512];logic [15:0] native_generation[512];
 wire native_ready=rst_n && cycle%7!=0 && cycle%19!=0;
 wire native_wrdy=rst_n && cycle%11!=0;
 wire native_valid=count!=0 && delay_count==0;
 wire native_push=native_en && native_ready && native_cmd==1;
 wire native_pop=native_valid && native_end;
 function automatic [127:0] memory_at(input logic [31:0] addr,input logic [15:0] gen);
  logic [31:0] off;integer src,y,x;
  for(int k=0;k<8;k++)begin
   src=addr[31:28]==2;off=addr-(src ? 32'h20000000 : 32'h10000000)+2*k;
   y=int'(off/STRIDE);x=int'((off%STRIDE)/2);
   memory_at[k*16+:16]=16'h4000+16'h2000*16'(src)+16'h0080*16'(y)+16'(x)+gen;
  end
 endfunction
    axi4_bus_ctl #(.AXI_AW(32),.AXI_DW(128),.MC_DW(128),.CK_RATIO(4),.CMD_QUANTUM(64)) bridge(
        .aclk(clk),.aresetn(rst_n),
        .s_axi_awid(req.awid),.s_axi_awaddr(req.awaddr),.s_axi_awlen(req.awlen),
        .s_axi_awsize(req.awsize),.s_axi_awburst(req.awburst),.s_axi_awlock(1'b0),
        .s_axi_awcache(4'd0),.s_axi_awprot(3'd0),.s_axi_awqos(4'd0),
        .s_axi_awvalid(req.awvalid),.s_axi_awready(rsp.awready),
        .s_axi_wdata(req.wdata),.s_axi_wstrb(req.wstrb),.s_axi_wlast(req.wlast),
        .s_axi_wvalid(req.wvalid),.s_axi_wready(rsp.wready),
        .s_axi_bid(rsp.bid),.s_axi_bresp(rsp.bresp),.s_axi_bvalid(rsp.bvalid),.s_axi_bready(req.bready),
        .s_axi_arid(req.arid),.s_axi_araddr(req.araddr),.s_axi_arlen(req.arlen),
        .s_axi_arsize(req.arsize),.s_axi_arburst(req.arburst),.s_axi_arlock(1'b0),
        .s_axi_arcache(4'd0),.s_axi_arprot(3'd0),.s_axi_arqos(4'd0),
        .s_axi_arvalid(req.arvalid),.s_axi_arready(rsp.arready),
        .s_axi_rid(rsp.rid),.s_axi_rdata(rsp.rdata),.s_axi_rresp(rsp.rresp),
        .s_axi_rlast(rsp.rlast),.s_axi_rvalid(rsp.rvalid),.s_axi_rready(req.rready),
        .mc_user_en(native_en),.mc_user_cmd(native_cmd),.mc_user_addr(native_addr),.mc_user_ready(native_ready),
        .mc_user_wren(native_wren),.mc_user_mask(native_mask),.mc_user_wdata(native_wdata),.mc_user_end(native_end),
        .mc_user_wrdy(native_wrdy),.mc_user_rd_valid(native_valid),
        .mc_user_rd_data(memory_at(native_queue[head],native_generation[head])),.mc_user_rd_end(1'b1),
        .mc_user_ecc_err(1'b0),.mc_init_done(rst_n));

 always @(posedge clk)begin
  if(!rst_n)begin cycle<=0;head<=0;tail<=0;count<=0;delay_count<=0;end
  else begin
   cycle<=cycle+1;
   if(delay_count!=0)delay_count<=delay_count-1;
   if(native_push)begin
    if(count>=512)$fatal(1,"native display transport overflow");
    native_queue[tail]<={2'b0,native_addr}<<1;
    native_generation[tail]<=generation;tail<=(tail+1)%512;
    if(count==0)delay_count<=READ_GAP;
   end
   if(native_pop)begin head<=(head+1)%512;delay_count<=READ_GAP;end
   case({native_push,native_pop})
    2'b10:count<=count+1;
    2'b01:count<=count-1;
   endcase
   if(bridge.reserved>248)$fatal(1,"native display reservation overflow");
  end
 end
endmodule

