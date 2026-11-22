`timescale 1ns/1ps
module tb_catalog_table_raster;
    logic clk=0,rst_n=0,in_vs=0,in_de=0;
    always #3 clk=~clk;
    logic [11:0] x=0,y=0;
    logic ui_enable=1;
    logic [31:0] ui_data=32'd1;
    logic [7:0] wr_data=0,catalog_rd_data;
    logic [demo_model_asset_pkg::MODEL_CATALOG_ADDR_WIDTH-1:0] wr_addr,catalog_rd_addr;
    logic wr_en=0,catalog_rd_en;
    logic [7:0] catalog_bytes[0:demo_model_asset_pkg::MODEL_CATALOG_BYTES-1];
    logic [15:0] pixel;
    logic ui_half,ui_opaque;
    integer glyph_rows[0:6];
    integer count_digit_seen[0:4];
    string model_names[0:28];
    string table_names[0:12];
    integer readmask;
    integer expected_char;

    display_ui_catalog_ram catalog_ram(
        .wr_clk(clk),.wr_en,.wr_addr,.wr_data,
        .rd_clk(clk),.rd_en(catalog_rd_en),.rd_addr(catalog_rd_addr),.rd_data(catalog_rd_data));

    display_renderer dut(
        .clk,.rst_n,.x,.y,.in_hs(1'b0),.in_vs,.in_de,
        .scene_mode(2'd0),.source_width(12'd1920),.source_height(12'd1080),
        .source_x(12'd0),.source_y(12'd0),.dest_x(12'd0),.dest_y(12'd0),
        .dest_width(12'd1920),.dest_height(12'd1080),.x_step(32'd65536),.y_step(32'd65536),
        .wipe_x(12'd960),.ui_enable,.fps_bcd(12'd0),.status_ok(1'b1),.ui_data,
        .ui_hint(14'h007f),.ui_metrics(17'd0),.catalog_model_count(5'd29),.catalog_table_count(4'd13),
        .ui_values(96'd0),.ui_live_state(3'd1),.ui_catalog_data(catalog_rd_data),
        .ui_catalog_addr(catalog_rd_addr),.ui_catalog_re(catalog_rd_en),.diagnostics_status(4'd0),
        .src_a_x(),.src_a_y(),.src_b_x(),.src_b_y(),.next_source_y(),.src_a_req(),.src_b_req(),
        .out_hs(),.out_vs(),.out_de(),.out_ui_half(ui_half),.out_ui_opaque(ui_opaque),.out_rgb565(pixel));

    task automatic write_slot(input integer addr,input string name);
        integer i;
        begin
            for(i=0;i<16;i++)begin
                @(negedge clk);
                wr_en=1;wr_addr=addr+i;
                if(i<name.len())wr_data=name[i];else wr_data=8'h20;
                catalog_bytes[addr+i]=wr_data;
                @(posedge clk);#1;
            end
        end
    endtask

    task automatic scan_picker(input integer table_index,input string expected_name);
        integer ink;
        integer base;
        begin
            ui_data=32'd1;
            ui_data[13:11]=table_index[2:0];ui_data[28]=table_index[3];
            base=demo_model_asset_pkg::MODEL_CATALOG_TABLE_BASE+table_index*16;
            for(integer row=0;row<7;row++)glyph_rows[row]=0;
            readmask=0;
            for(integer sy=637;sy<658;sy++)begin
                @(negedge clk);x=0;y=sy;in_de=1;
                @(posedge clk);#1;
                if(dut.line_tag!==6'd10)$fatal(1,"table picker line tag missing: %0d",dut.line_tag);
                for(integer xx=0;xx<1920;xx++)begin
                    if(xx!=0)begin @(negedge clk);x=xx;y=sy;end
                    #1;
                    if(catalog_rd_en)begin
                        if(catalog_rd_addr<base||catalog_rd_addr>=base+16)
                            $fatal(1,"catalog read escaped table slot index=%0d addr=%0d base=%0d",table_index,catalog_rd_addr,base);
                        if(table_index>=6&&catalog_rd_addr<512)
                            $fatal(1,"table slots beyond byte 511 did not use high catalog addresses index=%0d addr=%0d",
                                table_index,catalog_rd_addr);
                        if(catalog_rd_addr!==base+dut.fetch_index)
                            $fatal(1,"catalog addr/index mismatch index=%0d addr=%0d fetch=%0d",table_index,catalog_rd_addr,dut.fetch_index);
                        readmask=readmask|(1<<dut.fetch_index);
                    end
                    if(dut.text_valid_q&&dut.text_catalog_q&&dut.text_msg_q==7'd18)begin
                        expected_char=(dut.text_index_q<expected_name.len())?expected_name[dut.text_index_q]:8'h20;
                        if(catalog_rd_data!==expected_char[7:0]||dut.glyph_char!==expected_char[7:0])
                            $fatal(1,"catalog RAM character mismatch index=%0d char=%0d data=%h expected=%h",
                                table_index,dut.text_index_q,catalog_rd_data,expected_char);
                    end
                    if(dut.font_pixel&&xx>=1480&&xx<1736)begin
                        ink=(sy-637)/3;
                        if(ink>=0&&ink<7)glyph_rows[ink]++;
                    end
                    @(posedge clk);
                end
            end
            #1;
            if(readmask!=16'hffff)$fatal(1,"catalog slot did not fetch all 16 bytes index=%0d mask=%h",table_index,readmask);
            for(integer row=0;row<7;row++)if(glyph_rows[row]==0)
                $fatal(1,"picker glyph row absent index=%0d row=%0d",table_index,row);
        end
    endtask

    task automatic scan_model_footer(input integer model_index,input string expected_name);
        integer ink;
        integer base;
        begin
            ui_data=0;
            ui_data[7:5]=model_index[2:0];ui_data[27]=model_index[3];ui_data[31]=model_index[4];
            if({ui_data[31],ui_data[27],ui_data[7:5]}!==model_index[4:0])
                $fatal(1,"model metadata bits failed index=%0d encoded=%0d",model_index,{ui_data[31],ui_data[27],ui_data[7:5]});
            base=model_index*16;
            for(integer row=0;row<7;row++)glyph_rows[row]=0;
            readmask=0;
            for(integer sy=1019;sy<1040;sy++)begin
                @(negedge clk);x=0;y=sy;in_de=1;
                @(posedge clk);#1;
                if(sy<1025&&dut.line_tag!==6'd35)
                    $fatal(1,"shared footer arrow line tag missing y=%0d tag=%0d",sy,dut.line_tag);
                if(sy>=1025&&dut.line_tag!==6'd3)
                    $fatal(1,"footer subtitle line tag missing y=%0d tag=%0d",sy,dut.line_tag);
                for(integer xx=0;xx<1920;xx++)begin
                    if(xx!=0)begin @(negedge clk);x=xx;y=sy;end
                    #1;
                    if(catalog_rd_en)begin
                        if(dut.font_line_tag!==6'd3)
                            $fatal(1,"footer model fetch selected wrong font row y=%0d x=%0d tag=%0d",sy,xx,dut.font_line_tag);
                        if(catalog_rd_addr<base||catalog_rd_addr>=base+16)
                            $fatal(1,"model read escaped slot index=%0d addr=%0d base=%0d",model_index,catalog_rd_addr,base);
                        if(catalog_rd_addr!==base+dut.fetch_index)
                            $fatal(1,"model catalog addr/index mismatch index=%0d addr=%0d fetch=%0d",model_index,catalog_rd_addr,dut.fetch_index);
                        readmask=readmask|(1<<dut.fetch_index);
                    end
                    if(dut.text_valid_q&&dut.text_catalog_q&&dut.text_msg_q==7'd11)begin
                        expected_char=(dut.text_index_q<expected_name.len())?expected_name[dut.text_index_q]:8'h20;
                        if(catalog_rd_data!==expected_char[7:0]||dut.glyph_char!==expected_char[7:0])
                            $fatal(1,"model catalog RAM character mismatch index=%0d char=%0d data=%h expected=%h",
                                model_index,dut.text_index_q,catalog_rd_data,expected_char);
                    end
                    if(dut.font_pixel&&xx>=96&&xx<256)begin
                        ink=(sy-1019)/3;
                        if(ink>=0&&ink<7)glyph_rows[ink]++;
                    end
                    @(posedge clk);
                end
            end
            #1;
            if(readmask!=16'h07ff)$fatal(1,"model footer fetch span changed index=%0d mask=%h",model_index,readmask);
            for(integer row=0;row<7;row++)if(glyph_rows[row]==0)
                $fatal(1,"footer model glyph row absent index=%0d row=%0d",model_index,row);
        end
    endtask

    initial begin
        model_names[0]="VANGOGH";model_names[1]="POPCOMIC";model_names[2]="CANDY";model_names[3]="POINTILL";
        model_names[4]="BLUEPRINT";model_names[5]="NEON";model_names[6]="GRAFFITI";model_names[7]="CYBERPUNK";
        model_names[8]="AURORA";model_names[9]="INKWASH";model_names[10]="PICASSO";model_names[11]="PIXEL";
        model_names[12]="PAPERCUT";model_names[13]="CARTOON";model_names[14]="WOODCUT";model_names[15]="UKIYOE";
        model_names[16]="SKETCH";model_names[17]="MINIMAL";model_names[18]="CYANOTYPE";model_names[19]="INKCARVE";
        model_names[20]="TIKTOK";model_names[21]="SUNRISE";model_names[22]="RUST";model_names[23]="DITHER";
        model_names[24]="RETRO";model_names[25]="PSY";
        model_names[26]="COPPER";model_names[27]="NOBEL";model_names[28]="MOSAIC";
        table_names[0]="IDENTITY";table_names[1]="WARM";table_names[2]="AGED";table_names[3]="VERDANT";
        table_names[4]="MEMORY";table_names[5]="CINE";table_names[6]="NEON";table_names[7]="CYAN";
        table_names[8]="FOREST";table_names[9]="THERMAL";table_names[10]="SUNSET";table_names[11]="DUOTONE";table_names[12]="INVERT";
        wr_addr=0;wr_data=0;
        for(integer i=0;i<5;i++)count_digit_seen[i]=0;
        repeat(5)@(negedge clk);rst_n=1;in_vs=1;
        repeat(2)@(negedge clk);in_vs=0;
        for(integer i=0;i<29;i++)write_slot(i*16,model_names[i]);
        for(integer i=0;i<13;i++)write_slot(demo_model_asset_pkg::MODEL_CATALOG_TABLE_BASE+i*16,table_names[i]);
        @(negedge clk);wr_en=0;
        if(demo_model_asset_pkg::MODEL_CATALOG_TABLE_BASE!=464||
           demo_model_asset_pkg::MODEL_CATALOG_BYTES!=672||
           demo_model_asset_pkg::MODEL_CATALOG_ADDR_WIDTH!=10)
            $fatal(1,"generated catalog constants disagree with 672B/10-bit layout");
        for(integer i=0;i<672;i++)if(catalog_bytes[i]===8'hxx)
            $fatal(1,"catalog byte was not initialized addr=%0d",i);
        if(model_names[25]!="PSY"||table_names[12]!="INVERT")$fatal(1,"test vectors incomplete");
        scan_picker(0,"IDENTITY");
        scan_picker(8,"FOREST");
        scan_picker(12,"INVERT");
        if(demo_model_asset_pkg::MODEL_COUNT!=29)$fatal(1,"generated model count is not 29");
        scan_model_footer(12,"PAPERCUT");
        scan_model_footer(13,"CARTOON");
        scan_model_footer(25,"PSY");
        scan_model_footer(26,"COPPER");
        scan_model_footer(27,"NOBEL");
        scan_model_footer(28,"MOSAIC");

        // Exercise actual count glyphs for the last legal table slot: 13/13.
        ui_data=32'd1;ui_data[13:11]=3'd4;ui_data[28]=1'b1;
        @(negedge clk);x=0;y=704;in_de=1;
        @(posedge clk);#1;
        if(dut.line_tag!==6'd11)$fatal(1,"table count line tag missing");
        for(integer xx=0;xx<1920;xx++)begin
            if(xx!=0)begin @(negedge clk);x=xx;y=704;end
            #1;
            if(dut.text_valid_q&&dut.text_msg_q==7'd55&&dut.text_index_q<5)begin
                expected_char=dut.text_index_q==0?"1":dut.text_index_q==1?"3":dut.text_index_q==2?"/":
                    dut.text_index_q==3?"1":"3";
                if(dut.glyph_char!==expected_char[7:0])
                    $fatal(1,"table count glyph index=%0d got=%h expected=%h",dut.text_index_q,dut.glyph_char,expected_char);
                count_digit_seen[dut.text_index_q]++;
            end
            @(posedge clk);
        end
        for(integer i=0;i<5;i++)if(count_digit_seen[i]==0)$fatal(1,"13/13 glyph index not rendered: %0d",i);
        $display("PASS catalog raster: all 672 bytes; footer PAPERCUT/CARTOON/PSY/COPPER/NOBEL/MOSAIC; IDENTITY/FOREST/INVERT; 13/13 through RAM");
        $finish;
    end
endmodule

