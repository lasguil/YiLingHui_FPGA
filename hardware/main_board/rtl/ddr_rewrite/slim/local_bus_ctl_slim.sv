//***************************************************************/
//   ______   _   _   _                  _            _
//  |  ____| | | (_) | |                | |          | |
//  | |__    | |  _  | |_    ___   ___  | |_    ___  | | __
//  |  __|   | | | | | __|  / _ \ / __| | __|  / _ \ | |/ /
//  | |____  | | | | | |_  |  __/ \__ \ | |_  |  __/ |   <  
//  |______| |_| |_|  \__|  \___| |___/  \__|  \___| |_|\_\
//
// Moudel Name    : ui_wrapper.v
// Version        : 1.1
// Date Created   : 2023-02-23 10:37:59
// Last Modified  : 2023-02-23 10:37:59
// Abstract       : ---
//
//Copyright (c) 2020-2023 Elitestek,Inc. All Rights Reserved.
//
//***************************************************************/
//Modification History
//1.initial
//***************************************************************/

`timescale 1 ps / 1 ps

module local_bus_ctl #(
parameter                       TCQ        = 100,
parameter                       CK_RATIO   = 2, 
parameter                       USER_DW    = 256,
parameter                       USER_MW    = 32,
parameter                       BANK_WIDTH = 3,
parameter                       COL_WIDTH  = 12,
parameter                       CWL        = 5,
parameter                       BUF_AW     = 5,
parameter                       RANKS      = 4,
parameter                       RANK_WIDTH = 2,
parameter                       ROW_WIDTH  = 16,
parameter                       ADDR_WIDTH = RANK_WIDTH + BANK_WIDTH + ROW_WIDTH + COL_WIDTH,
parameter                       MEM_ADDR_ORDER = "BANK_ROW_COLUMN",
// Keep software addresses unchanged: separate 4MiB frame slots across banks, 
// then XOR retained row bits into the bank to spread adjacent 2KiB chunks.
parameter                       BANK_LSB = COL_WIDTH+ROW_WIDTH-3,
parameter                       BANK_XOR_LSB = COL_WIDTH
)
(

input                           clk, 
input                           rst,   
input                           mc_user_en,  
input           [2:0]           mc_user_cmd,
input           [ADDR_WIDTH-1:0]mc_user_addr, 
output                          mc_user_ready, 

input                           mc_user_wren,   
input           [USER_DW-1:0]   mc_user_wdata,
input           [USER_MW-1:0]   mc_user_mask,
input                           mc_user_end,                                 
output                          mc_user_wrdy,  
   
output          [USER_DW-1:0]   mc_user_rd_data,      
output                          mc_user_rd_end,       
output                          mc_user_rd_valid,      

input           [BUF_AW-1:0]    wr_data_addr, 
input                           wr_data_en,             
input                           wr_data_offset,           
output wire     [USER_DW-1:0]   wr_data,          
output wire     [USER_MW-1:0]   wr_data_mask,     
input           [USER_DW-1:0]   rd_data,           
input           [BUF_AW-1:0]    rd_data_addr, 
input                           rd_data_en,             
input                           rd_data_end,            
input                           rd_data_offset,  

output          [BANK_WIDTH-1:0]mc_bank,                 
output          [2:0]           mc_cmd,                    
output          [COL_WIDTH-1:0] mc_col,                   
output          [BUF_AW-1:0]    mc_data_buf_addr,

output          [RANK_WIDTH-1:0]mc_rank,                           
output          [ROW_WIDTH-1:0] mc_row,                                   
output                          mc_use_addr,  
input                           accept_ns             

  );

// Paired ONLY with direct-mode memory_bus_ctl_slim and stream AXI/CDC.
// Native addresses count 16-bit words. One native request = one BL8 =128b.
wire [3:0] write_occupancy;
wire write_request=(mc_user_cmd==0);
wire write_space=(write_occupancy<8);
assign mc_user_ready=accept_ns&&(!write_request||write_space);
assign mc_user_wrdy=accept_ns&&write_space;
wire take=mc_user_en&&mc_user_ready;
wire push_write=take&&write_request;
wire [USER_DW+USER_MW-1:0] write_head;
ddr_slim_fifo #(.W(USER_DW+USER_MW),.DEPTH(8)) u_write_hold(
 .clk(clk),.rst(rst),.push(push_write),.pop(wr_data_en),
 .din({mc_user_wdata,mc_user_mask}),.dout(write_head),.count(write_occupancy));
assign {wr_data,wr_data_mask}=write_head;
generate if(BANK_XOR_LSB<0)begin:g_plain_bank
 assign mc_bank=mc_user_addr[BANK_LSB+:BANK_WIDTH];
end else begin:g_xor_bank
 assign mc_bank=mc_user_addr[BANK_LSB+:BANK_WIDTH]^mc_user_addr[BANK_XOR_LSB+:BANK_WIDTH];
end endgenerate
generate if(BANK_LSB==COL_WIDTH+ROW_WIDTH)begin:g_bank_high
 assign mc_row=mc_user_addr[COL_WIDTH+:ROW_WIDTH];
end else begin:g_bank_stripe
 assign mc_row={mc_user_addr[COL_WIDTH+ROW_WIDTH+BANK_WIDTH-1:BANK_LSB+BANK_WIDTH],mc_user_addr[BANK_LSB-1:COL_WIDTH]};
end endgenerate
assign mc_col=mc_user_addr[0+:COL_WIDTH];
assign mc_rank='0;
assign mc_cmd=mc_user_cmd;
assign mc_data_buf_addr='0;
assign mc_use_addr=take;
// Match the original controller's return stage: capture the PHY beat on its
// enable, then present it on the following clock.  Feeding the return through
// combinationally arrives one clock earlier than the downstream reservation
// accounting expects and shifts the whole read stream by a beat.
reg [USER_DW-1:0] rd_data_q;
reg rd_data_valid_q;
always @(posedge clk) begin
 if(rst) begin rd_data_q<='0;rd_data_valid_q<=0;end
 else begin
  rd_data_valid_q<=rd_data_en;
  if(rd_data_en)rd_data_q<=rd_data;
 end
end
assign mc_user_rd_data=rd_data_valid_q?rd_data_q:{USER_DW{1'bx}};
assign mc_user_rd_valid=rd_data_valid_q;
assign mc_user_rd_end=rd_data_valid_q?1'b1:1'bx;
`ifdef SIM_ASSERT
initial begin
 if(USER_DW!=128||USER_MW!=16||RANKS!=1||CK_RATIO!=4)$fatal(1,"unsupported slim local geometry");
 if(BANK_LSB<COL_WIDTH || BANK_LSB>COL_WIDTH+ROW_WIDTH)$fatal(1,"bank mapping outside row/bank region");
 if(BANK_XOR_LSB>=0 && (BANK_XOR_LSB<COL_WIDTH || BANK_XOR_LSB+BANK_WIDTH>BANK_LSB))$fatal(1,"bank XOR must use retained row bits");
end
always @(posedge clk)if(!rst)begin
 if(take&&mc_user_cmd>1)$fatal(1,"unsupported native opcode");
 if(push_write&&!mc_user_wren)$fatal(1,"write command/data must coincide");
 if(mc_user_wren&&!push_write)$fatal(1,"unmatched native write data");
 if(take&&mc_user_addr[ADDR_WIDTH-1])$fatal(1,"nonzero rank address");
end
`endif
endmodule
