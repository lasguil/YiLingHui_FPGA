`timescale 1ns/1ps
module tb_bitslip_phase;
  reg clk=0; always #5 clk=~clk;
  reg rst_n, re_start;
  reg [9:0] raw_word;
  wire [9:0] sliced;
  wire frame_fail;
  wire sync_code, pos_sync, bitslip, aligned;
  frame_bitslip fb(.clk(clk),.rst_n(rst_n),.bitslip(bitslip),.data_in(raw_word),.data_out(sliced),.align_fail(frame_fail));
  phasealign_v1 #(.kTimeoutEnd(1024)) pa(.clk(clk),.rst_n(rst_n),.vin(sliced),.re_algin_start(re_start),.sync_code(sync_code),.pos_sync_code(pos_sync),.bitslip(bitslip),.aligned(aligned));
  integer i, offset, c, bitidx, wordidx, bp, sym, b, hi_run, max_hi, event_count, last_switch, stable;
  integer case_cycles=24000;
  reg [3:0] switch_at_start;
  function automatic [9:0] raw_at(input integer cyc, input integer off);
    integer bi, wi, p, s;
    begin
      raw_at=0;
      for(integer j=0;j<10;j=j+1) begin
        bi=cyc*10+off+j;
        wi=(bi/10)%224;
        p=bi%10;
        if(wi<96) s=10'h354; else s=10'h155;
        raw_at[j]=s[p];
      end
    end
  endfunction
  initial begin
    for(offset=0;offset<10;offset=offset+1) begin
      rst_n=0; re_start=0; raw_word=0; hi_run=0; max_hi=0; event_count=0; stable=0; last_switch=0;
      repeat(8) @(negedge clk);
      rst_n=1;
      @(negedge clk); re_start=1;
      @(negedge clk); re_start=0;
      for(i=0;i<case_cycles;i=i+1) begin
        raw_word=raw_at(i,offset);
        @(posedge clk);
        if(pa.bitslip1) begin hi_run=hi_run+1; if(hi_run>max_hi) max_hi=hi_run; end
        else hi_run=0;
        if(pos_sync) event_count=event_count+1;
        if(fb.Output_switch!=last_switch) begin last_switch=fb.Output_switch; stable=0; end
        else stable=stable+1;
        @(negedge clk);
      end
      $display("OFFSET %0d end_switch=%0d aligned=%0b pos_edges=%0d max_bitslip1_width=%0d stable_cycles=%0d fail=%0b",offset,fb.Output_switch,aligned,event_count,max_hi,stable,frame_fail);
    end
    $finish;
  end
endmodule

