`timescale 1ns/1ps
module tb_ddr_bank_integrity #(parameter BANK_LSB=21,BANK_XOR_LSB=-1);
 import demo_bus_pkg::*;
 logic clk=0,rst_n=0;always #2.777777778 clk=~clk;
 axi_req_t req;axi_rsp_t rsp;
 display_controller_timing_model #(.INTEGRITY(1),.BANK_LSB(BANK_LSB),.BANK_XOR_LSB(BANK_XOR_LSB),.COMMAND_DEPTH(256)) dut(.clk,.rst_n,.generation(16'd0),.service_pause(1'b0),.req,.rsp);
 logic [31:0] bases[64];integer writes=0,reads=0;
 function automatic [127:0] pattern(input logic[31:0] a,input integer pass);
  for(integer b=0;b<4;b++)pattern[b*32+:32]=(a*32'h9e3779b1)^(32'hdeadbeef*32'(b+1))^(32'h12345679*32'(pass));
 endfunction
 task automatic put(input logic[31:0] a,input integer pass);
  @(negedge clk);req.awaddr=a;req.awid=3;req.awlen=63;req.awsize=4;req.awburst=1;req.awvalid=1;
  do @(posedge clk);while(!rsp.awready);
  @(negedge clk);req.awvalid=0;
  for(integer k=0;k<64;k++)begin
   req.wvalid=1;req.wlast=k==63;req.wdata=pattern(a+k*16,pass);req.wstrb=pass==0?16'hffff:16'h5aa5;
   do @(posedge clk);while(!rsp.wready);
   @(negedge clk);req.wvalid=0;writes++;
  end
  req.bready=1;do @(posedge clk);while(!rsp.bvalid);
  if(rsp.bresp!=0 || rsp.bid!=3)$fatal(1,"B framing");
  @(negedge clk);req.bready=0;
 endtask
 task automatic get(input logic[31:0] a,input integer pass);
  reg[127:0] expected,other;
  @(negedge clk);req.araddr=a;req.arid=5;req.arlen=63;req.arsize=4;req.arburst=1;req.arvalid=1;
  do @(posedge clk);while(!rsp.arready);
  @(negedge clk);req.arvalid=0;
  for(integer k=0;k<64;k++)begin
   req.rready=0;repeat(k%5)@(negedge clk);req.rready=1;
   do @(posedge clk);while(!rsp.rvalid);
   expected=pattern(a+k*16,0);other=pattern(a+k*16,1);
   if(pass)for(integer b=0;b<16;b++)if((16'h5aa5>>b)&1)expected[b*8+:8]=other[b*8+:8];
   if(rsp.rdata!==expected || rsp.rid!=5 || rsp.rresp!=0 || rsp.rlast!=(k==63))$fatal(1,"PHY readback addr=%h data=%h expected=%h",a+k*16,rsp.rdata,expected);
   @(negedge clk);req.rready=0;reads++;
  end
 endtask
 initial begin
  req='0;repeat(30)@(negedge clk);rst_n=1;
  for(integer n=0;n<64;n++)begin
   bases[n]=(32'(n%8)<<(BANK_LSB+1))+(n/8)*32'h02000000+32'h1000+(n/8)*2048;
   put(bases[n],0);
  end
  for(integer n=63;n>=0;n--)get(bases[n],0);
  for(integer n=0;n<64;n++)begin put(bases[n],1);get(bases[n],1);end
  $display("PASS BANK_PHY_INTEGRITY write_beats=%0d read_beats=%0d all_8_banks_all_high_rows masks backpressure",writes,reads);$finish;
 end
 initial begin #20000000;$fatal(1,"integrity timeout");end
endmodule
