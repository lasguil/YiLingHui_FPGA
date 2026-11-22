// One row DMA serves two independent double-buffered pixel stores. Descriptors
// cross as held bundles; a source cannot overwrite its command before DONE.
module reference_display_axi_shared_reader #(
    parameter integer MAX_WIDTH=1920,AXI_DATA_WIDTH=128,ID_WIDTH=4,
    parameter integer MAX_BURST_BEATS=64, MAX_OUTSTANDING=1,
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
    output wire row_busy, output wire read_reserve,
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
    logic [INDEX_W-1:0] beats_left,beat_index,burst_left;
    logic ar_issued;
    wire pending_a=a_sync!=a_seen,pending_b=b_sync!=b_seen;
    // Serve the older source row first; equal rows favor A, whose split-view
    // pixels are consumed earlier. Compare only the stable pending descriptors.
    wire select_b=pending_a && pending_b ? (b_y<a_y) : pending_b;
    wire [INDEX_W-1:0] selected_first_beat=select_b ? b_first_beat : a_first_beat;
    wire accept=state==WAIT_CMD && (pending_a || pending_b);
    assign row_busy=state!=WAIT_CMD; assign read_reserve=row_busy;
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
            beats_left<=0;beat_index<=0;burst_left<=0;ar_issued<=0;
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
                    beat_index<=selected_first_beat;ar_issued<=0;state<=ROW_ADDR;
                end
            end
            // Register the descriptor before multiplication: no pixel-domain
            // selection/counter chain can be packed into the DSP input register.
            if(state==ROW_ADDR)begin
                row_address<=desc_base+active_y*desc_stride+active_first_beat*BYTES;state<=READ_ROW;
            end
            if(state==READ_ROW && !m_axi_arvalid && !ar_issued && beats_left!=0)begin
                logic [12:0] page_beats;
                logic [INDEX_W-1:0] take_beats;
                page_beats=(13'd4096-{1'b0,row_address[11:0]})/BYTES;
                take_beats=beats_left;
                if(take_beats>MAX_BURST_BEATS)take_beats=MAX_BURST_BEATS;
                if(take_beats>page_beats)take_beats=page_beats[INDEX_W-1:0];
                burst_left<=take_beats;m_axi_araddr<=row_address;
                m_axi_arlen<=take_beats-1'b1;m_axi_arsize<=$clog2(BYTES);
                m_axi_arvalid<=1;m_axi_rready<=1;
            end
            if(m_axi_arvalid && m_axi_arready)begin m_axi_arvalid<=0;ar_issued<=1;end
            if(write_valid)begin
                if(m_axi_rresp!=0 || m_axi_rid!=0 || m_axi_rlast!=(burst_left==1))begin
                    if(owner_b)error_b<=1;else error_a<=1;
                end
                beat_index<=beat_index+1'b1;burst_left<=burst_left-1'b1;
                beats_left<=beats_left-1'b1;row_address<=row_address+BYTES;
                if(burst_left==1)begin
                    ar_issued<=0;m_axi_rready<=0;
                    if(beats_left==1)begin
                        if(owner_b)b_done<=~b_done;else a_done<=~a_done;
                        state<=WAIT_CMD;
                    end
                end
            end
        end
    end
endmodule

