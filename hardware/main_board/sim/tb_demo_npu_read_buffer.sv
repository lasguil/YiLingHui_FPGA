`timescale 1ns/1ps
module tb_demo_npu_read_buffer;
 import demo_bus_pkg::*;
 logic clk=0,reset=1;
 always #2.777777778 clk=~clk;
 axi_req_t up,down;
 axi_rsp_t us,ds;
 demo_npu_read_buffer dut(.clk,.reset,.up_req(up),.up_rsp(us),.down_req(down),.down_rsp(ds));
 integer sent=0,got=0,cycles=0,burst=0,refill_bubbles=0;
 logic check=0;
 function automatic [127:0] word(input integer n,b);
  for(integer j=0;j<4;j++)word[j*32+:32]=32'h12340000 ^ (n*157+j*13+b*7919);
 endfunction
 always @(posedge clk)begin
  cycles<=cycles+1;
  if(burst==5 && up.rready && dut.queued!=0 && !dut.front_valid && dut.empty)refill_bubbles++;
  if(check && us.rvalid && up.rready)begin
   if(us.rdata!==word(got,burst) || us.rid!==4'(burst+3) || us.rresp!==2'(got%4) || us.rlast!==(got==((burst==1 || burst==5)?63:7)))
    $fatal(1,"buffer scoreboard failed burst=%0d beat=%0d",burst,got);
   got<=got+1;
  end
  if(cycles>20000)$fatal(1,"buffer timeout");
 end
 task automatic address(input integer n);
  @(negedge clk);up.arvalid=1;up.arlen=n-1;ds.arready=1;
  do @(posedge clk);while(!us.arready);
  @(negedge clk);up.arvalid=0;ds.arready=0;
 endtask
 task automatic produce(input integer n,b);
  for(integer i=0;i<n;i++)begin
   @(negedge clk);ds.rvalid=1;ds.rid=b+3;ds.rdata=word(i,b);ds.rresp=i%4;ds.rlast=i==n-1;
   do @(posedge clk);while(!down.rready);
   sent=sent+1;
  end
  @(negedge clk);ds.rvalid=0;
 endtask
 initial begin
  up='0;ds='0;
  repeat(8)@(negedge clk);reset=0;
  repeat(12)@(negedge clk);
  burst=1;got=0;check=1;address(64);
  // The entire return must retire even while the consumer is stopped.
  produce(64,1);
  if(sent!=64 || got!=0)$fatal(1,"64-beat reservation did not decouple consumer");
  repeat(100)@(negedge clk);
  up.rready=1;
  wait(got==64);repeat(6)@(negedge clk);
  burst=2;got=0;address(8);
  produce(8,2);
  wait(got==8);repeat(6)@(negedge clk);
  burst=5;got=0;up.rready=0;address(64);
  fork
   produce(64,5);
   begin repeat(3)@(negedge clk);up.rready=1;end
  join
  wait(got==64);repeat(6)@(negedge clk);
  $display("BUFFER_REFILL_BUBBLES short_stall=%0d",refill_bubbles);
  if(refill_bubbles!=0)$fatal(1,"extra read latency after a short consumer stall");
  check=0;up.rready=0;address(8);produce(8,3);
  reset=1;repeat(8)@(negedge clk);reset=0;repeat(12)@(negedge clk);
  if(us.rvalid)$fatal(1,"stale buffered data after reset");
  burst=4;got=0;check=1;up.rready=1;address(8);produce(8,4);
  wait(got==8);repeat(5)@(negedge clk);
  $display("PASS NPU_RETURN_BUFFER 64-beat stopped consumer, overlapping push/pop, ID/RESP/LAST, reset");
  $finish;
 end
endmodule
