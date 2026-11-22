`timescale 1ns/1ps
module tb_hand_marker_csr;
    reg cfg_clk=0,pix_clk=0,cfg_rst_n=0,pix_rst_n=0;
    always #5 cfg_clk=~cfg_clk;
    always #7 pix_clk=~pix_clk;
    reg cfg_valid=0,cfg_write=0;
    reg [11:0] cfg_addr=0;
    reg [31:0] cfg_wdata=0;
    reg [3:0] cfg_wstrb=4'hf;
    reg in_vs=0,pix_line_start=0;
    wire cfg_ready,cfg_error;
    wire [31:0] cfg_rdata;
    wire [13:0] ui_hint;
    wire [4:0] catalog_model_count;
    wire [3:0] catalog_table_count;
    wire [demo_model_asset_pkg::MODEL_CATALOG_ADDR_WIDTH-1:0] catalog_wr_addr;
    wire [7:0] catalog_wr_data;
    wire catalog_wr_en;

    display_cfg_csr dut(
        .cfg_clk,.cfg_rst_n,.cfg_valid,.cfg_write,.cfg_addr,.cfg_wdata,.cfg_wstrb,
        .cfg_ready,.cfg_error,.cfg_rdata,.pix_clk,.pix_rst_n,.in_vs,.pix_line_start,
        .diagnostics_status(4'd0),.underflow_a_event(1'b0),.underflow_b_event(1'b0),
        .underflow_a_x(12'd0),.underflow_a_y(12'd0),.underflow_b_x(12'd0),.underflow_b_y(12'd0),
        .scene_mode(),.base_a(),.base_b(),.stride_a(),.stride_b(),.source_width(),.source_height(),
        .source_x(),.source_y(),.dest_x(),.dest_y(),.dest_width(),.dest_height(),.wipe_x(),
        .x_step(),.y_step(),.ui_enable(),.status_ok(),.fps_bcd(),.ui_data(),.ui_hint(ui_hint),
        .ui_metrics(),.catalog_model_count,.catalog_table_count,.ui_values(),.ui_live_state(),
        .config_applied(),.catalog_wr_addr,.catalog_wr_data,.catalog_wr_en);

    task automatic write_csr(input [11:0] a,input [31:0] d);
        begin
            @(negedge cfg_clk);cfg_valid=1;cfg_write=1;cfg_addr=a;cfg_wdata=d;
            #1;if(cfg_error)$fatal(1,"CSR write error addr=%h data=%h",a,d);
            @(posedge cfg_clk);#1;
            @(negedge cfg_clk);cfg_valid=0;cfg_write=0;
        end
    endtask
    task automatic pulse_vs;
        begin
            @(negedge pix_clk);in_vs=1;
            repeat(3)@(negedge pix_clk);
            in_vs=0;repeat(2)@(negedge pix_clk);
        end
    endtask

    initial begin
        repeat(4)@(negedge cfg_clk);cfg_rst_n=1;pix_rst_n=1;
        repeat(2)@(negedge pix_clk);
        if(ui_hint!==14'h007f)$fatal(1,"pixel reset did not default marker hidden: %h",ui_hint);
        write_csr(12'h044,32'h00001234);
        write_csr(12'h038,32'h1);
        repeat(4)@(negedge pix_clk);
        pulse_vs();
        if(ui_hint!==14'h1234)$fatal(1,"VS commit missed marker: %h",ui_hint);

        // A shadow write alone cannot tear the pixel-domain marker at VS.
        write_csr(12'h044,32'h0000007f);pulse_vs();
        if(ui_hint!==14'h1234)$fatal(1,"uncommitted marker crossed CDC: %h",ui_hint);
        write_csr(12'h038,32'h1);repeat(4)@(negedge pix_clk);pulse_vs();
        if(ui_hint!==14'h007f)$fatal(1,"hide commit missed VS boundary: %h",ui_hint);

        // Catalog count stays shadowed until the regular atomic VS commit.
        write_csr(12'h078,32'h00000d1a); /* 26 models, 13 UI tables. */
        if(catalog_model_count!==0||catalog_table_count!==0)
            $fatal(1,"catalog count crossed before commit");
        write_csr(12'h038,32'h1);repeat(4)@(negedge pix_clk);pulse_vs();
        if(catalog_model_count!==26||catalog_table_count!==13)
            $fatal(1,"catalog count commit mismatch %0d/%0d",catalog_model_count,catalog_table_count);
        write_csr(12'h078,32'h00000c19);
        if(catalog_model_count!==26||catalog_table_count!==13)
            $fatal(1,"catalog count shadow tore pixel snapshot");
        write_csr(12'h038,32'h1);repeat(4)@(negedge pix_clk);pulse_vs();
        if(catalog_model_count!==25||catalog_table_count!==12)
            $fatal(1,"second catalog count commit mismatch");

        // The 10-bit byte address survives CSR high bits and data auto-increment.
        write_csr(12'h070,32'h000003ab);
        if(catalog_wr_addr!==10'h3ab)$fatal(1,"catalog high index truncated: %h",catalog_wr_addr);
        @(negedge cfg_clk);cfg_valid=1;cfg_write=1;cfg_addr=12'h074;cfg_wdata=32'h5a;cfg_wstrb=4'h1;
        #1;if(cfg_error||!catalog_wr_en||catalog_wr_addr!==10'h3ab||catalog_wr_data!==8'h5a)
            $fatal(1,"catalog data write decode mismatch");
        @(posedge cfg_clk);#1;
        if(catalog_wr_addr!==10'h3ac)$fatal(1,"catalog auto-increment failed: %h",catalog_wr_addr);
        @(negedge cfg_clk);cfg_valid=0;cfg_write=0;
        $display("PASS hand-marker/catalog CSR: atomic count snapshots, 10-bit index, data auto-increment");
        $finish;
    end
endmodule
