// Combined command/write CDC; a single backpressured read-return FIFO.
// Paired with axi4_bus_ctl_stream only: axi_user_end carries AXI RREADY.
module lb2_axi_clk #(
parameter                       USER_DW    = 256,
parameter                       USER_MW    = 32,
parameter                       BANK_WIDTH = 3,
parameter                       COL_WIDTH  = 12,
parameter                       RANK_WIDTH = 2,
parameter                       ROW_WIDTH  = 16,
parameter                       ADDR_WIDTH = RANK_WIDTH + BANK_WIDTH + ROW_WIDTH + COL_WIDTH
)
(
input                           axi_clk, 
input                           core_clk, 
input                           rstn,   
input                           axi_rstn,   
input                           axi_user_en,  
input           [2:0]           axi_user_cmd,
input           [ADDR_WIDTH-1:0]axi_user_addr, 
output                          axi_user_ready, 

input                           axi_user_wren,   
input           [USER_DW-1:0]   axi_user_wdata,
input           [USER_MW-1:0]   axi_user_mask,
input                           axi_user_end,                                 
output                          axi_user_wrdy,  
   
output          [USER_DW-1:0]   axi_user_rd_data,      
output                          axi_user_rd_end,       
output                          axi_user_rd_valid, 

//----------------local bus----------------//
output                          lb_user_en,  
output          [2:0]           lb_user_cmd,
output          [ADDR_WIDTH-1:0]lb_user_addr, 
input                           lb_user_ready, 

output                          lb_user_wren,   
output          [USER_DW-1:0]   lb_user_wdata,
output          [USER_MW-1:0]   lb_user_mask,
output                          lb_user_end,                                 
input                           lb_user_wrdy,  
   
input           [USER_DW-1:0]   lb_user_rd_data,      
input                           lb_user_rd_end,       
input                           lb_user_rd_valid

);
    localparam PACKED_WIDTH=ADDR_WIDTH+1+USER_DW+USER_MW;
    wire command_full,command_empty;
    wire [PACKED_WIDTH-1:0] command_data;
    wire command_write=!command_data[USER_MW+USER_DW+ADDR_WIDTH];
    wire command_pop=!command_empty && lb_user_ready && (!command_write || lb_user_wrdy);
    wire command_push=axi_user_en && axi_user_ready &&
                      (axi_user_cmd==1 || axi_user_wren);
    assign axi_user_ready=!command_full;
    assign axi_user_wrdy=!command_full;
    assign lb_user_cmd=command_write ? 3'd0 : 3'd1;
    assign lb_user_addr=command_data[USER_MW+USER_DW+:ADDR_WIDTH];
    assign lb_user_wdata=command_data[USER_MW+:USER_DW];
    assign lb_user_mask=command_data[0+:USER_MW];
    assign lb_user_en=!command_empty && (!command_write || lb_user_wrdy);
    assign lb_user_wren=command_pop && command_write;
    assign lb_user_end=1'b1;
    wire reset_all=!rstn || !axi_rstn;
    efx_fifo_wrapper #(.SYNC_CLK(0),.MODE("FWFT"),.DEPTH(256),.DATA_WIDTH(PACKED_WIDTH)) u_command_write_fifo(
        .a_rst_i(reset_all),.a_wr_rst_i(!axi_rstn),.a_rd_rst_i(!rstn),
        .clk_i(1'b0),.wr_clk_i(axi_clk),.rd_clk_i(core_clk),
        .wr_en_i(command_push),.rd_en_i(command_pop),
        .wdata({axi_user_cmd[0],axi_user_addr,axi_user_wdata,axi_user_mask}),.rdata(command_data),
        .full_o(command_full),.empty_o(command_empty),.almost_full_o(),.prog_full_o(),.overflow_o(),.wr_ack_o(),
        .datacount_o(),.wr_datacount_o(),.almost_empty_o(),.prog_empty_o(),.underflow_o(),.rd_valid_o(),.rd_datacount_o());
    wire return_full,return_empty;
    // Two-beat elastic prefetch breaks the consumer RREADY -> BRAM RE path.
    // Its fetch depends only on registered occupancy, never on external RREADY.
    wire [USER_DW-1:0] return_data;
    wire [3:0] prefetch_count;
    wire prefetch=!return_empty && prefetch_count<2;
    assign axi_user_rd_valid=prefetch_count!=0;
    ddr_slim_fifo #(.W(USER_DW),.DEPTH(8)) u_read_prefetch(
        .clk(axi_clk),.rst(!axi_rstn),.push(prefetch),
        .pop(axi_user_rd_valid && axi_user_end),.din(return_data),
        .dout(axi_user_rd_data),.count(prefetch_count));
    assign axi_user_rd_end=1'b1;
    efx_fifo_wrapper #(.SYNC_CLK(0),.MODE("FWFT"),.DEPTH(256),.DATA_WIDTH(USER_DW)) u_return_fifo(
        .a_rst_i(reset_all),.a_wr_rst_i(!rstn),.a_rd_rst_i(!axi_rstn),
        .clk_i(1'b0),.wr_clk_i(core_clk),.rd_clk_i(axi_clk),
        .wr_en_i(lb_user_rd_valid),.rd_en_i(prefetch),
        .wdata(lb_user_rd_data),.rdata(return_data),
        .full_o(return_full),.empty_o(return_empty),.almost_full_o(),.prog_full_o(),.overflow_o(),.wr_ack_o(),
        .datacount_o(),.wr_datacount_o(),.almost_empty_o(),.prog_empty_o(),.underflow_o(),.rd_valid_o(),.rd_datacount_o());
`ifndef SYNTHESIS
    always @(posedge core_clk)if(rstn && lb_user_rd_valid && return_full)$fatal(1,"Return reservation violated");
    always @(posedge axi_clk)if(axi_rstn && command_push && axi_user_cmd>1)$fatal(1,"Unsupported native operation");
`endif
endmodule
