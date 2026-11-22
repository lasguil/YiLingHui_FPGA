// Complete display subsystem. The board top supplies clocks, DDR AXI arbitration,
// and Efinix HDMI high-speed pads; this block owns CPU display CSRs, DDR reads,
// scan timing, composition, RGB expansion, and TMDS symbols.
module display_system_top #(
    parameter integer H_ACTIVE=1920, V_ACTIVE=1080,
    parameter integer H_FRONT=88, H_SYNC=44, H_BACK=148,
    parameter integer V_FRONT=4, V_SYNC=5, V_BACK=36,
    parameter integer MAX_WIDTH=1920,
    parameter integer AXI_DATA_WIDTH=128,
    parameter integer AXI_ID_WIDTH=4,
    parameter integer READ_BURST_BEATS=64,
    parameter bit PIPELINE_READS=1'b1
) (
    input logic cfg_clk, cfg_rst_n,
    input logic cfg_valid, cfg_write,
    input logic [11:0] cfg_addr,
    input logic [31:0] cfg_wdata,
    input logic [3:0] cfg_wstrb,
    output logic cfg_ready, cfg_error,
    output logic [31:0] cfg_rdata,

    input logic axi_clk, axi_rst_n,
    input logic pix_clk, pix_rst_n,
    output logic axi_error_a, axi_error_b,

    output logic [AXI_ID_WIDTH-1:0] m_axi_arid,
    output logic [31:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic [3:0] m_axi_arcache,
    output logic [2:0] m_axi_arprot,
    output logic m_axi_arlock,
    output logic [3:0] m_axi_arqos,
    output logic m_axi_arvalid,
    input logic m_axi_arready,
    input logic [AXI_ID_WIDTH-1:0] m_axi_rid,
    input logic [AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast,m_axi_rvalid,
    output logic m_axi_rready,
    output logic [9:0] tmds_clk_data,
    output logic [9:0] tmds_data0,
    output logic [9:0] tmds_data1,
    output logic [9:0] tmds_data2,
    output logic tmds_tx_oe,
    output logic tmds_tx_reset,
    output logic [15:0] debug_rgb565,
    output logic debug_de,debug_hs,debug_vs,
    output logic [31:0] active_base_a,active_base_b,
    output wire display_read_active
);
    logic [1:0] scene_mode;
    logic [31:0] base_a,base_b,x_step,y_step;
    logic [15:0] stride_a,stride_b;
    logic [11:0] source_width,source_height,source_x,source_y;
    logic [11:0] dest_x,dest_y,dest_width,dest_height,wipe_x,fps_bcd;
    logic [31:0] ui_data;
    logic [13:0] ui_hint;
    logic [16:0] ui_metrics;
    logic [4:0] catalog_model_count;
    logic [3:0] catalog_table_count;
    logic [95:0] ui_values;
    logic [2:0] ui_live_state;
    logic [demo_model_asset_pkg::MODEL_CATALOG_ADDR_WIDTH-1:0] catalog_wr_addr,catalog_rd_addr;
    logic [7:0] catalog_wr_data,catalog_rd_data;
    logic catalog_wr_en,catalog_rd_en;
    wire [12:0] fetch_width_ext={1'b0,source_x}+{1'b0,source_width};
    wire [11:0] fetch_width=fetch_width_ext<=MAX_WIDTH ? fetch_width_ext[11:0] : 12'(MAX_WIDTH);
    logic ui_enable,status_ok,config_applied;
    wire reader_idle;
    (* async_reg="true" *) logic applied_axi_meta,applied_axi_sync;
    logic [31:0] base_a_meta,base_a_sync,base_b_meta,base_b_sync;
    localparam integer ROW_INDEX_W=$clog2((MAX_WIDTH+AXI_DATA_WIDTH/16-1)/(AXI_DATA_WIDTH/16)+1);
    wire row_start,row_done,row_source,row_bank,row_first,write_valid,write_source,write_bank;
    wire [11:0] row_y,write_width;
    wire [ROW_INDEX_W-1:0] write_index;
    logic [12:0] h_count,v_count;
    logic in_hs,in_vs,in_de;
    logic [11:0] x,y;
    logic raster_hs,raster_vs,raster_de;
    logic [11:0] raster_x,raster_y;
    logic vs_q;
    logic [1:0] frame_load_pending;
    logic [1:0] vs_settle;
    logic fetch_enable_a_q,fetch_enable_b_q;
    logic [11:0] fetch_width_a_q,fetch_width_b_q;
    logic [ROW_INDEX_W-1:0] fetch_first_b_q,cmd_b_first_beat;
    // The same held VS configuration determines both requests and their row
    // coverage. Native wipe needs A's prefix and B's suffix, rather than two
    // whole source rows. Other mappings keep their complete row coverage.
    always_ff @(posedge pix_clk or negedge pix_rst_n)begin
        if(!pix_rst_n)begin
            fetch_enable_a_q<=0;fetch_enable_b_q<=0;
            fetch_width_a_q<=0;fetch_width_b_q<=0;fetch_first_b_q<=0;
        end else if(in_vs)begin
            logic [11:0] prefix,half_a,half_b;
            logic [12:0] prefix_end,half_a_end,half_b_end;
            prefix=wipe_x;
            if(prefix>source_width)prefix=source_width;
            if(prefix>dest_width)prefix=dest_width;
            prefix_end={1'b0,source_x}+{1'b0,prefix};
            half_a=dest_width>>1;half_b=dest_width-half_a;
            if(half_a>source_width)half_a=source_width;
            if(half_b>source_width)half_b=source_width;
            half_a_end={1'b0,source_x}+{1'b0,half_a};
            half_b_end={1'b0,source_x}+{1'b0,half_b};
            fetch_enable_a_q<=scene_mode!=1;
            fetch_enable_b_q<=scene_mode!=0;
            fetch_width_a_q<=fetch_width;fetch_width_b_q<=fetch_width;fetch_first_b_q<=0;
            if(scene_mode==2 && x_step==32'h00010000 && dest_x==0)begin
                fetch_width_a_q<=prefix_end<=MAX_WIDTH ? prefix_end[11:0] : 12'(MAX_WIDTH);
                fetch_first_b_q<=prefix_end/(AXI_DATA_WIDTH/16);
                fetch_enable_a_q<=prefix!=0;
                fetch_enable_b_q<=prefix<source_width && prefix<dest_width && prefix_end<MAX_WIDTH;
            end
            if(scene_mode==3 && x_step==32'h00010000 && dest_x==0)begin
                fetch_width_a_q<=half_a_end<=MAX_WIDTH ? half_a_end[11:0] : 12'(MAX_WIDTH);
                fetch_width_b_q<=half_b_end<=MAX_WIDTH ? half_b_end[11:0] : 12'(MAX_WIDTH);
                fetch_enable_a_q<=half_a!=0;
                fetch_enable_b_q<=half_b!=0;
            end
        end
    end

    logic [11:0] src_a_x,src_a_y,src_b_x,src_b_y,next_source_y;
    logic src_a_req,src_b_req;
    logic [15:0] cache_a_pixel,cache_b_pixel;
    logic cache_a_valid,cache_b_valid;
    logic [11:0] cache_a_y0,cache_a_y1,cache_b_y0,cache_b_y1;
    logic [1:0] cache_a_rows_valid,cache_b_rows_valid;
    logic cmd_a_toggle,cmd_b_toggle,cmd_a_bank,cmd_b_bank,cmd_a_first,cmd_b_first;
    logic [31:0] cmd_a_base,cmd_b_base;
    logic [15:0] cmd_a_stride,cmd_b_stride;
    logic [11:0] cmd_a_width,cmd_b_width,cmd_a_y,cmd_b_y;
    logic cmd_a_ack,cmd_b_ack,cmd_a_done,cmd_b_done;
    (* async_reg="true" *) logic ack_a_meta,ack_a_sync,ack_b_meta,ack_b_sync;
    (* async_reg="true" *) logic done_a_meta,done_a_sync,done_b_meta,done_b_sync;
    logic cmd_a_busy,cmd_b_busy;
    logic pending_a,pending_b;
    logic [11:0] pending_a_y,pending_b_y;
    logic pending_a_bank,pending_b_bank;
    logic line_start_d,prefetch_row_eligible_q;
    logic [11:0] prefetch_current_y_q,prefetch_next_y_q;
    logic done_a_seen,done_b_seen;

    logic render_hs,render_vs,render_de;
    logic [15:0] render_rgb;
    logic render_ui_half,render_ui_opaque;
    logic ui_half_q,ui_opaque_q;
    logic req_a_q,req_b_q;
    logic [11:0] req_a_x_q,req_a_y_q,req_b_x_q,req_b_y_q;
    logic [15:0] overlay_q,source_rgb,final_rgb,scan_rgb_q;
    logic scan_hs_q,scan_vs_q,scan_de_q;
    logic hs_q,vs_q_out,de_q;
    wire underflow_a_event=de_q&&req_a_q&&!cache_a_valid;
    wire underflow_b_event=de_q&&req_b_q&&!cache_b_valid;
    logic [23:0] rgb888;
    logic [9:0] raw_b,raw_g,raw_r;
    logic [9:0] tmds_clock=10'b1111100000;
    logic [1:0] underflow_q;
    // Sticky until pixel reset: detect every requested sample replaced by the
    // overlay because the matching row is unavailable. CSR 0x03c reports A/B
    // underflow in bits 0/1 and A/B AXI errors in bits 2/3.
    always_ff @(posedge pix_clk or negedge pix_rst_n)begin
        if(!pix_rst_n)underflow_q<=0;
        else begin
            if(underflow_a_event)underflow_q[0]<=1;
            if(underflow_b_event)underflow_q[1]<=1;
        end
    end

    // The VS-applied bundle is held until another commit. Acknowledge the
    // displayed bases only after every read of the previous bundle has drained.
    always_ff @(posedge axi_clk or negedge axi_rst_n) begin
        if(!axi_rst_n) begin
            applied_axi_meta<=0;applied_axi_sync<=0;
            base_a_meta<=0;base_a_sync<=0;base_b_meta<=0;base_b_sync<=0;
            active_base_a<=0;active_base_b<=0;
        end else begin
            applied_axi_meta<=config_applied;applied_axi_sync<=applied_axi_meta;
            base_a_meta<=base_a;base_a_sync<=base_a_meta;
            base_b_meta<=base_b;base_b_sync<=base_b_meta;
            if(reader_idle && applied_axi_sync) begin
                active_base_a<=base_a_sync;active_base_b<=base_b_sync;
            end
        end
    end

    display_cfg_csr u_cfg(
        .cfg_clk,.cfg_rst_n,.cfg_valid,.cfg_write,.cfg_addr,.cfg_wdata,.cfg_wstrb,
        .cfg_ready,.cfg_error,.cfg_rdata,.pix_clk,.pix_rst_n,.in_vs,.pix_line_start(in_de&&(x==12'd0)),
        .diagnostics_status({axi_error_b,axi_error_a,underflow_q}),
        .underflow_a_event,.underflow_b_event,
        .underflow_a_x(req_a_x_q),.underflow_a_y(req_a_y_q),
        .underflow_b_x(req_b_x_q),.underflow_b_y(req_b_y_q),
        .scene_mode,.base_a,.base_b,.stride_a,.stride_b,
        .source_width,.source_height,.source_x,.source_y,.dest_x,.dest_y,
        .dest_width,.dest_height,.wipe_x,.x_step,.y_step,.ui_enable,.status_ok,.fps_bcd,
        .ui_data,.ui_hint,.ui_metrics,.catalog_model_count,.catalog_table_count,.ui_values,.ui_live_state,.config_applied,
        .catalog_wr_addr,.catalog_wr_data,.catalog_wr_en);

    display_ui_catalog_ram u_ui_catalog(
        .wr_clk(cfg_clk),.wr_en(catalog_wr_en),.wr_addr(catalog_wr_addr),.wr_data(catalog_wr_data),
        .rd_clk(pix_clk),.rd_en(catalog_rd_en),.rd_addr(catalog_rd_addr),.rd_data(catalog_rd_data));

    localparam integer H_TOTAL=H_SYNC+H_BACK+H_ACTIVE+H_FRONT;
    localparam integer V_TOTAL=V_SYNC+V_BACK+V_ACTIVE+V_FRONT;
    always_comb begin
        raster_hs=(h_count<H_SYNC);
        raster_vs=(v_count<V_SYNC);
        raster_de=(h_count>=H_SYNC+H_BACK && h_count<H_SYNC+H_BACK+H_ACTIVE &&
               v_count>=V_SYNC+V_BACK && v_count<V_SYNC+V_BACK+V_ACTIVE);
        raster_x=raster_de ? h_count-(H_SYNC+H_BACK) : 12'd0;
        raster_y=raster_de ? v_count-(V_SYNC+V_BACK) : 12'd0;
    end
    // Register the whole raster bundle, including sync and DE. This separates
    // counter decoding/subtraction from mapping and prefetch command selection;
    // it preserves every pixel and all porch lengths without an RGB-only shift.
    always_ff @(posedge pix_clk or negedge pix_rst_n) begin
        if(!pix_rst_n)begin in_hs<=0;in_vs<=0;in_de<=0;x<=0;y<=0;end
        else begin in_hs<=raster_hs;in_vs<=raster_vs;in_de<=raster_de;
            x<=raster_x;y<=raster_y;end
    end
    always_ff @(posedge pix_clk or negedge pix_rst_n) begin
        if(!pix_rst_n) begin h_count<=0;v_count<=0;end
        else if(h_count==H_TOTAL-1) begin
            h_count<=0;
            if(v_count==V_TOTAL-1)v_count<=0;else v_count<=v_count+1'b1;
        end else h_count<=h_count+1'b1;
    end

    // Capture the source-row descriptor at the current x=0 pixel. Consume it
    // on the following pixel clock so cache/AXI command selection starts from
    // registered coordinates; VS flush prevents a stale line request.
    always_ff @(posedge pix_clk or negedge pix_rst_n) begin
        if(!pix_rst_n)begin
            line_start_d<=0;prefetch_row_eligible_q<=0;
            prefetch_current_y_q<=0;prefetch_next_y_q<=0;
        end else if(in_vs && !vs_q)begin
            line_start_d<=0;prefetch_row_eligible_q<=0;
        end else begin
            line_start_d<=in_de && (x==12'd0);
            if(in_de && (x==12'd0))begin
                prefetch_row_eligible_q<=(y>=dest_y && y<dest_y+dest_height);
                prefetch_current_y_q<=src_a_y;
                prefetch_next_y_q<=next_source_y;
            end
        end
    end

    // Prefetch row zero during vertical blanking, then fetch the next distinct
    // mapped source row while the current row is being displayed.
    always_ff @(posedge pix_clk or negedge pix_rst_n) begin
        if(!pix_rst_n) begin
            vs_q<=0;frame_load_pending<=0;vs_settle<=0;cmd_b_first_beat<=0;
            cmd_a_toggle<=0;cmd_b_toggle<=0;cmd_a_bank<=0;cmd_b_bank<=0;cmd_a_first<=0;cmd_b_first<=0;
            cmd_a_base<=0;cmd_b_base<=0;cmd_a_stride<=0;cmd_b_stride<=0;
            cmd_a_width<=0;cmd_b_width<=0;cmd_a_y<=0;cmd_b_y<=0;
            ack_a_meta<=0;ack_a_sync<=0;ack_b_meta<=0;ack_b_sync<=0;
            done_a_meta<=0;done_a_sync<=0;done_b_meta<=0;done_b_sync<=0;
            cmd_a_busy<=0;cmd_b_busy<=0;pending_a<=0;pending_b<=0;pending_a_y<=0;pending_b_y<=0;pending_a_bank<=0;pending_b_bank<=0;done_a_seen<=0;done_b_seen<=0;
        end else begin
            vs_q<=in_vs;
            if(vs_settle!=0)vs_settle<=vs_settle-1'b1;
            ack_a_meta<=cmd_a_ack;ack_a_sync<=ack_a_meta;
            ack_b_meta<=cmd_b_ack;ack_b_sync<=ack_b_meta;
            done_a_meta<=cmd_a_done;done_a_sync<=done_a_meta;
            done_b_meta<=cmd_b_done;done_b_sync<=done_b_meta;
            if(done_a_sync!=done_a_seen)begin done_a_seen<=done_a_sync;cmd_a_busy<=0;end
            if(done_b_sync!=done_b_seen)begin done_b_seen<=done_b_sync;cmd_b_busy<=0;end
            if(pending_a && !in_vs && !cmd_a_busy && cmd_a_toggle==ack_a_sync)begin
                cmd_a_base<=base_a;cmd_a_stride<=stride_a;cmd_a_width<=fetch_width_a_q;cmd_a_y<=pending_a_y;cmd_a_bank<=pending_a_bank;
                cmd_a_toggle<=~cmd_a_toggle;cmd_a_busy<=1;pending_a<=0;cmd_a_first<=0;
            end
            if(pending_b && !in_vs && !cmd_b_busy && cmd_b_toggle==ack_b_sync)begin
                cmd_b_base<=base_b;cmd_b_stride<=stride_b;cmd_b_width<=fetch_width_b_q;cmd_b_first_beat<=fetch_first_b_q;cmd_b_y<=pending_b_y;cmd_b_bank<=pending_b_bank;
                cmd_b_toggle<=~cmd_b_toggle;cmd_b_busy<=1;pending_b<=0;cmd_b_first<=0;
            end
            if(in_vs && !vs_q)begin
                frame_load_pending<=2'b11;pending_a<=0;pending_b<=0;vs_settle<=2;
            end else begin
                if(frame_load_pending[0] && vs_settle==0 && !fetch_enable_a_q)frame_load_pending[0]<=0;
                if(frame_load_pending[1] && vs_settle==0 && !fetch_enable_b_q)frame_load_pending[1]<=0;
                if(frame_load_pending[0] && vs_settle==0 && fetch_enable_a_q && !cmd_a_busy && (cmd_a_toggle==ack_a_sync))begin
                    cmd_a_base<=base_a;cmd_a_stride<=stride_a;cmd_a_width<=fetch_width_a_q;
                    cmd_a_y<=source_y;cmd_a_bank<=0;cmd_a_toggle<=~cmd_a_toggle;cmd_a_busy<=1;cmd_a_first<=1;
                    frame_load_pending[0]<=0;
                end
                if(frame_load_pending[1] && vs_settle==0 && fetch_enable_b_q && !cmd_b_busy && (cmd_b_toggle==ack_b_sync))begin
                    cmd_b_base<=base_b;cmd_b_stride<=stride_b;cmd_b_width<=fetch_width_b_q;cmd_b_first_beat<=fetch_first_b_q;
                    cmd_b_y<=source_y;cmd_b_bank<=0;cmd_b_toggle<=~cmd_b_toggle;cmd_b_busy<=1;cmd_b_first<=1;
                    frame_load_pending[1]<=0;
                end
            end
            if(line_start_d && prefetch_row_eligible_q)begin
                logic [11:0] next_y;
                logic [11:0] cur_y;
                logic a_fill_bank,b_fill_bank;
                logic [11:0] a0,a1,b0,b1;
                logic [1:0] av,bv;
                a0=cache_a_y0;a1=cache_a_y1;b0=cache_b_y0;b1=cache_b_y1;
                av=cache_a_rows_valid;bv=cache_b_rows_valid;
                next_y=prefetch_next_y_q;
                cur_y=prefetch_current_y_q;
                a_fill_bank = (av[0]&&a0==cur_y) ? 1'b1 :
                              (av[1]&&a1==cur_y) ? 1'b0 :
                              (cmd_a_busy&&cmd_a_y==cur_y) ? ~cmd_a_bank :
                              (pending_a&&pending_a_y==cur_y) ? ~pending_a_bank :
                              av[0] ? 1'b1 : av[1] ? 1'b0 : ~cmd_a_bank;
                b_fill_bank = (bv[0]&&b0==cur_y) ? 1'b1 :
                              (bv[1]&&b1==cur_y) ? 1'b0 :
                              (cmd_b_busy&&cmd_b_y==cur_y) ? ~cmd_b_bank :
                              (pending_b&&pending_b_y==cur_y) ? ~pending_b_bank :
                              bv[0] ? 1'b1 : bv[1] ? 1'b0 : ~cmd_b_bank;
                if(next_y!=cur_y && {1'b0,next_y}<{1'b0,source_y}+{1'b0,source_height})begin
                    if(fetch_enable_a_q && !(av[0]&&a0==next_y) && !(av[1]&&a1==next_y))begin
                        if(!cmd_a_busy && cmd_a_toggle==ack_a_sync && !pending_a && !frame_load_pending[0])begin
                            cmd_a_base<=base_a;cmd_a_stride<=stride_a;cmd_a_width<=fetch_width_a_q;cmd_a_y<=next_y;
                            cmd_a_bank<=a_fill_bank;
                            cmd_a_toggle<=~cmd_a_toggle;cmd_a_busy<=1;cmd_a_first<=0;
                        end else begin pending_a<=1;pending_a_y<=next_y;pending_a_bank<=a_fill_bank;end
                    end
                    if(fetch_enable_b_q && !(bv[0]&&b0==next_y) && !(bv[1]&&b1==next_y))begin
                        if(!cmd_b_busy && cmd_b_toggle==ack_b_sync && !pending_b && !frame_load_pending[1])begin
                            cmd_b_base<=base_b;cmd_b_stride<=stride_b;cmd_b_width<=fetch_width_b_q;cmd_b_first_beat<=fetch_first_b_q;cmd_b_y<=next_y;
                            cmd_b_bank<=b_fill_bank;
                            cmd_b_toggle<=~cmd_b_toggle;cmd_b_busy<=1;cmd_b_first<=0;
                        end else begin pending_b<=1;pending_b_y<=next_y;pending_b_bank<=b_fill_bank;end
                    end
                end
            end
        end
    end

    assign m_axi_arcache=4'b0011;
    assign m_axi_arprot=0;assign m_axi_arlock=0;assign m_axi_arqos=0;
    display_axi_shared_reader #(.MAX_WIDTH(MAX_WIDTH),.AXI_DATA_WIDTH(AXI_DATA_WIDTH),.ID_WIDTH(AXI_ID_WIDTH),.MAX_BURST_BEATS(READ_BURST_BEATS),.MAX_OUTSTANDING(PIPELINE_READS?2:1)) u_row_reader(
        .axi_clk,.axi_rst_n,.a_toggle(cmd_a_toggle),.b_toggle(cmd_b_toggle),
        .a_base(cmd_a_base),.b_base(cmd_b_base),.a_stride(cmd_a_stride),.b_stride(cmd_b_stride),
        .a_width(cmd_a_width),.b_width(cmd_b_width),.a_y(cmd_a_y),.b_y(cmd_b_y),
        .a_first_beat({ROW_INDEX_W{1'b0}}),.b_first_beat(cmd_b_first_beat),
        .a_bank(cmd_a_bank),.b_bank(cmd_b_bank),.a_first(cmd_a_first),.b_first(cmd_b_first),.a_ack(cmd_a_ack),.b_ack(cmd_b_ack),
        .a_done(cmd_a_done),.b_done(cmd_b_done),.error_a(axi_error_a),.error_b(axi_error_b),.idle(reader_idle),.row_busy(),.read_reserve(display_read_active),
        .row_start,.row_done,.row_source,.row_bank,.row_first,.row_y,
        .write_valid,.write_source,.write_bank,.write_index,.write_width,
        .m_axi_arid,.m_axi_araddr,.m_axi_arlen,.m_axi_arsize,.m_axi_arburst,.m_axi_arvalid,.m_axi_arready,
        .m_axi_rid,.m_axi_rresp,.m_axi_rlast,.m_axi_rvalid,.m_axi_rready);
    display_axi_line_store #(.MAX_WIDTH(MAX_WIDTH),.AXI_DATA_WIDTH(AXI_DATA_WIDTH)) u_cache_a(
        .axi_clk,.axi_rst_n,.pix_clk,.pix_rst_n,
        .row_start(row_start && !row_source),.row_done(row_done && !row_source),.row_bank,.row_first,.row_y,
        .write_valid(write_valid && !write_source),.write_bank,.write_index,.write_width,.write_data(m_axi_rdata),
        .pixel_x(src_a_x),.pixel_y(src_a_y),.pixel_req(src_a_req),.pixel_data(cache_a_pixel),.pixel_valid(cache_a_valid),
        .cached0_y(cache_a_y0),.cached1_y(cache_a_y1),.cached_valid(cache_a_rows_valid));
    display_axi_line_store #(.MAX_WIDTH(MAX_WIDTH),.AXI_DATA_WIDTH(AXI_DATA_WIDTH)) u_cache_b(
        .axi_clk,.axi_rst_n,.pix_clk,.pix_rst_n,
        .row_start(row_start && row_source),.row_done(row_done && row_source),.row_bank,.row_first,.row_y,
        .write_valid(write_valid && write_source),.write_bank,.write_index,.write_width,.write_data(m_axi_rdata),
        .pixel_x(src_b_x),.pixel_y(src_b_y),.pixel_req(src_b_req),.pixel_data(cache_b_pixel),.pixel_valid(cache_b_valid),
        .cached0_y(cache_b_y0),.cached1_y(cache_b_y1),.cached_valid(cache_b_rows_valid));

    // The renderer computes source coordinates combinationally for this pixel.
    // The line RAM captures that address on the edge; latch the choice/overlay
    // on the same edge so its returned sample is selected for that pixel.
    display_renderer u_renderer(
        .clk(pix_clk),.rst_n(pix_rst_n),.x,.y,.in_hs,.in_vs,.in_de,
        .scene_mode,.source_width,.source_height,.source_x,.source_y,.dest_x,.dest_y,.dest_width,.dest_height,.x_step,.y_step,.wipe_x,.ui_enable,.fps_bcd,.status_ok,
        .ui_data,.ui_hint,.ui_metrics,.catalog_model_count,.catalog_table_count,.ui_values,.ui_live_state,
        .ui_catalog_data(catalog_rd_data),.ui_catalog_addr(catalog_rd_addr),.ui_catalog_re(catalog_rd_en),
        .diagnostics_status({axi_error_b,axi_error_a,underflow_q}),
        .src_a_x,.src_a_y,.src_b_x,.src_b_y,.next_source_y,.src_a_req,.src_b_req,
        .out_hs(render_hs),.out_vs(render_vs),.out_de(render_de),.out_rgb565(render_rgb),
        .out_ui_half(render_ui_half),.out_ui_opaque(render_ui_opaque));
    always_ff @(posedge pix_clk or negedge pix_rst_n) begin
        if(!pix_rst_n)begin req_a_q<=0;req_b_q<=0;req_a_x_q<=0;req_a_y_q<=0;req_b_x_q<=0;req_b_y_q<=0;overlay_q<=0;ui_half_q<=0;ui_opaque_q<=0;hs_q<=0;vs_q_out<=0;de_q<=0;end
        else begin req_a_q<=src_a_req;req_b_q<=src_b_req;req_a_x_q<=src_a_x;req_a_y_q<=src_a_y;req_b_x_q<=src_b_x;req_b_y_q<=src_b_y;overlay_q<=render_rgb;ui_half_q<=render_ui_half;ui_opaque_q<=render_ui_opaque;hs_q<=render_hs;vs_q_out<=render_vs;de_q<=render_de;end
    end
    // Fixed alpha needs only three small adders. Widen each component before
    // adding so RGB565 channel carries cannot contaminate adjacent channels.
    function automatic [15:0] half565(input logic [15:0] a,input logic [15:0] b);
        logic [5:0] r,bv;
        logic [6:0] g;
        begin
            r={1'b0,a[15:11]}+{1'b0,b[15:11]};
            g={1'b0,a[10:5]}+{1'b0,b[10:5]};
            bv={1'b0,a[4:0]}+{1'b0,b[4:0]};
            half565={r[5:1],g[6:1],bv[5:1]};
        end
    endfunction
    always_comb begin
        source_rgb=16'h0000;
        if(req_a_q && cache_a_valid) source_rgb=cache_a_pixel;
        else if(req_b_q && cache_b_valid) source_rgb=cache_b_pixel;
        if(ui_opaque_q) final_rgb=overlay_q;
        else if(ui_half_q) final_rgb=half565(source_rgb,overlay_q);
        else if((req_a_q && cache_a_valid)||(req_b_q && cache_b_valid)) final_rgb=source_rgb;
        else final_rgb=overlay_q;
    end
    // One shared output stage isolates cache/select/alpha from the TMDS
    // encoder. Delay the entire raster bundle; never shift RGB alone.
    always_ff @(posedge pix_clk or negedge pix_rst_n)begin
        if(!pix_rst_n)begin scan_rgb_q<=0;scan_hs_q<=0;scan_vs_q<=0;scan_de_q<=0;end
        else begin scan_rgb_q<=final_rgb;scan_hs_q<=hs_q;scan_vs_q<=vs_q_out;scan_de_q<=de_q;end
    end
    function automatic [23:0] expand565(input logic [15:0] p);
        expand565={p[15:11],p[15:13],p[10:5],p[10:9],p[4:0],p[4:2]};
    endfunction
    assign rgb888=expand565(scan_rgb_q);
    tmds_encode enc_blue(.clk(pix_clk),.rst_p(!pix_rst_n),.din(rgb888[7:0]),.c0(scan_hs_q),.c1(scan_vs_q),.de(scan_de_q),.dout(raw_b));
    tmds_encode enc_green(.clk(pix_clk),.rst_p(!pix_rst_n),.din(rgb888[15:8]),.c0(1'b0),.c1(1'b0),.de(scan_de_q),.dout(raw_g));
    tmds_encode enc_red(.clk(pix_clk),.rst_p(!pix_rst_n),.din(rgb888[23:16]),.c0(1'b0),.c1(1'b0),.de(scan_de_q),.dout(raw_r));
    always_comb begin
        tmds_clk_data=~tmds_clock;
        tmds_data0=~raw_b;tmds_data1=~raw_g;tmds_data2=~raw_r;
        tmds_tx_oe=1'b1;tmds_tx_reset=1'b0;
        debug_rgb565=scan_rgb_q;debug_de=scan_de_q;debug_hs=scan_hs_q;debug_vs=scan_vs_q;
    end
endmodule














