// Shallow ordered storage. EFX_SRL8 Q is inverted; Q7 is not.
module ddr_slim_fifo #(parameter W=32, DEPTH=8)(
 input wire clk,rst,push,pop,
 input wire [W-1:0] din,
 output wire [W-1:0] dout,
 output reg [$clog2(DEPTH):0] count
);
 localparam N=DEPTH/8;
 wire [$clog2(DEPTH)-1:0] tap=count-1'b1;
 wire [2:0] address=~tap[2:0];
 for(genvar b=0;b<W;b++) begin:g_bit
  wire [N:0] cascade;
  wire [N-1:0] selected;
  assign cascade[0]=~din[b];
  for(genvar s=0;s<N;s++) begin:g_segment
   EFX_SRL8 u_srl(.D(cascade[s]),.A(address),.CLK(clk),.CE(push&&!rst),
                 .Q(selected[s]),.Q7(cascade[s+1]));
  end
  if(N==1) assign dout[b]=selected[0];
  else assign dout[b]=selected[tap[$clog2(DEPTH)-1:3]];
 end
 always @(posedge clk) begin
  if(rst) count<=0;
  else case({push,pop})
   2'b10:count<=count+1'b1;
   2'b01:count<=count-1'b1;
   default:;
  endcase
 end
`ifdef SIM_ASSERT
 always @(posedge clk) if(!rst) begin
  if(push&&count==DEPTH&&!pop) $fatal(1,"slim FIFO overflow");
  if(pop&&count==0) $fatal(1,"slim FIFO underflow");
 end
`endif
endmodule
