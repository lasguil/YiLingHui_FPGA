// Project-specific paired replacement with lb2_axi_clk_stream.
// 128-bit aligned INCR bursts; two ordered reads, one write.
// Same public module/ports as the vendor block; original vendor source is retained.
module axi4_bus_ctl #(
parameter                       AXI_ID     = 4,
parameter                       AXI_AW     = 30,
parameter                       AXI_DW     = 32,
parameter                       MC_AW      = 30,
parameter                       MC_DW      = 32,
parameter                       BURST_MODE = "8",
parameter                       CK_RATIO   = 2,
parameter                       CMD_QUANTUM = 64
)
(
input  wire                     aclk,
input  wire                     aresetn,
// Slave Interface Write Address Ports
input  wire     [AXI_ID-1:0]    s_axi_awid,
input  wire     [AXI_AW-1:0]    s_axi_awaddr,
input  wire     [7:0]           s_axi_awlen,
input  wire     [2:0]           s_axi_awsize,
input  wire     [1:0]           s_axi_awburst,
input  wire     [0:0]           s_axi_awlock,
input  wire     [3:0]           s_axi_awcache,
input  wire     [2:0]           s_axi_awprot,
input  wire     [3:0]           s_axi_awqos,
input  wire                     s_axi_awvalid,
output wire                     s_axi_awready,
// Slave Interface Write Data Ports
input  wire     [AXI_DW-1:0]    s_axi_wdata,
input  wire     [AXI_DW/8-1:0]  s_axi_wstrb,
input  wire                     s_axi_wlast,
input  wire                     s_axi_wvalid,
output wire                     s_axi_wready,
// Slave Interface Write Response Ports
output wire     [AXI_ID-1:0]    s_axi_bid,
output wire     [1:0]           s_axi_bresp,
output wire                     s_axi_bvalid,
input  wire                     s_axi_bready,
// Slave Interface Read Address Ports
input  wire     [AXI_ID-1:0]    s_axi_arid,
input  wire     [AXI_AW-1:0]    s_axi_araddr,
input  wire     [7:0]           s_axi_arlen,
input  wire     [2:0]           s_axi_arsize,
input  wire     [1:0]           s_axi_arburst,
input  wire     [0:0]           s_axi_arlock,
input  wire     [3:0]           s_axi_arcache,
input  wire     [2:0]           s_axi_arprot,
input  wire     [3:0]           s_axi_arqos,
input  wire                     s_axi_arvalid,
output wire                     s_axi_arready,
// Slave Interface Read Data Ports
output wire     [AXI_ID-1:0]    s_axi_rid,
output wire     [AXI_DW-1:0]    s_axi_rdata,
output wire     [1:0]           s_axi_rresp,
output wire                     s_axi_rlast,
output wire                     s_axi_rvalid,
input  wire                     s_axi_rready,
// MC Master Interface
//CMD PORT
output wire                     mc_user_en,
output wire     [2:0]           mc_user_cmd,
output wire     [MC_AW-1:0]     mc_user_addr,
input  wire                     mc_user_ready,
//DATA PORT
output wire                     mc_user_wren,
output wire     [MC_DW/8-1:0]   mc_user_mask,
output wire     [MC_DW-1:0]     mc_user_wdata,
output wire                     mc_user_end,
input  wire                     mc_user_wrdy,
input  wire                     mc_user_rd_valid,
input  wire     [MC_DW-1:0]     mc_user_rd_data,
input  wire                     mc_user_rd_end,
input  wire                     mc_user_ecc_err,
input  wire                     mc_init_done
);
    // Calibration is generated in core_clk; never gate AXI combinationally with it.
    wire init_meta,init_ready;
    EFX_FF init_head(.D(mc_init_done),.CLK(aclk),.CE(1'b1),.SR(!aresetn),.Q(init_meta));
    EFX_FF init_tail(.D(init_meta),.CLK(aclk),.CE(1'b1),.SR(!aresetn),.Q(init_ready));
    reg write_active,read_active;
    reg [MC_AW-4:0] write_address,read_address;
    reg [8:0] write_left,issue_left;
    reg [AXI_ID-1:0] write_id;
    reg b_valid;
    reg [1:0] descriptor_count;
    reg descriptor_head,descriptor_tail;
    reg [AXI_ID-1:0] read_id[2];
    reg [8:0] return_left[2];
    // R storage and CDC are owned by lb2_axi_clk_stream; there is no second FIFO.
    reg [8:0] reserved;
    reg prefer_write;
    reg [$clog2(CMD_QUANTUM)-1:0] grant_count;
    assign s_axi_rdata=mc_user_rd_data;
    assign s_axi_rid=read_id[descriptor_head];
    assign s_axi_rvalid=aresetn && mc_user_rd_valid && descriptor_count!=0;
    assign s_axi_rlast=return_left[descriptor_head]==1;
    assign s_axi_rresp=2'b00;
    assign s_axi_bid=write_id;
    assign s_axi_bresp=2'b00;
    assign s_axi_bvalid=b_valid;
    assign s_axi_awready=aresetn && init_ready && !write_active && !b_valid;
    wire aw_push=s_axi_awvalid && s_axi_awready;
    wire ar_push=s_axi_arvalid && s_axi_arready;
    wire r_pop=s_axi_rvalid && s_axi_rready;
    wire descriptor_pop=r_pop && s_axi_rlast;
    wire read_candidate=read_active && reserved<248;
    wire write_candidate=write_active && s_axi_wvalid && mc_user_wrdy;
    wire select_write=write_candidate && (!read_candidate || prefer_write);
    wire command_valid=aresetn && init_ready && (select_write || read_candidate);
    wire issue=command_valid && mc_user_ready;
    wire write_issue=issue && select_write;
    wire read_issue=issue && !select_write;
    // The attached demo_axi_merge allows at most two read descriptors. Its
    // read_count increments with this bridge's descriptor_count on the same
    // downstream AR handshake, and it cannot present a third AR while full;
    // therefore descriptor_pop is not needed as a same-cycle ARREADY bypass.
    assign s_axi_arready=aresetn && init_ready &&
        (!read_active || (read_issue && issue_left==1)) &&
        (descriptor_count<2);
    // Write command and payload enter the combined transport queue together.
    // No extra 2 x 144-bit skid buffers: the AXI producer holds W until ready.
    assign mc_user_en=command_valid;
    assign mc_user_cmd=select_write ? 3'd0 : 3'd1;
    assign mc_user_addr=select_write ? {write_address,3'b000} : {read_address,3'b000};
    assign mc_user_wren=write_issue;
    assign mc_user_wdata=s_axi_wdata;
    assign mc_user_mask=~s_axi_wstrb;
    // Project transport contract: END carries RREADY toward the CDC bridge.
    // The bridge restores native write END=1 for every 128-bit DDR command.
    assign mc_user_end=s_axi_rready;
    // READY advertises a grantable slot; write_issue still commits the W payload.
    assign s_axi_wready=aresetn && init_ready && write_active && mc_user_wrdy && mc_user_ready && (!read_candidate || prefer_write);
    always @(posedge aclk or negedge aresetn)begin
        if(!aresetn)begin
            write_active<=0;read_active<=0;write_address<=0;read_address<=0;
            write_left<=0;issue_left<=0;write_id<=0;b_valid<=0;
            descriptor_count<=0;descriptor_head<=0;descriptor_tail<=0;
            read_id[0]<=0;read_id[1]<=0;return_left[0]<=0;return_left[1]<=0;
            reserved<=0;prefer_write<=0;grant_count<=0;
        end else begin
            if(b_valid && s_axi_bready)b_valid<=0;
            if(aw_push)begin
                write_active<=1;write_id<=s_axi_awid;
                write_address<=s_axi_awaddr >> 4;write_left<={1'b0,s_axi_awlen}+9'd1;
            end
            if(write_issue)begin
                write_address<=write_address+1'b1;write_left<=write_left-1'b1;
                if(write_left==1)begin write_active<=0;b_valid<=1;end
            end
            if(read_issue)begin
                read_address<=read_address+1'b1;issue_left<=issue_left-1'b1;
                if(issue_left==1)read_active<=0;
            end
            // Batch same-direction commands. Alternating every
            // beat makes the DDR scheduler pay excessive R/W turnarounds.
            if(issue)begin
                if(grant_count==CMD_QUANTUM-1 || (select_write ? write_left==1 : issue_left==1))begin
                    prefer_write<=!select_write;grant_count<=0;
                end else begin prefer_write<=select_write;grant_count<=grant_count+1'b1;end
            end
            if(r_pop)return_left[descriptor_head]<=return_left[descriptor_head]-1'b1;
            if(descriptor_pop)descriptor_head<=!descriptor_head;
            // Refill an issuer/descriptor on its final beat without a bubble.
            // On full-queue pop+push the new descriptor owns the replaced slot.
            if(ar_push)begin
                read_active<=1;read_address<=s_axi_araddr >> 4;issue_left<={1'b0,s_axi_arlen}+9'd1;
                read_id[descriptor_tail]<=s_axi_arid;
                return_left[descriptor_tail]<={1'b0,s_axi_arlen}+9'd1;
                descriptor_tail<=!descriptor_tail;
            end
            case({ar_push,descriptor_pop})
                2'b10:descriptor_count<=descriptor_count+1'b1;
                2'b01:descriptor_count<=descriptor_count-1'b1;
                default:begin end
            endcase
            case({read_issue,r_pop})
                2'b10:reserved<=reserved+1'b1;
                2'b01:reserved<=reserved-1'b1;
                default:begin end
            endcase
        end
    end
    // This replacement is intentionally scoped to the actual system masters.
    // Native completion is one beat; AXI LAST comes from descriptor lengths.
`ifndef SYNTHESIS
    initial begin
        if(AXI_DW!=128 || MC_DW!=128 || CK_RATIO!=4)$fatal(1,"Unsupported DDR stream configuration");
    end
    always @(posedge aclk)if(aresetn)begin
        if(aw_push && (s_axi_awsize!=4 || s_axi_awburst!=1 || s_axi_awaddr[3:0]!=0))$fatal(1,"Unsupported AW");
        if(ar_push && (s_axi_arsize!=4 || s_axi_arburst!=1 || s_axi_araddr[3:0]!=0))$fatal(1,"Unsupported AR");
        if(write_issue && s_axi_wlast!=(write_left==1))$fatal(1,"WLAST differs from AWLEN");
        if(mc_user_rd_valid && reserved==0)$fatal(1,"Unreserved native return/overflow");
    end
`endif
endmodule
