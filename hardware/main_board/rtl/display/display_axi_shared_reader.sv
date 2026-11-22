// One row DMA serves two independent double-buffered pixel stores. Descriptors
// cross as held bundles; a source cannot overwrite its command before DONE.
module display_axi_shared_reader #(
    parameter integer MAX_WIDTH=1920,AXI_DATA_WIDTH=128,ID_WIDTH=4,
    parameter integer MAX_BURST_BEATS=64,
    parameter integer MAX_OUTSTANDING=1,
    parameter integer INDEX_W=$clog2((MAX_WIDTH+AXI_DATA_WIDTH/16-1)/(AXI_DATA_WIDTH/16)+1)
)(
    input logic axi_clk,axi_rst_n,
    input logic a_toggle,b_toggle,
    input logic [31:0] a_base,b_base,
    input logic [15:0] a_stride,b_stride,
    input logic [11:0] a_width,b_width,a_y,b_y,
    input logic a_bank,b_bank,a_first,b_first,
    input logic [INDEX_W-1:0] a_first_beat,b_first_beat,
    output logic a_ack,b_ack,a_done,b_done,
    output logic error_a,error_b,
    output wire idle,
    output wire row_busy,
    output wire read_reserve,
    output wire row_start,row_done,row_source,row_bank,row_first,
    output wire [11:0] row_y,
    output wire write_valid,write_source,write_bank,
    output wire [INDEX_W-1:0] write_index,
    output wire [11:0] write_width,
    output logic [ID_WIDTH-1:0] m_axi_arid,
    output logic [31:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic m_axi_arvalid,
    input logic m_axi_arready,
    input logic [ID_WIDTH-1:0] m_axi_rid,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast,m_axi_rvalid,
    output logic m_axi_rready
);
    localparam integer LANES=AXI_DATA_WIDTH/16,BYTES=AXI_DATA_WIDTH/8;
    typedef enum logic [1:0] {WAIT_CMD,ROW_ADDR,READ_ROW} state_t;
    state_t state;
    (* async_reg="true" *) logic a_meta,a_sync,b_meta,b_sync;
    logic a_seen,b_seen,owner_b,active_bank;
    logic [31:0] desc_base,row_address;
    logic [15:0] desc_stride;
    logic [11:0] active_width,active_y;
    logic [INDEX_W-1:0] active_first_beat;
    logic [INDEX_W-1:0] beats_left,beat_index,issue_left;
    logic [INDEX_W-1:0] return_left[2];
    logic return_head,return_tail;
    logic [1:0] offered;
    wire offer=state==READ_ROW && !m_axi_arvalid && issue_left!=0 && offered<MAX_OUTSTANDING;
    wire pop_burst=write_valid && return_left[return_head]==1;
    wire pending_a=a_sync!=a_seen,pending_b=b_sync!=b_seen;
    // Serve the older source row first; equal rows favor A, whose split-view
    // pixels are consumed earlier. Compare only the stable pending descriptors.
    wire select_b=pending_a && pending_b ? (b_y<a_y) : pending_b;
    wire [INDEX_W-1:0] selected_first_beat=select_b ? b_first_beat : a_first_beat;
    wire accept=state==WAIT_CMD && (pending_a || pending_b);
    assign row_busy=state!=WAIT_CMD;
    // Reserve until every currently pending display descriptor is submitted.
    // A peer accepted after the final AR is ordered behind all of these reads.
    assign read_reserve=MAX_OUTSTANDING==1 ? row_busy :
        (pending_a || pending_b || (state!=WAIT_CMD && issue_left!=0));
    wire [11:0] selected_width=select_b ? b_width : a_width;
    wire [15:0] selected_stride=select_b ? b_stride : a_stride;
    wire good_command=selected_width!=0 && selected_width<=MAX_WIDTH && selected_stride!=0 && selected_first_beat<(selected_width+LANES-1)/LANES;
    assign idle=state==WAIT_CMD && !pending_a && !pending_b &&
        a_meta==a_seen && b_meta==b_seen && !m_axi_arvalid && !m_axi_rready;
    assign row_start=accept;
    assign row_first=accept && (select_b ? b_first : a_first);
    assign row_done=m_axi_rvalid && m_axi_rready && beats_left==1;
    assign row_source=accept ? select_b : owner_b;
    assign row_bank=accept ? (select_b ? b_bank : a_bank) : active_bank;
    assign row_y=accept ? (select_b ? b_y : a_y) : active_y;
    assign write_valid=m_axi_rvalid && m_axi_rready;
    assign write_source=owner_b;assign write_bank=active_bank;
    assign write_index=beat_index;assign write_width=active_width;
    always_ff @(posedge axi_clk or negedge axi_rst_n)begin
        if(!axi_rst_n)begin
            state<=WAIT_CMD;a_meta<=0;a_sync<=0;b_meta<=0;b_sync<=0;
            a_seen<=0;b_seen<=0;a_ack<=0;b_ack<=0;a_done<=0;b_done<=0;
            error_a<=0;error_b<=0;owner_b<=0;active_bank<=0;
            active_first_beat<=0;desc_base<=0;desc_stride<=0;active_width<=0;active_y<=0;row_address<=0;
            beats_left<=0;beat_index<=0;issue_left<=0;offered<=0;
            return_head<=0;return_tail<=0;return_left[0]<=0;return_left[1]<=0;
            m_axi_arid<=0;m_axi_araddr<=0;m_axi_arlen<=0;
            m_axi_arsize<=4;m_axi_arburst<=1;m_axi_arvalid<=0;m_axi_rready<=0;
        end else begin
            a_meta<=a_toggle;a_sync<=a_meta;b_meta<=b_toggle;b_sync<=b_meta;
            if(accept)begin
                if(select_b)begin b_seen<=b_sync;b_ack<=b_sync;end
                else begin a_seen<=a_sync;a_ack<=a_sync;end
                if(!good_command)begin
                    if(select_b)b_done<=~b_done;else a_done<=~a_done;
                end else begin
                    owner_b<=select_b;active_bank<=select_b ? b_bank : a_bank;
                    desc_base<=select_b ? b_base : a_base;desc_stride<=selected_stride;
                    active_width<=selected_width;active_y<=select_b ? b_y : a_y;
                    active_first_beat<=selected_first_beat;
                    beats_left<=(selected_width+LANES-1)/LANES-selected_first_beat;
                    issue_left<=(selected_width+LANES-1)/LANES-selected_first_beat;
                    beat_index<=selected_first_beat;return_head<=0;return_tail<=0;state<=ROW_ADDR;
                end
            end
            // Register the descriptor before multiplication: no pixel-domain
            // selection/counter chain can be packed into the DSP input register.
            if(state==ROW_ADDR)begin
                row_address<=desc_base+active_y*desc_stride+active_first_beat*BYTES;state<=READ_ROW;
            end
            if(offer)begin
                logic [12:0] page_beats;
                logic [INDEX_W-1:0] take_beats;
                page_beats=(13'd4096-{1'b0,row_address[11:0]})/BYTES;
                take_beats=issue_left;
                if(take_beats>MAX_BURST_BEATS)take_beats=MAX_BURST_BEATS;
                if(take_beats>page_beats)take_beats=page_beats[INDEX_W-1:0];
                // Allocate on presentation, before the delayed upstream ARREADY.
                // DDR may return its first beat together with that acknowledgement.
                return_left[return_tail]<=take_beats;return_tail<=!return_tail;
                m_axi_araddr<=row_address;
                m_axi_arlen<=take_beats-1'b1;m_axi_arsize<=$clog2(BYTES);
                m_axi_arvalid<=1;m_axi_rready<=1;
            end
            if(m_axi_arvalid && m_axi_arready)begin
                m_axi_arvalid<=0;
                issue_left<=issue_left-(INDEX_W'(m_axi_arlen)+1'b1);
                row_address<=row_address+((32'(m_axi_arlen)+1'b1)*BYTES);
            end
            case({offer,pop_burst})
                2'b10:offered<=offered+1'b1;
                2'b01:offered<=offered-1'b1;
                default:begin end
            endcase
            if(write_valid)begin
                if(m_axi_rresp!=0 || m_axi_rid!=0 || m_axi_rlast!=(return_left[return_head]==1))begin
                    if(owner_b)error_b<=1;else error_a<=1;
                end
                beat_index<=beat_index+1'b1;return_left[return_head]<=return_left[return_head]-1'b1;
                beats_left<=beats_left-1'b1;
                if(pop_burst)begin
                    return_head<=!return_head;
                    if(beats_left==1)begin
                        if(owner_b)b_done<=~b_done;else a_done<=~a_done;
                        state<=WAIT_CMD;m_axi_rready<=0;
                    end
                end
            end
        end
    end
