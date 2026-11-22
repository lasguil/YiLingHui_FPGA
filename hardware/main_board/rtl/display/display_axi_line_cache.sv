// Burst reader and two-bank RGB565 line cache for one DDR source.
// A pixel-domain row command is held stable until AXI-domain acceptance.
module display_axi_line_cache #(
    parameter integer MAX_WIDTH = 1920,
    parameter integer AXI_DATA_WIDTH = 128,
    parameter integer ADDR_WIDTH = 32,
    parameter integer ID_WIDTH = 4,
    parameter integer MAX_BURST_BEATS = 64
) (
    input  logic                  axi_clk,
    input  logic                  axi_rst_n,
    input  logic                  pix_clk,
    input  logic                  pix_rst_n,

    input  logic                  row_cmd_toggle,
    input  logic [31:0]           row_cmd_base,
    input  logic [15:0]           row_cmd_stride,
    input  logic [11:0]           row_cmd_width,
    input  logic [11:0]           row_cmd_y,
    input  logic                  row_cmd_bank,
    output logic                  row_cmd_ack,
    output logic                  row_cmd_done,
    output logic [11:0]           cached0_y,
    output logic [11:0]           cached1_y,
    output logic [1:0]            cached_valid,

    input  logic [11:0]           pixel_x,
    input  logic [11:0]           pixel_y,
    input  logic                  pixel_req,
    output logic [15:0]           pixel_data,
    output logic                  pixel_valid,

    output logic [ID_WIDTH-1:0]   m_axi_arid,
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    input  logic [ID_WIDTH-1:0]   m_axi_rid,
    input  logic [AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,
    output logic                  axi_error,
    output wire                   axi_idle
);
    localparam integer LANES = AXI_DATA_WIDTH/16;
    localparam integer BYTES_PER_BEAT = AXI_DATA_WIDTH/8;
    localparam integer MAX_BEATS = (MAX_WIDTH+LANES-1)/LANES;
    localparam integer BANK_ADDR_W = (MAX_BEATS>1) ? $clog2(MAX_BEATS) : 1;
    localparam integer BANK_DEPTH = 1 << BANK_ADDR_W;
    localparam integer MEM_ADDR_W = BANK_ADDR_W+1;
    localparam integer BEAT_COUNT_W = $clog2((MAX_WIDTH+LANES-1)/LANES+1);

    logic [11:0] row_tag [0:1];
    logic row_valid [0:1];
    (* async_reg="true" *) logic [11:0] row_tag_meta0,row_tag_meta1;
    (* async_reg="true" *) logic [11:0] row_tag_meta2,row_tag_meta3;
    (* async_reg="true" *) logic [1:0] row_valid_meta0,row_valid_meta1;
    logic [15:0] rd_lane_mem [0:LANES-1];
    logic rd_valid;
    logic [11:0] rd_y_q;
    logic rd_bank_q;
    logic [$clog2(LANES)-1:0] rd_lane_q;
    logic rd_bank_d;
    logic [11:0] rd_word_full;
    logic [BANK_ADDR_W-1:0] rd_word_addr;
    logic [MEM_ADDR_W-1:0] rd_mem_addr,wr_mem_addr;

    logic cmd_meta,cmd_sync,cmd_seen;
    logic [31:0] cmd_base_q;
    logic [15:0] cmd_stride_q;
    logic [11:0] cmd_width_q,cmd_y_q;
    logic cmd_bank_q;
    logic [11:0] active_width;
    logic [15:0] active_stride;
    logic [31:0] active_base;
    logic [11:0] active_y;
    logic active_bank;
    logic [31:0] row_address;
    logic [11:0] tag0_q,tag1_q;
    logic [1:0] valid_q;
    logic [BEAT_COUNT_W-1:0] beats_left,beat_index,burst_beats;
    logic [BEAT_COUNT_W-1:0] burst_left;
    logic [BEAT_COUNT_W-1:0] word_pixel_base;
    logic busy;
    logic ar_issued;
    assign axi_idle = !busy && !m_axi_arvalid && !m_axi_rready;

    assign cached0_y=tag0_q;
    assign cached1_y=tag1_q;
    assign cached_valid=valid_q;

    // Pack both row banks into one 512x16-capable memory per AXI RGB565 lane.
    // AXI writes still update all lanes in parallel; the pixel port reads only
    // the selected row bank and lane. Keeping the bank bit in the RAM address
    // avoids spending a separate RAM10 on each 240-word row bank.
    always_comb begin
        rd_bank_d=(row_valid_meta1[0] && row_tag_meta1==pixel_y) ? 1'b0 : 1'b1;
        rd_word_full=pixel_x/LANES;
        rd_word_addr=rd_word_full[BANK_ADDR_W-1:0];
        rd_mem_addr={rd_bank_d,rd_word_addr};
        wr_mem_addr={active_bank,beat_index[BANK_ADDR_W-1:0]};
    end

    genvar lane_g;
    generate
        for(lane_g=0;lane_g<LANES;lane_g=lane_g+1) begin: g_lane
            logic [15:0] line_mem [0:(2*BANK_DEPTH)-1];
            logic [15:0] rd_data_q;
            always_ff @(posedge axi_clk) begin
                if(axi_rst_n && m_axi_rvalid && m_axi_rready &&
                   beat_index*LANES+lane_g<active_width)
                    line_mem[wr_mem_addr]<=m_axi_rdata[lane_g*16+:16];
            end
            always_ff @(posedge pix_clk) begin
                if(pixel_req && pixel_x<MAX_WIDTH)
                    rd_data_q<=line_mem[rd_mem_addr];
            end
            assign rd_lane_mem[lane_g]=rd_data_q;
        end
    endgenerate

    // Pixel-side dual-port RAM read. Registered read data is aligned with
    // the row/coordinate tag, then consumed by the renderer on the next beat.
    always_ff @(posedge pix_clk or negedge pix_rst_n) begin
        if(!pix_rst_n) begin
            row_tag_meta0<=0;row_tag_meta1<=0;row_tag_meta2<=0;row_tag_meta3<=0;tag0_q<=0;tag1_q<=0;valid_q<=0;
            row_valid_meta0<=0;row_valid_meta1<=0;
            rd_valid<=0;rd_y_q<=0;rd_bank_q<=0;rd_lane_q<=0;
        end else begin
            row_tag_meta0<=row_tag[0]; row_tag_meta1<=row_tag_meta0;
            row_tag_meta2<=row_tag[1]; row_tag_meta3<=row_tag_meta2;
            row_valid_meta0<={row_valid[1],row_valid[0]};
            row_valid_meta1<=row_valid_meta0;tag0_q<=row_tag_meta1;tag1_q<=row_tag_meta3;valid_q<=row_valid_meta1;
            rd_y_q<=pixel_y;
            rd_bank_q<=rd_bank_d;
            rd_lane_q<=pixel_x[$clog2(LANES)-1:0];
            rd_valid <= pixel_req && ((row_valid_meta1[0] && row_tag_meta1==pixel_y) ||
                                      (row_valid_meta1[1] && row_tag_meta3==pixel_y)) && pixel_x<MAX_WIDTH;
        end
    end
    always_comb begin
        pixel_data=rd_lane_mem[rd_lane_q];
        pixel_valid=rd_valid && (rd_bank_q ? (row_valid_meta1[1] && row_tag_meta3==rd_y_q) :
                                               (row_valid_meta1[0] && row_tag_meta1==rd_y_q));
    end

    // A single outstanding row command per source keeps the bundled CDC
    // descriptor stable while AXI bursts complete.
    always_ff @(posedge axi_clk or negedge axi_rst_n) begin
        if(!axi_rst_n) begin
            cmd_meta<=0;cmd_sync<=0;cmd_seen<=0;row_cmd_ack<=0;row_cmd_done<=0;
            cmd_base_q<=0;cmd_stride_q<=0;cmd_width_q<=0;cmd_y_q<=0;cmd_bank_q<=0;
            active_width<=0;active_stride<=0;active_base<=0;active_y<=0;active_bank<=0;
            row_address<=0;beats_left<=0;beat_index<=0;burst_beats<=0;burst_left<=0;
            word_pixel_base<=0;busy<=0;ar_issued<=0;row_valid[0]<=0;row_valid[1]<=0;
            row_tag[0]<=0;row_tag[1]<=0;axi_error<=0;
            m_axi_arid<=0;m_axi_araddr<=0;m_axi_arlen<=0;m_axi_arsize<=4;
            m_axi_arburst<=2'b01;m_axi_arvalid<=0;m_axi_rready<=0;
        end else begin
            cmd_meta<=row_cmd_toggle;cmd_sync<=cmd_meta;

            if(!busy && cmd_sync!=cmd_seen) begin
                cmd_seen<=cmd_sync;row_cmd_ack<=cmd_sync;
                if(row_cmd_width==0 || row_cmd_width>MAX_WIDTH || row_cmd_stride==0) begin
                    row_valid[row_cmd_bank]<=0;
                    row_cmd_done<=~row_cmd_done;
                    busy<=0;
                end else begin
                    active_base<=row_cmd_base;active_stride<=row_cmd_stride;active_width<=row_cmd_width;
                    active_y<=row_cmd_y;active_bank<=row_cmd_bank;
                    row_valid[row_cmd_bank]<=0;
                    row_address<=row_cmd_base + row_cmd_y*row_cmd_stride;
                    beats_left<=(row_cmd_width+LANES-1)/LANES;
                    beat_index<=0;busy<=1;ar_issued<=0;m_axi_rready<=0;
                end
            end
            if(busy && !m_axi_arvalid && !ar_issued && beats_left!=0) begin
                logic [12:0] page_beats;
                logic [BEAT_COUNT_W-1:0] take_beats;
                page_beats=(13'd4096-{1'b0,row_address[11:0]})/BYTES_PER_BEAT;
                take_beats=beats_left;
                if(take_beats>MAX_BURST_BEATS)take_beats=MAX_BURST_BEATS;
                if(take_beats>page_beats)take_beats=page_beats[BEAT_COUNT_W-1:0];
                burst_beats<=take_beats;burst_left<=take_beats;
                m_axi_araddr<=row_address[ADDR_WIDTH-1:0];
                m_axi_arlen<=take_beats-1'b1;m_axi_arsize<=$clog2(BYTES_PER_BEAT);
                m_axi_arvalid<=1;m_axi_rready<=1;
            end
            if(m_axi_arvalid && m_axi_arready) begin m_axi_arvalid<=0;ar_issued<=1;end
            if(m_axi_rvalid && m_axi_rready) begin
                if(m_axi_rresp!=0 || m_axi_rid!=0 || m_axi_rlast!=(burst_left==1))axi_error<=1;
                beat_index<=beat_index+1'b1;
                burst_left<=burst_left-1'b1;
                beats_left<=beats_left-1'b1;
                row_address<=row_address+BYTES_PER_BEAT;
                if(burst_left==1) begin
                    ar_issued<=0;m_axi_rready<=0;
                    if(beats_left==1) begin
                        row_tag[active_bank]<=active_y;row_valid[active_bank]<=1;
                        row_cmd_done<=~row_cmd_done;busy<=0;
                    end
                end
            end
        end
    end
endmodule



