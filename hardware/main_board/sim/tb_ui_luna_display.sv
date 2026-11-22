`timescale 1ns/1ps
module tb_ui_luna_display;
    logic cfg_clk=0,pix_clk=0,cfg_rst_n=0,pix_rst_n=0;
    always #5 cfg_clk=~cfg_clk;
    always #3.333 pix_clk=~pix_clk;
    logic cfg_valid=0,cfg_write=0,in_vs=0;
    logic [11:0] cfg_addr=0;
    logic [31:0] cfg_wdata=0;
    logic [3:0] cfg_wstrb=4'hf,diagnostics_status=0;
    wire cfg_ready,cfg_error;wire [31:0] cfg_rdata;
    wire [1:0] scene_mode;wire [31:0] base_a,base_b,x_step,y_step;
    wire [15:0] stride_a,stride_b;
    wire [11:0] source_width,source_height,source_x,source_y,dest_x,dest_y,dest_width,dest_height,wipe_x,fps_bcd;
    wire ui_enable,status_ok,config_applied;
    wire [31:0] ui_data;wire [10:0] ui_hint;wire [16:0] ui_metrics;wire [2:0] ui_live_state;
    integer dump_fd;
    logic [11:0] x=0,y=0;
    logic [1:0] scene_sel=2'd2;
    logic in_hs=0,render_vs=0,in_de=0;
    wire pix_line_start=in_de&&(x==12'd0);
    wire [11:0] src_a_x,src_a_y,src_b_x,src_b_y,next_source_y;
    wire src_a_req,src_b_req,out_hs,out_vs,out_de;wire [15:0] out_rgb565;

    display_cfg_csr cfg(
        .cfg_clk,.cfg_rst_n,.cfg_valid,.cfg_write,.cfg_addr,.cfg_wdata,.cfg_wstrb,
        .cfg_ready,.cfg_error,.cfg_rdata,.pix_clk,.pix_rst_n,.in_vs,
        .pix_line_start,.diagnostics_status,.scene_mode,.base_a,.base_b,.stride_a,.stride_b,
        .source_width,.source_height,.source_x,.source_y,.dest_x,.dest_y,.dest_width,.dest_height,
        .wipe_x,.x_step,.y_step,.ui_enable,.status_ok,.fps_bcd,.ui_data,.ui_hint,.ui_metrics,
        .ui_live_state,.config_applied);
    display_renderer dut(
        .clk(pix_clk),.rst_n(pix_rst_n),.x,.y,.in_hs,.in_vs,.in_de,
        .scene_mode(scene_sel),.source_width,.source_height,.source_x,.source_y,
        .dest_x,.dest_y,.dest_width,.dest_height,
        .x_step,.y_step,.wipe_x(12'd960),.ui_enable,.fps_bcd,.status_ok,
        .ui_data,.ui_hint,.ui_metrics,.ui_live_state,.diagnostics_status,
        .src_a_x,.src_a_y,.src_b_x,.src_b_y,.next_source_y,.src_a_req,.src_b_req,
        .out_hs,.out_vs,.out_de,.out_rgb565);

    task automatic write(input logic [11:0] a,input logic [31:0] d);
        begin
            @(negedge cfg_clk);cfg_valid=1;cfg_write=1;cfg_addr=a;cfg_wdata=d;cfg_wstrb=4'hf;
            #1;if(cfg_error)$fatal(1,"write rejected addr=%h",a);
            @(negedge cfg_clk);cfg_valid=0;cfg_write=0;
        end
    endtask
    task automatic commit_vsync;
        begin
            write(12'h038,32'd1);
            repeat(4)@(negedge pix_clk); // allow the commit toggle to reach the pixel domain
            @(negedge pix_clk);x=0;y=0;in_de=0;in_vs=1;
            repeat(5)@(negedge pix_clk);in_vs=0;
            repeat(4)@(negedge cfg_clk);
            if(!config_applied)$fatal(1,"config commit did not acknowledge");
        end
    endtask
    task automatic sample(input logic [11:0] sx,input logic [11:0] sy);
        begin @(negedge pix_clk);x=sx;y=sy;in_de=1;#1;end
    endtask
    task automatic frame_zero;
        begin
            @(negedge pix_clk);x=0;y=0;in_de=1;
            @(posedge pix_clk);#1;
        end
    endtask
    task automatic live_state(input logic [2:0] s);
        logic [31:0] prior;logic next_toggle;
        begin
            @(negedge cfg_clk);cfg_addr=12'h04c;cfg_valid=1;cfg_write=0;#1;prior=cfg_rdata;cfg_valid=0;
            next_toggle=~prior[3];
            write(12'h04c,{29'd0,s});
            repeat(3)@(negedge cfg_clk);
            if(cfg.ui_state_ack_sync==next_toggle)$fatal(1,"state ack before a pixel line boundary");
            @(negedge pix_clk);x=0;y=300;in_de=1;
            @(posedge pix_clk);#1;
            repeat(4)@(negedge cfg_clk);
            if(cfg.ui_state_ack_sync!=next_toggle || ui_live_state!=s)
                $fatal(1,"live state CDC failed req=%0d ack=%0d state=%0d",next_toggle,cfg.ui_state_ack_sync,ui_live_state);
        end
    endtask
    task automatic lowres_geometry(input integer mode,input integer width,input integer height,
                                   input integer step_x,input integer step_y,input integer expect_x,input integer expect_y);
        logic [31:0] ui;
        begin
            write(12'h00c,(height<<16)|width);
            write(12'h018,(1080<<16)|1920);
            write(12'h024,step_x);write(12'h028,step_y);
            ui=(20'h00123<<12)|(4'b0111<<8)|(mode&3);
            write(12'h040,ui);
            commit_vsync();
            frame_zero();
            for(integer yy=0;yy<1080;yy++)begin
                @(negedge pix_clk);x=0;y=yy;in_de=1;#1;
                if(src_a_y>=height)$fatal(1,"mode=%0d y=%0d mapped out of source range: %0d",mode,yy,src_a_y);
                if(yy==1079&&src_a_y!=expect_y)$fatal(1,"mode=%0d final source y=%0d expected=%0d",mode,src_a_y,expect_y);
                @(posedge pix_clk);
                @(negedge pix_clk);x=1;@(posedge pix_clk); // let the registered next-line accumulator settle
            end
            frame_zero();
            for(integer xx=0;xx<1920;xx++)begin
                @(negedge pix_clk);x=xx;y=0;in_de=1;#1;
                if(src_a_x>=width)$fatal(1,"mode=%0d x=%0d mapped out of source range: %0d",mode,xx,src_a_x);
                if(xx==1919&&src_a_x!=expect_x)$fatal(1,"mode=%0d final source x=%0d expected=%0d",mode,src_a_x,expect_x);
                @(posedge pix_clk);
            end
        end
    endtask

    initial begin
        repeat(5)@(negedge cfg_clk);cfg_rst_n=1;pix_rst_n=1;
        write(12'h00c,{4'd0,12'd1080,4'd0,12'd1920});
        write(12'h018,{4'd0,12'd1080,4'd0,12'd1920});
        write(12'h024,32'h00010000);write(12'h028,32'h00010000);
        write(12'h030,32'd1);
        // mode=480p30, READY, DIRECT, diag+hint+metric enabled, frame count=00123 BCD.
        write(12'h040,{20'h00123,4'b0111,3'd0,3'd0,2'd2});
        write(12'h044,(11'd3<<1)|1'b1);
        write(12'h048,17'd0);
        if(ui_data!==0 || ui_enable!==0)$fatal(1,"uncommitted UI became visible early");
        commit_vsync();
        if(ui_data[1:0]!=2 || ui_data[31:12]!=20'h00123 || !ui_enable)
            $fatal(1,"VS commit did not atomically publish UI metadata");

        sample(24,17);if(src_a_req || src_b_req || out_rgb565!==16'h18e3)
            $fatal(1,"left card padding overlay/requests incorrect rgb=%h A=%b B=%b",out_rgb565,src_a_req,src_b_req);
        sample(28,24);if(out_rgb565!==16'h18e3)$fatal(1,"5x7 A first-column mask wrong rgb=%h",out_rgb565);
        sample(31,24);if(out_rgb565!==16'h07ff)$fatal(1,"scaled A glyph pixel missing rgb=%h",out_rgb565);
        sample(100,51);if(out_rgb565===16'h18e3 || src_a_req!==1'b0)
            $fatal(1,"input-resolution character cell not rendered/occluded");
        sample(500,40);if(!src_a_req || out_rgb565!==16'h0000)$fatal(1,"image A outside UI card was disturbed");
        sample(1200,40);if(!src_b_req || src_a_req)$fatal(1,"wipe B-side request changed");
        sample(1618,20);if(src_a_req || src_b_req || out_rgb565!==16'h18e3)
            $fatal(1,"right card background/requests incorrect rgb=%h",out_rgb565);
        sample(1625,24);if(out_rgb565!==16'h07ff)$fatal(1,"right title font pixel missing rgb=%h",out_rgb565);
        sample(1630,105);if(out_rgb565!==16'h18e3)$fatal(1,"invalid FPS must not reserve a visible row rgb=%h",out_rgb565);
        sample(24,1020);if(out_rgb565!==16'h0000 || !src_a_req)
            $fatal(1,"hint appeared before frame-counter reload");

        frame_zero();
        sample(24,1020);if(out_rgb565!==16'h18e3 || src_a_req)
            $fatal(1,"hint region should be covered while timer is active");
        // A 3-output-frame hint expires on the fourth frame start.
        frame_zero();frame_zero();frame_zero();
        sample(24,1020);if(out_rgb565!==16'h0000 || !src_a_req)
            $fatal(1,"hint failed to expire after frame-count duration");

        live_state(3'd2);
        if(ui_live_state!==3'd2)$fatal(1,"PROCESSING state was not captured");
        diagnostics_status=4'b0010;
        // A historical sticky diagnostic must not falsify the real live state,
        // and disabling the history row must not affect state or accent color.
        write(12'h040,{20'h00123,4'b0110,3'd0,3'd0,2'd2});
        commit_vsync();
        sample(1625,51);if(out_rgb565!==16'hdfff||ui_live_state!==3'd2)
            $fatal(1,"hidden sticky diagnostic incorrectly changed PROCESSING status rgb=%h",out_rgb565);
        sample(1625,112);if(out_rgb565!==16'h0000)
            $fatal(1,"diagnostic row must disappear when disabled");
        // Re-enable the row: state remains PROCESSING while the independent
        // fourth row explicitly says the sticky event was observed.
        write(12'h040,{20'h00123,4'b0111,3'd0,3'd0,2'd2});
        commit_vsync();
        sample(1625,51);if(out_rgb565!==16'hdfff||ui_live_state!==3'd2)
            $fatal(1,"visible historical diagnostic overwrote live state rgb=%h",out_rgb565);
        sample(1622,105);if(out_rgb565!==16'hfca0)
            $fatal(1,"sticky underflow history row missing/incorrect rgb=%h",out_rgb565);
        sample(1878,105);if(out_rgb565!==16'h18e3)
            $fatal(1,"diagnostic row wrapped and repeated text past its end");
        sample(1881,51);if(out_rgb565!==16'h18e3)
            $fatal(1,"live state line wrapped and repeated text past its end");
        // Only a current software fatal state is orange.
        live_state(3'd5);sample(1625,51);
        if(out_rgb565!==16'hfca0)$fatal(1,"live fatal state was not marked orange");
        live_state(3'd2);
        diagnostics_status=0;
        scene_sel=2'd0;sample(1625,42);
        if(out_rgb565!==16'h18e3)$fatal(1,"original-only scene label must identify A/original");
        scene_sel=2'd1;sample(1625,42);
        if(out_rgb565!==16'h07ff)$fatal(1,"B-only scene label must identify processed B output");
        scene_sel=2'd2;sample(1625,42);
        if(out_rgb565!==16'h18e3)$fatal(1,"wipe scene label must identify A/B wipe");
        scene_sel=2'd3;sample(1622+12*16+3,24);
        if(out_rgb565!==16'h07ff)$fatal(1,"side-by-side scene label missing");
        scene_sel=2'd2;
        lowres_geometry(0,1920,1080,65536,65536,1919,1079);
        sample(143,60);if(out_rgb565!==16'hDFFF)
            $fatal(1,"1080p mode label did not map its input size/rate");
        lowres_geometry(1,1280,720,43680,43671,1279,719);
        sample(143,60);if(out_rgb565!==16'h18e3)
            $fatal(1,"720p mode label did not update at VS atomically");
        lowres_geometry(2,854,480,29131,29094,853,479);
        sample(127,51);if(out_rgb565!==16'hDFFF)
            $fatal(1,"480p mode label did not update at VS atomically");
        lowres_geometry(3,854,480,29131,29094,853,479);
        sample(252,51);if(out_rgb565!==16'h18e3)
            $fatal(1,"480p60 nominal input rate label did not update");
        write(12'h048,17'h10600);commit_vsync();
        sample(1689,105);if(out_rgb565!==16'hDFFF)
            $fatal(1,"valid measured-FPS BCD field was not rendered");
        // Restore representative boot UI and emit actual RTL pixels for both
        // top cards and the transient footer. The preview composites these ROI
        // pixels over an abstract background; it does not redraw the glyphs.
        diagnostics_status=0;scene_sel=2'd2;
        write(12'h040,{20'h00123,4'b0111,3'd0,3'd0,2'd2});
        write(12'h048,17'd0);write(12'h044,(11'd180<<1)|1'b0);commit_vsync();
        frame_zero();@(negedge pix_clk);in_de=0;live_state(3'd1);
        sample(284,1024);if(out_rgb565!==16'h18e3)
            $fatal(1,"hint text wrapped and repeated past its end rgb=%h hint=%h data=%h",out_rgb565,ui_hint,ui_data);
        dump_fd=$fopen("ui_luna_rtl_dump.txt","w");
        if(dump_fd==0)$fatal(1,"cannot create RTL pixel dump");
        for(integer yy=0;yy<150;yy++)begin
            $fwrite(dump_fd,"T %0d ",yy);
            for(integer xx=0;xx<1920;xx++)begin
                @(negedge pix_clk);x=xx;y=yy;in_de=1;#1;
                $fwrite(dump_fd,"%04h",out_rgb565);
            end
            $fwrite(dump_fd,"\n");
        end
        for(integer yy=1000;yy<1070;yy++)begin
            $fwrite(dump_fd,"B %0d ",yy);
            for(integer xx=0;xx<1920;xx++)begin
                @(negedge pix_clk);x=xx;y=yy;in_de=1;#1;
                $fwrite(dump_fd,"%04h",out_rgb565);
            end
            $fwrite(dump_fd,"\n");
        end
        $fclose(dump_fd);
        $display("PASS UI_LUNA viewport=1920x1080 cards=3 glyph=5x7x3 live_state=CDC hint_frames=3 sticky_diag=independent scene_labels=4 rtl_dump=220rows");
        $finish;
    end
endmodule



