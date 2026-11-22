`timescale 1ns/1ps
module tb_ui_range_equivalence;
    import demo_model_asset_pkg::*;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    logic [11:0] x=0,y=0;
    logic in_hs=0,in_vs=0,in_de=0;
    logic [1:0] scene_mode=0;
    logic [11:0] source_width=1920,source_height=1080,source_x=0,source_y=0;
    logic [11:0] dest_x=0,dest_y=0,dest_width=1920,dest_height=1080;
    logic [31:0] x_step=65536,y_step=65536;
    logic [11:0] wipe_x=960,fps_bcd=12'h300;
    logic ui_enable=1,status_ok=1;
    logic [31:0] ui_data=0;
    logic [13:0] ui_hint=14'h007f;
    logic [16:0] ui_metrics=17'h1300;
    logic [4:0] catalog_model_count=26;
    logic [3:0] catalog_table_count=13;
    logic [95:0] ui_values=0;
    logic [2:0] ui_live_state=1;
    logic [3:0] diagnostics_status=0;
    logic [7:0] catalog_old=0,catalog_new=0;
    typedef struct packed {
        logic [11:0] ax,ay,bx,by,next_y;
        logic a_req,b_req,hs,vs,de,half_alpha,opaque;
        logic [15:0] rgb;
        logic [MODEL_CATALOG_ADDR_WIDTH-1:0] catalog_addr;
        logic catalog_re;
    } result_t;
    wire result_t old_result,new_result;
`define COMMON .clk,.rst_n,.x,.y,.in_hs,.in_vs,.in_de,.scene_mode, \
    .source_width,.source_height,.source_x,.source_y,.dest_x,.dest_y,.dest_width,.dest_height, \
    .x_step,.y_step,.wipe_x,.ui_enable,.fps_bcd,.status_ok,.ui_data,.ui_hint,.ui_metrics, \
    .catalog_model_count,.catalog_table_count,.ui_values,.ui_live_state,.diagnostics_status
