`timescale 1ns/1ps
module tb_footer_raster;
    logic clk=0,rst_n=0,in_vs=0,in_de=0;
    always #3 clk=~clk;
    logic [11:0] x=0,y=0;
    logic ui_enable=1;
    logic [31:0] ui_data=0;
    logic [13:0] ui_hint=14'h007f;
    logic [15:0] pixel;
    logic ui_half,ui_opaque;
    logic [5:0] observed_tag;
    integer title_counts[0:5],sub_counts[0:5];
    integer title_ink[0:6],sub_ink[0:6],arrow_ink[0:6];
    integer title_expected[0:5]='{80,80,96,64,80,80};
    integer sub_expected[0:5]='{160,144,256,128,240,160};
    integer left_arrow_count,right_arrow_count;

    display_renderer dut(
        .clk,.rst_n,.x,.y,.in_hs(1'b0),.in_vs,.in_de,
        .scene_mode(2'd0),.source_width(12'd1920),.source_height(12'd1080),
        .source_x(12'd0),.source_y(12'd0),.dest_x(12'd0),.dest_y(12'd0),
        .dest_width(12'd1920),.dest_height(12'd1080),.x_step(32'd65536),.y_step(32'd65536),
        .wipe_x(12'd960),.ui_enable,.fps_bcd(12'd0),.status_ok(1'b1),.ui_data,
        .ui_hint,.ui_metrics(17'd0),.catalog_model_count(5'd26),.catalog_table_count(4'd13),
        .ui_values(96'd0),.ui_live_state(3'd1),.ui_catalog_data(8'h41),
        .ui_catalog_addr(),.ui_catalog_re(),.diagnostics_status(4'd0),
        .src_a_x(),.src_a_y(),.src_b_x(),.src_b_y(),.next_source_y(),.src_a_req(),.src_b_req(),
        .out_hs(),.out_vs(),.out_de(),.out_ui_half(ui_half),.out_ui_opaque(ui_opaque),.out_rgb565(pixel));

    function automatic integer group_for_x(input integer px,input integer second_line);
        if(!second_line)begin
            if(px>=96&&px<176)return 0;
            if(px>=356&&px<436)return 1;
            if(px>=672&&px<768)return 2;
            if(px>=988&&px<1052)return 3;
            if(px>=1304&&px<1400)return 4;
            if(px>=1600&&px<1680)return 5;
        end else begin
            if(px>=96&&px<256)return 0;
            if(px>=356&&px<548)return 1;
            if(px>=672&&px<928)return 2;
            if(px>=988&&px<1116)return 3;
            if(px>=1304&&px<1544)return 4;
            if(px>=1600&&px<1760)return 5;
        end
        return -1;
    endfunction

    initial begin
        repeat(6)@(negedge clk);rst_n=1;in_vs=1;
        repeat(3)@(negedge clk);in_vs=0;
        for(integer i=0;i<7;i++)begin title_ink[i]=0;sub_ink[i]=0;arrow_ink[i]=0;end
        // Walk actual active pixels, in order, across the complete footer
        // title/subtitle rows and the intervening blank lines. Every scanline
        // begins at x=0 so line_tag changes only through the renderer's normal
        // line_start path; no y-only or mid-line tag forcing is used.
        for(integer yy=970;yy<1058;yy++)begin
            for(integer i=0;i<6;i++)begin title_counts[i]=0;sub_counts[i]=0;end
            left_arrow_count=0;right_arrow_count=0;
            @(negedge clk);x=0;y=yy;in_de=1;
            @(posedge clk);#1;
            observed_tag=dut.line_tag;
            if((yy>=987&&yy<1004)&&observed_tag!==6'd2)
                $fatal(1,"title line tag changed y=%0d tag=%0d",yy,observed_tag);
            if((yy>=1004&&yy<1025)&&observed_tag!==6'd35)
                $fatal(1,"arrow/title/subtitle shared row tag changed y=%0d tag=%0d",yy,observed_tag);
            if((yy>=1025&&yy<1040)&&observed_tag!==6'd3)
                $fatal(1,"subtitle line tag changed y=%0d tag=%0d",yy,observed_tag);
            if((yy<987||yy>=1040)&&observed_tag!==6'd0)
                $fatal(1,"unexpected footer tag outside text rows y=%0d tag=%0d",yy,observed_tag);
            for(integer xx=0;xx<1920;xx++)begin
                if(xx!=0)begin @(negedge clk);x=xx;y=yy;end
                #1;
                if((xx>=38&&xx<57)||(xx>=290&&xx<309))begin
                    if((yy<1004||yy>=1025)&&(dut.font_active||dut.font_pixel))
                        $fatal(1,"arrow rendered outside centered 21px row x=%0d y=%0d active/pixel=%0b/%0b",
                            xx,yy,dut.font_active,dut.font_pixel);
                end
                if(dut.font_active)begin
                    integer g;
                    if(yy>=1004&&yy<1025)begin
                        if(xx>=41&&xx<57)left_arrow_count++;
                        if(xx>=293&&xx<309)right_arrow_count++;
                    end
                    g=group_for_x(xx,yy>=1019);
                    if(g>=0)begin
                        if(yy<1008)title_counts[g]++;
                        else if(yy>=1019)sub_counts[g]++;
                    end
                end
                if(dut.font_pixel)begin
                    integer r;
                    if((yy>=987&&yy<1008)&&group_for_x(xx,0)>=0)begin
                        r=(yy-987)/3;title_ink[r]++;
                    end
                    if((yy>=1019&&yy<1040)&&group_for_x(xx,1)>=0)begin
                        r=(yy-1019)/3;sub_ink[r]++;
                    end
                    if(yy>=1004&&yy<1025&&((xx>=41&&xx<57)||(xx>=293&&xx<309)))begin
                        r=(yy-1004)/3;arrow_ink[r]++;
                    end
                end
                @(posedge clk);
            end
            #1;
            if(yy>=987&&yy<1008)for(integer i=0;i<6;i++)
                if(title_counts[i]!=title_expected[i])
                    $fatal(1,"title glyph span clipped y=%0d group=%0d got=%0d expected=%0d",
                        yy,i,title_counts[i],title_expected[i]);
            if(yy>=1019&&yy<1040)for(integer i=0;i<6;i++)
                if(sub_counts[i]!=sub_expected[i])
                    $fatal(1,"subtitle glyph span clipped y=%0d group=%0d got=%0d expected=%0d",
                        yy,i,sub_counts[i],sub_expected[i]);
            if(yy>=1004&&yy<1025)begin
                if(left_arrow_count!=16||right_arrow_count!=16)
                    $fatal(1,"centered arrow glyph clipped y=%0d left/right=%0d/%0d",
                        yy,left_arrow_count,right_arrow_count);
                if(yy<1008&&dut.font_y_origin!==12'd987)
                    $fatal(1,"title glyph row origin changed y=%0d origin=%0d",yy,dut.font_y_origin);
                if(yy>=1019&&dut.font_y_origin!==12'd1019)
                    $fatal(1,"subtitle glyph row origin changed y=%0d origin=%0d",yy,dut.font_y_origin);
                if(dut.font_y_origin!==12'd1004&&dut.font_y_origin!==12'd987&&dut.font_y_origin!==12'd1019)
                    $fatal(1,"footer glyph row has unexpected origin y=%0d origin=%0d",yy,dut.font_y_origin);
            end
        end
        // Scan clean mode through its real line-start path too: the narrower
        // 200-pixel SHOW TOOLS button keeps its centered text and hit box.
        ui_enable=0;in_de=0;
        for(integer yy=1009;yy<1030;yy++)begin
            integer show_count;
            show_count=0;
            @(negedge clk);x=0;y=yy;in_de=1;
            @(posedge clk);#1;
            if(dut.line_tag!==6'd30)$fatal(1,"SHOW line tag missing y=%0d tag=%0d",yy,dut.line_tag);
            for(integer xx=0;xx<1920;xx++)begin
                if(xx!=0)begin @(negedge clk);x=xx;y=yy;end
                #1;
                if(dut.font_active&&xx>=1684&&xx<1844)show_count++;
                @(posedge clk);
            end
            if(show_count!=160)$fatal(1,"centered SHOW TOOLS text clipped y=%0d span=%0d",yy,show_count);
        end
        for(integer r=0;r<7;r++)begin
            if(title_ink[r]==0||sub_ink[r]==0||arrow_ink[r]==0)
                $fatal(1,"glyph ROM row missing title/subtitle/arrow row=%0d counts=%0d/%0d/%0d",
                    r,title_ink[r],sub_ink[r],arrow_ink[r]);
        end
        if(dut.ui_button||dut.ui_overlay)$fatal(1,"unexpected SHOW control outside its 200-pixel box");
        @(negedge clk);x=1750;y=1000;in_de=1;#1;
        if(!dut.ui_button||!dut.ui_overlay)$fatal(1,"SHOW hit target missing inside 200-pixel box");
        if(dut.panel_color!==16'h1944)$fatal(1,"FLIP state unexpectedly recolored SHOW/footer buttons");
        @(negedge clk);ui_enable=1;ui_data=32'h20000000;x=500;y=980;#1;
        if(dut.panel_color!==16'h29C5)$fatal(1,"footer color no longer follows FLIP state");
        $display("PASS footer raster: full title/subtitle rows, centered arrows, and 200px SHOW frame");
        $finish;
    end
endmodule
