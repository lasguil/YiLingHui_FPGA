`timescale 1ns/1ps
module tb_gesture_prompt_ui;
 reg clk=0,rst_n=0,in_vs=0,in_de=0;
 always #3 clk=~clk;
 reg[11:0] x=0,y=0;
 reg[2:0] live=1;reg ui_enable=0;reg[31:0] data_drive=0;reg[13:0] ui_hint=14'h007f;
 reg[1:0] scene_mode=0;wire[31:0] ui_data=(live==6)?32'h00400000:data_drive;
 reg[95:0] values=0;
 wire half,opaque;wire[15:0] pixel;
 reg rom_re=0;reg[11:0] rom_addr=0;wire[7:0] rom_data;
 pipeline_luna_ui_text_rom prompt_rom(.clk(clk),.re(rom_re),.addr(rom_addr),.data(rom_data));
 display_renderer dut(.clk,.rst_n,.x,.y,.in_hs(1'b0),.in_vs,.in_de,
 .scene_mode(scene_mode),.source_width(12'd1920),.source_height(12'd1080),.source_x(12'd0),.source_y(12'd0),
 .dest_x(12'd0),.dest_y(12'd0),.dest_width(12'd1920),.dest_height(12'd1080),.x_step(32'd65536),.y_step(32'd65536),.wipe_x(12'd960),
 .ui_enable,.fps_bcd(12'h300),.status_ok(1'b1),.ui_data(ui_data),.ui_hint,.ui_metrics(17'd0),.catalog_model_count(5'd26),.catalog_table_count(4'd13),.ui_values(values),.ui_live_state(live),
 .ui_catalog_data(8'd0),.ui_catalog_addr(),.ui_catalog_re(),.diagnostics_status(4'd0),
 .src_a_x(),.src_a_y(),.src_b_x(),.src_b_y(),.next_source_y(),.src_a_req(),.src_b_req(),
 .out_hs(),.out_vs(),.out_de(),.out_ui_half(half),.out_ui_opaque(opaque),.out_rgb565(pixel));

 task automatic select_line(input logic [11:0] yy,input logic [11:0] xx,
                           input logic [6:0] expected_msg,input logic [4:0] expected_len);
  begin
   @(negedge clk);in_de=0;x=0;y=yy;
   repeat(3)@(negedge clk);
   in_de=1;@(posedge clk);#1;x=xx;#1;
   if(dut.font_msg!==expected_msg || dut.font_len!==expected_len)
    $fatal(1,"text select y=%0d x=%0d msg=%0d len=%0d expected=%0d/%0d data=%h live=%0d tag=%0d",yy,xx,dut.font_msg,dut.font_len,expected_msg,expected_len,ui_data,live,dut.line_tag);
   in_de=0;
  end
 endtask

 task automatic check_button_alpha(input integer xx,input integer yy);
  begin
   if(!dut.ui_overlay||!dut.ui_button)
    $fatal(1,"button overlay missing at %0d,%0d",xx,yy);
   if(dut.ui_button_border)begin
    if(dut.panel_color!==16'h4B09||half||!opaque)
     $fatal(1,"secondary button border alpha/color mismatch at %0d,%0d",xx,yy);
   end else if(dut.font_pixel)begin
    if(!opaque||half)
     $fatal(1,"button glyph is not opaque at %0d,%0d",xx,yy);
   end else if(dut.ui_footer_button)begin
    if(dut.panel_color!==(ui_data[29]?16'h29C5:16'h1944)||!half||opaque)
     $fatal(1,"footer fill differs from FLIP state at %0d,%0d",xx,yy);
   end else if(dut.ui_selected)begin
    if(dut.panel_color!==16'h29C5||!half||opaque)
     $fatal(1,"secondary selected button fill changed at %0d,%0d",xx,yy);
   end else if(dut.panel_color!==16'h1944||!half||opaque)
    $fatal(1,"inactive secondary fill changed at %0d,%0d",xx,yy);
  end
 endtask

 initial begin
  repeat(8)@(negedge clk);rst_n=1;in_vs=1;repeat(4)@(negedge clk);in_vs=0;

  // Normal status field: READY wins over PAUSED, ERROR wins over READY.
  ui_enable=1;data_drive=0;live=1;select_line(34,1610,7'd5,5'd4);
  live=6;select_line(34,1610,7'd6,5'd6);
  live=7;select_line(34,1610,7'd80,5'd5);
  live=5;select_line(34,1610,7'd75,5'd5);

  // Menu remains visible while the shared header field carries SWIPE.
  live=7;data_drive=1;select_line(34,1610,7'd80,5'd5);

  // Clean mode reuses its existing SHOW button text slot.
  ui_enable=0;data_drive=0;live=1;select_line(1009,1735,7'd52,5'd10);
  live=6;select_line(1009,1735,7'd52,5'd10);
  live=7;select_line(1009,1735,7'd80,5'd5);
  data_drive=(1<<30)|32'd1;select_line(1009,1735,7'd0,5'd9);
  if(dut.ui_font_zone||dut.font_active)$fatal(1,"remote hide left active text glyphs");
  @(negedge clk);in_de=1;x=1760;y=1000;#1;
  if(dut.ui_overlay||opaque||half)$fatal(1,"remote hide left a SHOW control overlay");
  if(dut.ui_menu)$fatal(1,"remote hide left menu state visible");

  // Clearing returns the old labels; state 6 is still PAUSED in the header.
  ui_enable=1;data_drive=0;live=1;select_line(34,1610,7'd5,5'd4);
  live=6;select_line(34,1610,7'd6,5'd6);

  // Footer layout: STYLE arrows are centered in their tall hit boxes, and
  // SHOW TOOLS is centered in the narrowed 200-pixel clean-mode frame.
  select_line(1004,50,7'd8,5'd1);
  if(dut.font_origin!==12'd41||dut.font_y_origin!==12'd1004)
   $fatal(1,"STYLE arrow origin is not centered: %0d/%0d",dut.font_origin,dut.font_y_origin);
  ui_enable=0;data_drive=0;select_line(1009,1760,7'd52,5'd10);
  if(dut.font_origin!==12'd1684||dut.font_len!==5'd10)
   $fatal(1,"SHOW TOOLS text is not centered in 200-pixel frame");

  // Footer buttons track FLIP's current fill in either flip state.
  ui_enable=1;live=1;data_drive=0;@(negedge clk);in_de=1;x=970;y=40;#1;
  if(dut.panel_color!==16'h1944||!half||opaque)$fatal(1,"FLIP fill/alpha changed");
  for(integer flip_i=0;flip_i<2;flip_i=flip_i+1)begin
   data_drive=(flip_i<<29);
   for(integer yy=16;yy<72;yy=yy+1)begin
    for(integer xx=960;xx<1176;xx=xx+1)begin
     x=xx;y=yy;#1;
     if(dut.ui_button_border)$fatal(1,"FLIP unexpectedly has a separate border");
     check_button_alpha(xx,yy);
    end
   end
  end
  for(integer flip_i=0;flip_i<2;flip_i=flip_i+1)begin
   data_drive=(flip_i<<29);
   for(integer yy=970;yy<1058;yy=yy+1)begin
    for(integer xx=24;xx<1896;xx=xx+1)begin
     x=xx;y=yy;#1;
     if(dut.ui_button)begin
      if(!dut.ui_footer_button||dut.ui_button_border)
       $fatal(1,"footer button scope/border mismatch at %0d,%0d",xx,yy);
      check_button_alpha(xx,yy);
     end
    end
   end
  end
  data_drive=2;
  // SAT shares AI/FX's 400-pixel track, with 0/100/200 at left/middle/right.
  for(integer sat=0;sat<=200;sat+=100)begin
   values[71:60]=12'(sat);x=12'(1384+sat*2);y=570;#1;
   if(dut.slider_end!==12'(1384+sat*2)||!dut.slider_knob||!opaque||half||pixel!==16'hE60F)
    $fatal(1,"SAT slider geometry/style sat=%0d end=%0d",sat,dut.slider_end);
  end
  x=1730;y=550;#1;if(dut.ui_button||dut.ui_button_border)$fatal(1,"old SAT +/- buttons remain");
  data_drive=1;x=1584;y=810;#1;
  if(dut.slider_track||dut.slider_knob)$fatal(1,"Color FX slider remains");
  select_line(776,1400,7'd0,5'd9); // default message0 has length9, but zone is off
  if(dut.ui_font_zone)$fatal(1,"Color FX label remains");
  in_de=1;
  // Exercise every button class in all four menu pages, including selection
  // states and compact parameter controls.
  for(integer page=1;page<=4;page=page+1)begin
   data_drive=page;
   for(integer yy=112;yy<928;yy=yy+1)begin
    for(integer xx=1328;xx<1872;xx=xx+1)begin
     x=xx;y=yy;#1;
     if(dut.ui_button)check_button_alpha(xx,yy);
    end
   end
  end
  data_drive=0;x=970;y=40;#1;
  if(dut.panel_color!==16'h1944||!half||opaque)$fatal(1,"FLIP default state changed");
  data_drive=(1<<29);#1;
  if(dut.panel_color!==16'h29C5||!half||opaque||dut.ink_color!==16'hE60F)
   $fatal(1,"FLIP active fill or yellow text changed");
  x=500;y=980;#1;
  if(dut.panel_color!==16'h29C5||!half||opaque)
   $fatal(1,"footer did not track active FLIP fill");
  data_drive=(1<<29)|1;#1;
  if(dut.panel_color!==16'h29C5||!half||opaque||dut.ink_color!==16'hE60F)
   $fatal(1,"selected footer did not track active FLIP fill");
  data_drive=1;#1;
  if(dut.panel_color!==16'h1944||!half||opaque||dut.ink_color!==16'hE60F)
   $fatal(1,"selected footer did not track inactive FLIP fill");
  data_drive=2;x=1500;y=240;#1;
  if(dut.ui_footer_button||dut.panel_color!==16'h29C5||!half||opaque||dut.ink_color!==16'hE60F)
   $fatal(1,"secondary popup selected fill/label semantics changed");
  in_de=0;data_drive=0;

  // Existing wipe cue text is unchanged and no center toast is introduced.
  live=7;data_drive=(2<<25);select_line(882,850,7'd76,5'd15);
  data_drive=0;@(negedge clk);x=800;y=890;#1;
  if(opaque||half)$fatal(1,"unexpected gesture center overlay");

  // The 16x16 marker is visible in clean/source mode, inclusive at cell edges,
  // absent outside the cell, and invalidated by the x=127 sentinel.
  ui_enable=1;scene_mode=0;ui_hint={7'd20,7'd10};
  @(negedge clk);in_de=1;x=160;y=320;#1;
  if(pixel!==16'hffff||!opaque)$fatal(1,"marker missing at cell origin rgb=%h opaque=%b",pixel,opaque);
  x=175;y=335;#1;
  if(pixel!==16'hffff||!opaque)$fatal(1,"marker missing at cell far edge rgb=%h",pixel);
  x=176;y=335;#1;
  if(pixel===16'hffff||opaque)$fatal(1,"marker leaked outside cell rgb=%h opaque=%b",pixel,opaque);
  ui_hint={7'd20,7'd127};#1;
  if(pixel===16'hffff||opaque)$fatal(1,"invalid marker remained visible");

  // Marker takes precedence over the split seam while UI is enabled.
  scene_mode=2;ui_hint={7'd31,7'd60};x=960;y=500;#1;
  if(pixel!==16'hffff||!opaque)$fatal(1,"marker did not win split seam rgb=%h",pixel);
  ui_enable=1;ui_hint={7'd4,7'd10};x=160;y=64;#1;
  if(dut.ui_overlay!==1'b1||pixel===16'hffff)$fatal(1,"marker covered UI rgb=%h",pixel);
  ui_enable=0;data_drive=(1<<30);ui_hint={7'd4,7'd10};x=64;y=160;#1;
  if(pixel===16'hffff||opaque)$fatal(1,"marker remained visible during full hide");
  in_de=0;ui_enable=0;scene_mode=0;ui_hint=14'h007f;

  // Message ID 80 is stored in bank 2 at 0xA00 and contains exactly SWIPE.
  for(integer i=0;i<5;i=i+1)begin
   @(negedge clk);rom_re=1;rom_addr=12'hA00+i;
   @(posedge clk);#1;
   case(i)
    0:if(rom_data!=="S")$fatal(1,"ROM[80][0]=%h",rom_data);
    1:if(rom_data!=="W")$fatal(1,"ROM[80][1]=%h",rom_data);
    2:if(rom_data!=="I")$fatal(1,"ROM[80][2]=%h",rom_data);
    3:if(rom_data!=="P")$fatal(1,"ROM[80][3]=%h",rom_data);
    4:if(rom_data!=="E")$fatal(1,"ROM[80][4]=%h",rom_data);
   endcase
  end
  @(negedge clk);rom_re=0;

  // Track positions use binary slots 3/4 and remain opaque over any video.
  ui_enable=1;live=1;data_drive=2;in_de=1;
  values[43:36]=8'd0;values[55:48]=8'd100;
  x=1384;y=378;#1;
  if(!dut.slider_knob||!opaque||half||pixel!==16'hE60F)$fatal(1,"AI zero knob missing");
  x=1584;#1;
  if(!dut.slider_track||dut.slider_knob||!opaque||pixel!==16'h4B09)$fatal(1,"AI unfilled track missing");
  values[43:36]=8'd50;#1;
  if(!dut.slider_knob||pixel!==16'hE60F)$fatal(1,"AI midpoint wrong");
  x=1784;y=474;#1;
  if(!dut.slider_knob||!opaque||pixel!==16'hE60F)$fatal(1,"FX endpoint wrong");
  data_drive=1;y=810;#1;
  if(dut.slider_knob||dut.slider_track)$fatal(1,"removed color menu FX slider visible");
  data_drive=3;y=536;#1;
  if(dut.slider_track||dut.slider_knob)$fatal(1,"removed outside saturation control visible");
  data_drive=3;select_line(440,1400,7'd65,5'd12);
  data_drive=3|(1<<18);select_line(440,1400,7'd67,5'd14);
  data_drive=3|(2<<18);select_line(440,1400,7'd68,5'd13);
  $display("PASS UI hide/layout/colors: sliders, RGB keep presets and legacy layout");
  $finish;
 end
endmodule