`define OUTPUTS(r) .src_a_x(r.ax),.src_a_y(r.ay),.src_b_x(r.bx),.src_b_y(r.by), \
    .next_source_y(r.next_y),.src_a_req(r.a_req),.src_b_req(r.b_req), \
    .out_hs(r.hs),.out_vs(r.vs),.out_de(r.de),.out_ui_half(r.half_alpha), \
    .out_ui_opaque(r.opaque),.out_rgb565(r.rgb),.ui_catalog_addr(r.catalog_addr),.ui_catalog_re(r.catalog_re)
    display_renderer_before_ui_range ref_dut(`COMMON,`OUTPUTS(old_result),.ui_catalog_data(catalog_old));
    display_renderer dut(`COMMON,`OUTPUTS(new_result),.ui_catalog_data(catalog_new));
`undef COMMON
`undef OUTPUTS
    function automatic [7:0] catalog_byte(input logic [MODEL_CATALOG_ADDR_WIDTH-1:0] addr);
        catalog_byte=8'd65+8'(addr%26);
    endfunction
    always @(posedge clk)begin
        if(old_result.catalog_re)catalog_old<=catalog_byte(old_result.catalog_addr);
        if(new_result.catalog_re)catalog_new<=catalog_byte(new_result.catalog_addr);
    end
    integer samples=0,font_samples=0,text_reads=0,ink_samples=0;
    integer scenario=0;
    bit [84:0] message_seen=0;
    task automatic compare;
        begin
            if(old_result !== new_result)
                $fatal(1,"UI outputs differ scenario=%0d x=%0d y=%0d old=%h new=%h",scenario,x,y,old_result,new_result);
            if({ref_dut.font_active,ref_dut.font_index,ref_dut.font_x,ref_dut.text_rd_en,
                ref_dut.text_addr,ref_dut.glyph_addr,ref_dut.font_pixel} !==
               {dut.font_active,dut.font_index,dut.font_x,dut.text_rd_en,
                dut.text_addr,dut.glyph_addr,dut.font_pixel})
                $fatal(1,"UI text/prefetch differs scenario=%0d x=%0d y=%0d",scenario,x,y);
            samples++;
            if(dut.font_active)font_samples++;
            if(dut.text_rd_en)begin text_reads++;message_seen[dut.font_msg]=1;end
            if(dut.font_pixel)ink_samples++;
        end
    endtask
    task automatic pixel(input integer px,input integer py,input bit active);
        begin
            @(negedge clk);x=12'(px);y=12'(py);in_de=active;
            #1;compare();
            @(posedge clk);#1;compare();
        end
    endtask
    task automatic scan_line(input integer sy);
        begin
            // First x=0 edge establishes the scanline tag, as in the real raster.
            for(integer sx=0;sx<1920;sx++)pixel(sx,sy,1);
            for(integer sx=1920;sx<1924;sx++)pixel(sx,sy,0);
        end
    endtask
    task automatic frame_boundary;
        begin
            @(negedge clk);in_de=0;in_vs=1;x=0;y=0;
            repeat(3)@(negedge clk);
            in_vs=0;
        end
    endtask
    integer scan_y[0:31]='{0,34,40,54,140,146,160,166,241,253,259,273,337,344,350,364,
                          421,440,446,460,505,536,542,556,578,637,643,657,704,850,886,1019};
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        for(scenario=0;scenario<24;scenario++)begin
            ui_data=0;
            ui_data[2:0]=3'(scenario%5);
            ui_data[4:3]=2'(scenario%4);
            ui_data[20:18]=3'(scenario%3);
            ui_data[17]=scenario[0];ui_data[21]=scenario[1];ui_data[22]=scenario[2];
            ui_data[16]=(scenario%3)==1;ui_data[15]=(scenario%3)==2;
            ui_data[29]=scenario[0];ui_data[30]=scenario==22;
            ui_data[7:5]=3'(scenario%8);ui_data[27]=scenario[3];ui_data[31]=scenario[4];
            ui_data[13:11]=3'(scenario%13);ui_data[28]=(scenario%13)>=8;
            ui_data[26:25]=2'(scenario%4);
            ui_enable=scenario!=20 && scenario!=21 && scenario!=23;
            ui_live_state=scenario[0]?7:1;
            ui_values={32'h12345678,32'h90123456,32'h78901234};
            ui_values[43:36]=8'(scenario%3==0?0:scenario%3==1?50:100);
            ui_values[55:48]=8'(100-(scenario%3)*50);
            ui_values[67:60]=8'((scenario%3)*100);
            scene_mode=2'(scenario%4);
            wipe_x=12'(scenario==0?48:scenario==1?1871:960);
            source_width=scenario[0]?1280:1920;source_height=scenario[0]?720:1080;
            source_x=scenario[0]?16:0;source_y=scenario[0]?12:0;
            x_step=scenario[0]?43690:65536;y_step=scenario[0]?43690:65536;
            frame_boundary();
            for(integer line_no=0;line_no<32;line_no++)scan_line(scan_y[line_no]);
            for(integer sy=987;sy<1040;sy++)scan_line(sy);
            for(integer sy=868;sy<916;sy+=3)scan_line(sy);
            $display("UI RANGE scenario=%0d samples=%0d",scenario,samples);
        end
        // Exercise dynamic wipe origins, the 512-pixel alias boundary, and all
        // 12-bit coordinates while a text line tag is retained.
        ui_enable=1;ui_data=0;ui_data[26:25]=2;wipe_x=48;
        frame_boundary();scan_line(507);
        for(integer sx=0;sx<4096;sx++)pixel(sx,507,1);
        if(font_samples<10000 || text_reads<1000 || ink_samples<1000)
            $fatal(1,"insufficient visible text coverage");
        $display("PASS UI RANGE EQUIVALENCE samples=%0d font=%0d reads=%0d ink=%0d message_mask=%h",samples,font_samples,text_reads,ink_samples,message_seen);
        $finish;
    end
endmodule
