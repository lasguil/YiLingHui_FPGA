`timescale 1ns/1ps
// Compare the actual Efinity mapped cells with RTL, including ROM inference.
module tb_dct_mapped;
 reg clk=0,rst_n=0,in_valid=0,in_last=0;reg signed[11:0]in_data=0;
 always #5 clk=~clk;
 wire rv,mv,rl,ml;wire signed[15:0]rd,md;
 dct_1d reference_dct(clk,rst_n,in_valid,in_data,in_last,rv,rd,rl);
 dct_probe mapped_dct(clk,rst_n,in_valid,in_data,in_last,mv,md,ml);
 int count=0,cycles=0;
 always @(negedge clk)if(rst_n)begin
 cycles++;
 if(rv!==mv || (rv&&({rd,rl}!=={md,ml})))$fatal(1,"Mismatch cycle=%0d reference=%0d/%0d mapped=%0d/%0d count=%0d",cycles,rv,rd,mv,md,count);
 if(rv)count++;
 end
 initial begin
 repeat(4)@(negedge clk);rst_n=1;
 repeat(3)@(negedge clk);
 for(int row=0;row<32;row++)begin
 for(int n=0;n<8;n++)begin in_valid=1;in_data=12'((n*n*17+row*11)%256-128);in_last=(n==7);@(negedge clk);end
 in_valid=0;repeat(8)@(negedge clk);
 end
 in_valid=0;repeat(32)@(negedge clk);
 if(count!=256)$fatal(1,"missing outputs %0d",count);
 $display("PASS: mapped DCT identical across all 256 coefficients");$finish;
 end
endmodule
