from pathlib import Path
import re
P=Path(__file__).resolve().parents[1]
D=P/'build/x0_read_decouple_20261013/work/project'
repo=next(p for p in P.parents if (p/'AGENTS.md').exists())
ref=(repo/'hardware/v2e_int8_npu_arch_v1/sim/tb/ngm_x0_dma_tb.sv').read_text(encoding='utf-8')
mem=ref[ref.index('    ngm_memory_subsystem memory('):ref.index('    function automatic')]
mem=mem.replace('.code_valid(1\'b0)', '.code_valid(code_valid),.code_in_range(code_x<2)').replace('.code_x(11\'d0)', '.code_x(code_x)').replace('.code_batch(1\'b0)', '.code_batch(code_batch)')
mem=mem.replace('.emit_lo(lo),.emit_hi(hi),.write_center_lo(center_lo),.write_center_hi(center_hi)', ".emit_lo(11'd0),.emit_hi(11'd2),.write_center_lo(11'd0),.write_center_hi(11'd2)")
tb='''`timescale 1ns/1ps
module tb_x0_joint #(parameter bit OLD=0);
import demo_bus_pkg::*;
logic clk=0,reset=1,abort=0;always #2.7778 clk=~clk;
logic start_valid=0;wire start_ready,busy,done,error;
logic [31:0] start_address=32'h4080;logic [10:0] start_row=1,lo=4,hi=134,center_lo=4,center_hi=134;
wire read_valid,read_ready;wire [31:0] read_address;wire [15:0] read_length;
wire read_data_valid,read_done,read_error,read_data_ready;wire [127:0] read_data;
wire scratch_write;wire [127:0] scratch_value;wire dma_valid,dma_ready;
wire [10:0] dma_row,dma_x,dma_center_lo,dma_center_hi;wire [7:0] dma_word;wire [255:0] dma_data;wire dma_begin,dma_last;
int cycles=0,checks=0,commits=0,display_start=-1,display_finish=-1,ar_commands=0,read_stalls=0,consumer_stalls=0;
logic [4:0] layer=5;logic req_valid=0,skip_valid=0;wire req_ready,skip_ready;
logic [10:0] req_x=0,skip_x=0;wire c_valid,d_valid,mem_error;wire [255:0] c_word,d_word;
logic code_valid=0,code_batch=0;logic [10:0] code_x=0;
wire mem_dma_ready;wire commit_gate=1;assign dma_ready=mem_dma_ready;
if(OLD)begin:old_design ngm_x0_dma_legacy dut(.*);end
else begin:new_design ngm_x0_dma dut(.*);end
ngm_weight_dma host_register(.clk,.reset,.abort,.scratch_write,.scratch_value,.start_valid(1'b0),.start_address(32'd0),.read_ready(1'b0),.read_data_valid(1'b0),.read_data,.read_done(1'b0),.read_error(1'b0),.reload_ready(1'b0));
MEMORY
axi_req_t req[4],nreq,mem_req;axi_rsp_t rsp[4],mem_rsp;
logic display_request=0;wire idle;
always_comb begin
 for(int k=0;k<4;k++)req[k]='0;
 req[1]=nreq;req[0].arvalid=display_request;req[0].araddr=32'h9000;
 req[0].arlen=3;req[0].arsize=4;req[0].arburst=1;req[0].rready=1;
end
demo_axi_merge merger(.clk,.reset,.ddr_ready(1'b1),.display_urgent(display_request),.capture_urgent(1'b0),.req,.rsp,.mem_req,.mem_rsp,.idle);
ngm_axi_master master(.clk,.reset,.abort,.read_valid,.read_ready,.read_address,.read_length,.read_data_valid,.read_data_ready,.read_data,.read_keep(),.read_last(),.read_done,.read_error,
 .write_valid(1'b0),.write_address(32'd0),.write_length(16'd0),.write_data_valid(1'b0),.write_data(128'd0),.write_keep(16'd0),
 .m_axi_arid(nreq.arid),.m_axi_araddr(nreq.araddr),.m_axi_arlen(nreq.arlen),.m_axi_arsize(nreq.arsize),.m_axi_arburst(nreq.arburst),.m_axi_arvalid(nreq.arvalid),.m_axi_arready(rsp[1].arready),
 .m_axi_rid(rsp[1].rid),.m_axi_rdata(rsp[1].rdata),.m_axi_rresp(rsp[1].rresp),.m_axi_rlast(rsp[1].rlast),.m_axi_rvalid(rsp[1].rvalid),.m_axi_rready(nreq.rready),
 .m_axi_awid(nreq.awid),.m_axi_awaddr(nreq.awaddr),.m_axi_awlen(nreq.awlen),.m_axi_awsize(nreq.awsize),.m_axi_awburst(nreq.awburst),.m_axi_awvalid(nreq.awvalid),.m_axi_awready(1'b0),
 .m_axi_wdata(nreq.wdata),.m_axi_wstrb(nreq.wstrb),.m_axi_wlast(nreq.wlast),.m_axi_wvalid(nreq.wvalid),.m_axi_wready(1'b0),.m_axi_bid(4'd1),.m_axi_bresp(2'd0),.m_axi_bvalid(1'b0),.m_axi_bready(nreq.bready));
logic head=0,tail=0;int queued=0;
logic [31:0] qaddr[2];logic [8:0] qleft[2];
wire push=mem_req.arvalid&&mem_rsp.arready;
wire pop=mem_rsp.rvalid&&mem_req.rready&&mem_rsp.rlast;
function automatic [255:0] pattern(input int w);
 for(int b=0;b<32;b++)pattern[b*8+:8]=8'((w*31+b*17+7)&127);
endfunction
always_comb begin
 logic [255:0] value;int offset;
 mem_rsp='0;mem_rsp.arready=queued<2&&cycles%7!=0;
 mem_rsp.rvalid=queued!=0&&cycles%5!=0;mem_rsp.rlast=qleft[head]==1;
 offset=int'(qaddr[head]-start_address);value=pattern(offset/32);
 mem_rsp.rdata=qaddr[head]>=32'h9000 ? 128'h5555 : (offset%32==0?value[127:0]:value[255:128]);
end
always @(posedge clk)begin
 cycles<=cycles+1;
 if(reset)begin head<=0;tail<=0;queued<=0;qaddr[0]<=0;qaddr[1]<=0;qleft[0]<=0;qleft[1]<=0;end
 else begin
  if(push)begin
   qaddr[tail]<=mem_req.araddr;qleft[tail]<={1'b0,mem_req.arlen}+1'b1;tail<=!tail;
   if(mem_req.araddr==32'h9000)display_start=cycles;
   else begin ar_commands++;if(!OLD&&mem_req.arlen>1)$fatal(1,"new word burst too long");end
   if({1'b0,mem_req.araddr[11:0]}+({1'b0,mem_req.arlen}+1)*16>4096)$fatal(1,"4KiB crossing");
  end
  if(mem_rsp.rvalid&&mem_req.rready)begin
   qaddr[head]<=qaddr[head]+16;qleft[head]<=qleft[head]-1'b1;
   if(pop)head<=!head;
  end
  case({push,pop})2'b10:queued<=queued+1;2'b01:queued<=queued-1;default:;endcase
  if(scratch_write)display_request<=display_start<0;
  if(rsp[0].arready)display_request<=0;
  if(rsp[0].rvalid&&req[0].rready&&rsp[0].rlast)display_finish=cycles;
  if(rsp[1].rvalid&&!nreq.rready)begin read_stalls++;if(master.r_state_q==2)consumer_stalls++;end
  if(dma_valid&&dma_ready)begin
   if(dma_data!==pattern(commits)||dma_x!==lo+commits||dma_word!==commits||$isunknown(dma_data))$fatal(1,"word/coordinate mismatch");
   commits++;
  end
  if(mem_error)$fatal(1,"C/D protocol error");
  if(cycles>30000)$fatal(1,"timeout");
 end
end
task automatic compute_code(input int x,input bit batch);
 @(negedge clk);code_x=11'(x);code_batch=batch;code_valid=1;
 @(negedge clk);code_valid=0;
endtask
task automatic check(input bit ok,input string msg);
 checks++;if(!ok)$fatal(1,"joint %s",msg);
endtask
initial begin
 repeat(4)@(negedge clk);reset=0;
 fork
  begin
   compute_code(0,0);repeat(5)@(negedge clk);compute_code(0,1);compute_code(1,0);
   repeat(6000)@(negedge clk);compute_code(1,1);
  end
  begin
   repeat(3)@(negedge clk);start_valid=1;do @(posedge clk);while(!start_ready);@(negedge clk);start_valid=0;
   wait(done);check(commits==130&&!error,"complete mirror row");
  end
 join
 repeat(3)@(negedge clk);
 check(display_start>=0&&display_finish>display_start,"display served");
 if(OLD)check(display_finish-display_start>5900,"legacy blocks until C row release");
 else check(display_finish-display_start<100&&consumer_stalls==0,"new bounded display wait / no consumer R stalls");
 for(int w=0;w<130;w++)begin
  layer=4;req_x=lo+11'(w);req_valid=1;do @(posedge clk);while(!req_ready);@(negedge clk);req_valid=0;
  while(!d_valid)@(negedge clk);check(d_word===pattern(w),"D mirror");@(negedge clk);
  layer=5;skip_x=lo+11'(w);skip_valid=1;@(negedge clk);skip_valid=0;
  while(!c_valid)@(negedge clk);check(c_word===pattern(w),"C mirror");@(negedge clk);
 end
 $display("PASS X0 JOINT OLD=%0d commits=%0d checks=%0d cycles=%0d display_wait_cycles=%0d NPU_R_stalls=%0d consumer_stalls=%0d AR=%0d",OLD,commits,checks,cycles,display_finish-display_start,read_stalls,consumer_stalls,ar_commands);
 $finish;
end
endmodule
'''.replace('MEMORY',mem)
(D/'sim/tb_x0_joint.sv').write_text(tb,encoding='utf-8')
print(D/'sim/tb_x0_joint.sv')