endmodule

// Same RAM organization and pixel latency as display_axi_line_cache. Only DMA
// control moves out: each source still owns two complete, independent rows.
module display_axi_line_store #(
    parameter integer MAX_WIDTH=1920,AXI_DATA_WIDTH=128,
    parameter integer INDEX_W=$clog2((MAX_WIDTH+AXI_DATA_WIDTH/16-1)/(AXI_DATA_WIDTH/16)+1)
)(
    input logic axi_clk,axi_rst_n,pix_clk,pix_rst_n,
    input logic row_start,row_done,row_bank,row_first,
    input logic [11:0] row_y,
    input logic write_valid,write_bank,
    input logic [INDEX_W-1:0] write_index,
    input logic [11:0] write_width,
    input logic [AXI_DATA_WIDTH-1:0] write_data,
    input logic [11:0] pixel_x,pixel_y,
    input logic pixel_req,
    output logic [15:0] pixel_data,
    output logic pixel_valid,
    output logic [11:0] cached0_y,cached1_y,
    output logic [1:0] cached_valid
);
    localparam integer LANES=AXI_DATA_WIDTH/16;
    localparam integer MAX_BEATS=(MAX_WIDTH+LANES-1)/LANES;
    localparam integer BANK_ADDR_W=(MAX_BEATS>1) ? $clog2(MAX_BEATS) : 1;
    localparam integer BANK_DEPTH=1<<BANK_ADDR_W;
    logic [11:0] tags[2];logic [1:0] valid;
    (* async_reg="true" *) logic [11:0] tag0_meta,tag0_sync,tag1_meta,tag1_sync;
    (* async_reg="true" *) logic [1:0] valid_meta,valid_sync;
    logic [15:0] lane_data[LANES];
    wire read_bank=!(valid_sync[0] && tag0_sync==pixel_y);
    wire [BANK_ADDR_W:0] read_address={read_bank,pixel_x[BANK_ADDR_W+$clog2(LANES)-1:$clog2(LANES)]};
    wire [BANK_ADDR_W:0] write_address={write_bank,write_index[BANK_ADDR_W-1:0]};
    logic rd_valid,rd_bank;logic [11:0] rd_y;
    logic [$clog2(LANES)-1:0] rd_lane;
    always_ff @(posedge axi_clk or negedge axi_rst_n)begin
        if(!axi_rst_n)begin valid<=0;tags[0]<=0;tags[1]<=0;end
        else begin
            if(row_start)begin
                if(row_first)valid<=0;else valid[row_bank]<=0;
            end
            if(row_done)begin valid[row_bank]<=1;tags[row_bank]<=row_y;end
        end
    end
    for(genvar lane=0;lane<LANES;lane++)begin:g_lane
        logic [15:0] memory[2*BANK_DEPTH];
        always_ff @(posedge axi_clk)
            if(axi_rst_n && write_valid && write_index*LANES+lane<write_width)
                memory[write_address]<=write_data[lane*16+:16];
        always_ff @(posedge pix_clk)
            if(pixel_req && pixel_x<MAX_WIDTH)lane_data[lane]<=memory[read_address];
    end
    always_ff @(posedge pix_clk or negedge pix_rst_n)begin
        if(!pix_rst_n)begin
            tag0_meta<=0;tag0_sync<=0;tag1_meta<=0;tag1_sync<=0;
            valid_meta<=0;valid_sync<=0;cached0_y<=0;cached1_y<=0;cached_valid<=0;
            rd_valid<=0;rd_bank<=0;rd_y<=0;rd_lane<=0;
        end else begin
            tag0_meta<=tags[0];tag0_sync<=tag0_meta;tag1_meta<=tags[1];tag1_sync<=tag1_meta;
            valid_meta<=valid;valid_sync<=valid_meta;
            cached0_y<=tag0_sync;cached1_y<=tag1_sync;cached_valid<=valid_sync;
            rd_y<=pixel_y;rd_bank<=read_bank;rd_lane<=pixel_x[$clog2(LANES)-1:0];
            rd_valid<=pixel_req && pixel_x<MAX_WIDTH &&
                ((valid_sync[0] && tag0_sync==pixel_y) || (valid_sync[1] && tag1_sync==pixel_y));
        end
    end
    always_comb begin
        pixel_data=lane_data[rd_lane];
        pixel_valid=rd_valid && (rd_bank ? valid_sync[1] && tag1_sync==rd_y : valid_sync[0] && tag0_sync==rd_y);
    end
endmodule
