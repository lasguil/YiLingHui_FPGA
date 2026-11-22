`timescale 1ns/1ps
// Board A's actual encoder, followed by board B's packet/8b10b decode stages.
// No PHY model or on-board probe; tests the digital protocol contract.
module tb_board_link_dvi;
  reg clk=0,rst=1,de=0,hs=0,vs=0,preamble=0,guard=0;
  always #3.333 clk=~clk;
  reg [23:0] rgb=0;
  wire [9:0] eb,eg,er;
  reg guard_q=0;
  always @(posedge clk)guard_q<=guard;
  wire [9:0] b=guard_q ? 10'h2cc : eb;
  wire [9:0] g=guard_q ? 10'h133 : eg;
  wire [9:0] r=guard_q ? 10'h2cc : er;
  tmds_encode encb(clk,rst,rgb[7:0],hs,vs,de,eb);
  tmds_encode encg(clk,rst,rgb[15:8],preamble,1'b0,de,eg);
  tmds_encode encr(clk,rst,rgb[23:16],1'b0,1'b0,de,er);
  wire ctrl,island,dh,dv,db,dg,dr;
  wire [7:0] rb,rg,rr;
  package_ctrl_v1 pkg(.clk(clk),.i_gdata(g),.i_rdata(r),.i_bdata(b),.ctrl_time(ctrl),.data_island(island),.aux_ch0_o(),.aux_ch1_o(),.aux_ch2_o(),.hs(dh),.vs(dv));
  decoder_v1 decb(.pixelclk(clk),.i_data(b),.pmerdy_int(1'b1),.ctrl_time(ctrl),.pc0(),.pc1(),.pvde(db),.pdatain(rb));
  decoder_v1 decg(.pixelclk(clk),.i_data(g),.pmerdy_int(1'b1),.ctrl_time(ctrl),.pc0(),.pc1(),.pvde(dg),.pdatain(rg));
  decoder_v1 decr(.pixelclk(clk),.i_data(r),.pmerdy_int(1'b1),.ctrl_time(ctrl),.pc0(),.pc1(),.pvde(dr),.pdatain(rr));
  reg check_en=0,prev_de=0;
  reg [23:0] expected[0:40000];
  integer wr=0,rd=0,line_count=0,width=0;
  always @(posedge clk)begin
    if(check_en&&de)begin expected[wr]=rgb;wr=wr+1;end
    #2;
    if(check_en)begin
      if(db!==dg ||db!==dr)$fatal(1,"RGB DE disagreement");
      if(db)begin
        if(rd>=wr)$fatal(1,"extra decoded pixel at %0d",rd);
        if({rr,rg,rb}!==expected[rd])$fatal(1,"pixel %0d got %06h expected %06h",rd,{rr,rg,rb},expected[rd]);
        // During active video the source control values are held constant.
        // Any parser transition here would create a spurious H/V edge (and,
        // downstream, a false line/frame boundary).
        if(dh!==hs || dv!==vs)
          $fatal(1,"sync changed during active video pixel=%0d got hs/vs=%b%b expected=%b%b token=%03h/%03h/%03h",rd,dh,dv,hs,vs,b,g,r);
        rd=rd+1;width=width+1;
      end
      if(prev_de&&!db)begin
        if(width!=1920)$fatal(1,"line %0d width=%0d",line_count,width);
        line_count=line_count+1;width=0;
      end
      prev_de=db;
    end
  end
  task automatic idle(input integer n,input bit h,input bit v);
    repeat(n)begin @(negedge clk);de=0;hs=h;vs=v;preamble=0;guard=0;end
  endtask
  task automatic line(input bit hdmi,input bit guard_like_first,input integer index,input bit h,input bit v);
    idle(100,h,v);
    if(hdmi)begin
      repeat(8)begin @(negedge clk);preamble=1;end
      repeat(2)begin @(negedge clk);preamble=0;guard=1;end
    end
    for(integer x=0;x<1920;x=x+1)begin
      @(negedge clk);de=1;guard=0;preamble=0;
      rgb=(guard_like_first&&x==0)?24'hab55ab:{8'(x+index),8'(x*3+index),8'(x*7+index)};
    end
    @(negedge clk);de=0;
    idle(100,h,v);
  endtask
  initial begin
    idle(20,0,0);rst=0;idle(100,0,0);check_en=1;
    for(integer i=0;i<5;i=i+1)line(0,i==2,i,i[0],i[1]);
    for(integer i=0;i<5;i=i+1)line(1,0,i+5,i[1],i[0]);
    // Switch back to DVI after HDMI: previous video preamble must not leak.
    line(0,1,10,1,1);
    idle(100,1,1);
    if(rd!=wr ||line_count!=11)$fatal(1,"counts rd=%0d wr=%0d lines=%0d",rd,wr,line_count);
    $display("PASS board A to B: DVI/HDMI 11 lines, %0d pixels, first/last RGB exact, guard-like DVI data retained",rd);
    $finish;
  end
endmodule
