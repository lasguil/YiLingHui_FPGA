//***************************************************************/
//   ______   _   _   _                  _            _
//  |  ____| | | (_) | |                | |          | |
//  | |__    | |  _  | |_    ___   ___  | |_    ___  | | __
//  |  __|   | | | | | __|  / _ \ / __| | __|  / _ \ | |/ /
//  | |____  | | | | | |_  |  __/ \__ \ | |_  |  __/ |   <  
//  |______| |_| |_|  \__|  \___| |___/  \__|  \___| |_|\_\
//
// Moudel Name    : memory_bus_ctl.v
// Version        : 1.0
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

`timescale 1ps/1ps

module memory_bus_ctl #(
parameter                       TCQ           = 100,        
parameter                       BANK_WIDTH    = 3, 
parameter                       RANK_WIDTH    = 2, 
parameter                       ROW_WIDTH     = 16, 
parameter                       CK_RATIO      = 4,            
parameter                       BM_CNT_WIDTH  = 2,
parameter                       BUF_AW        = 8,
parameter                       BUF_OFTW      = 1,
parameter                       ERR_AW        = 31,  
parameter                       RANKS         = 4,          
parameter                       RANK_RATIO    = 1,           
parameter                       COL_WIDTH     = 12,         
parameter                       CS_WIDTH      = 4, 
parameter                       PAYLOAD_WIDTH = 64,   
parameter                       DATA_WIDTH    = 64,         
parameter                       DQ_WIDTH      = 64,         
parameter                       DQS_WIDTH     = 8,
parameter                       BURST_MODE    = "8", 
parameter                       RTT_NOM       = "40",       
parameter                       RTT_WR        = "120", 
parameter                       ORDERING      = "NORM",     
parameter                       CL            = 5,         
parameter                       CWL           = 5,            
parameter                       tCK           = 2500 ,        
parameter                       tCKE          = 10000,        
parameter                       tFAW          = 40000,        
parameter                       tRAS          = 37500,       
parameter                       tRCD          = 12500,        
parameter                       tREFI         = 7800000,      
parameter                       tRFC          = 110000,       
parameter                       tRP           = 12500,       
parameter                       tRRD          = 10000,       
parameter                       tRTP          = 7500,         
parameter                       tWTR          = 7500,         
parameter                       tZQCS         = 64,           
parameter                       tZQI          = 128_000_000,  
parameter                       tPRDI         = 1_000_000   
)
(
input                           clk,
input                           rst,
input           [2:0]           cmd,
input           [BUF_AW-1:0]    data_buf_addr,
input           [BANK_WIDTH-1:0]bank,
input           [COL_WIDTH-1:0] col,
input           [RANK_WIDTH-1:0]rank,
input           [ROW_WIDTH-1:0] row,
input                           use_addr,
input           [2*CK_RATIO*PAYLOAD_WIDTH-1:0] 
                                wr_data,
input           [2*CK_RATIO*DATA_WIDTH/8-1:0]  
                                wr_data_mask,
output                          accept,
output                          accept_ns,
output          [BM_CNT_WIDTH-1:0]
                                bank_mach_next,
output  wire    [2*CK_RATIO*PAYLOAD_WIDTH-1:0] 
                                rd_data,
output          [BUF_AW-1:0]    rd_data_addr,
output                          rd_data_en,
output                          rd_data_end,
output          [BUF_OFTW-1:0]  rd_data_offset,   
output  wire    [BUF_AW-1:0]    wr_data_addr,
output  wire                    wr_data_en,
output  reg     [BUF_OFTW-1:0]  wr_data_offset,
output          [31:0]          mc_debug_port,
  
input                           app_ref_req,
input                           app_zq_req,
input                           app_sr_req,
output                          app_sr_active,
output                          app_ref_ack,
output                          app_zq_ack,   
output  reg     [CK_RATIO-1:0]  mc_ras_n,
output  reg     [CK_RATIO-1:0]  mc_cas_n,
output  reg     [CK_RATIO-1:0]  mc_we_n,
output  reg     [CK_RATIO*ROW_WIDTH-1:0]   
                                mc_address,
output  reg     [CK_RATIO*BANK_WIDTH-1:0]  
                                mc_bank,
output  reg     [CS_WIDTH*RANK_RATIO*CK_RATIO-1:0] 
                                mc_cs_n,
output  reg     [1:0]           mc_odt,
output  reg     [CK_RATIO-1:0]  mc_cke,
output  wire                    mc_reset_n,
output  wire    [2*CK_RATIO*DQ_WIDTH-1:0]  
                                mc_wrdata,
output  wire    [2*CK_RATIO*DQ_WIDTH/8-1:0]
                                mc_wrdata_mask,
output  wire                    mc_wrdata_en,
 
output                          mc_cmd_wren,
output                          mc_ctl_wren,
output  reg     [2:0]           mc_cmd,

output  reg     [1:0]           mc_cas_slot,
output  reg     [3:0]           mc_aux_out0,
output  reg     [3:0]           mc_aux_out1,
output  reg     [1:0]           mc_rank_cnt,
    
input                           phy_mc_ctl_full,
input                           phy_mc_cmd_full,
input                           phy_mc_data_full,
input           [2*CK_RATIO*DQ_WIDTH-1:0]
                                phy_rd_data,
input                           phy_rddata_valid,
input                           cal_done
    
  );
// Fixed board contract: one x16 rank, CK_RATIO=4, BL8, no self refresh.
// Must be paired with local_bus_ctl_slim and stream AXI/CDC.
// Local input: use_addr is an accepted request; cmd 0=write, 1=read. PHY codes differ.
parameter BANK_CTL_NUM=4;
localparam integer WORD=2*CK_RATIO*DQ_WIDTH, MASK=WORD/8;
localparam integer QW=1+BANK_WIDTH+ROW_WIDTH+COL_WIDTH;
function automatic integer cycles(input integer ps);
 cycles=(ps+CK_RATIO*tCK-1)/(CK_RATIO*tCK);
endfunction
localparam integer RCD=cycles(tRCD), RP=cycles(tRP), RAS=cycles(tRAS);
localparam integer RTP=cycles(tRTP), WPRE=cycles((CWL+4)*tCK+15000);
localparam integer WTR=cycles((CWL+4)*tCK+tWTR);
localparam integer RTW=cycles((CL+4+2-CWL)*tCK);
localparam integer RFC=cycles(tRFC), REFI=cycles(tREFI);
localparam integer RASW=$clog2(RAS+1), RCDW=$clog2(RCD+1), RPW=$clog2(RP+1);
wire [QW-1:0] head;
wire qread; wire [BANK_WIDTH-1:0] qb;
wire [ROW_WIDTH-1:0] qr; wire [COL_WIDTH-1:0] qc;
assign {qread,qb,qr,qc}=head;
wire [3:0] requests;
reg accept_q;
assign accept=accept_q;
assign accept_ns=cal_done&&!rst&&(requests<7);
// Paired slim local bus presents command/address/valid in the same cycle.
wire push=use_addr;
wire pop;
ddr_slim_fifo #(.W(QW),.DEPTH(8)) u_requests(
 .clk(clk),.rst(rst),.push(push),.pop(pop),
 .din({cmd[0],bank,row,col}),.dout(head),.count(requests));

reg [7:0] opened;
reg [ROW_WIDTH-1:0] open_row[0:7];
reg [RASW-1:0] ras_wait[0:7];
reg [RCDW-1:0] rcd_wait[0:7];
reg [RPW-1:0] rp_wait[0:7];
// Shared turnaround/recovery counters: conservative on row misses, no cost
// on sustained same-direction row hits. One CAS/core clock = full BL8 rate.
reg [2:0] pre_wait,read_wait,write_wait;
reg [$clog2(REFI+1)-1:0] refresh_timer;
reg refresh_due,zq_due;
// Periodic ZQCS uses the existing refresh cadence, not a wide 128 ms timer.
// 8192 refresh periods <64 ms, comfortably inside the configured 128 ms.
reg [12:0] zq_refresh_count;
localparam integer ACT_SPACING=cycles(tRRD>((tFAW+3)/4)?tRRD:((tFAW+3)/4));
reg [$clog2(ACT_SPACING+1)-1:0] activate_wait;
reg [2:0] maintenance;
reg [$clog2(RFC+1)-1:0] maintenance_wait;
wire ras_clear=(ras_wait[0]==0)&&(ras_wait[1]==0)&&(ras_wait[2]==0)&&(ras_wait[3]==0)&&
               (ras_wait[4]==0)&&(ras_wait[5]==0)&&(ras_wait[6]==0)&&(ras_wait[7]==0);
wire rp_clear=(rp_wait[0]==0)&&(rp_wait[1]==0)&&(rp_wait[2]==0)&&(rp_wait[3]==0)&&
              (rp_wait[4]==0)&&(rp_wait[5]==0)&&(rp_wait[6]==0)&&(rp_wait[7]==0);
wire phy_ready=!phy_mc_ctl_full&&!phy_mc_cmd_full;
reg [2:0] operation;
localparam OP_NOP=0,OP_PRE=1,OP_ACT=2,OP_RD=3,OP_WR=4,OP_PREALL=5,OP_REF=6,OP_ZQ=7;
wire [5:0] read_count;
wire [3:0] write_count;
reg wr1,wr2;
reg [1:0] read_odt_left,write_odt_left;
wire drained=(read_count==0)&&(write_count==0)&&!wr1&&!wr2;
always @* begin
 operation=OP_NOP;
 if(cal_done&&phy_ready) begin
  if(maintenance==1&&ras_clear&&pre_wait==0&&drained) operation=OP_PREALL;
  else if(maintenance==2&&maintenance_wait==0&&rp_clear) operation=refresh_due?OP_REF:OP_ZQ;
  else if(maintenance==0&&!refresh_due&&!zq_due&&requests!=0) begin
   if(opened[qb]&&open_row[qb]!=qr) begin
    if(ras_wait[qb]==0&&pre_wait==0) operation=OP_PRE;
   end else if(!opened[qb]) begin
    if(rp_wait[qb]==0&&activate_wait==0) operation=OP_ACT;
   end else if(rcd_wait[qb]==0) begin
    if(qread&&read_wait==0&&read_count<30&&write_count==0&&!wr1&&!wr2) operation=OP_RD;
    else if(!qread&&write_wait==0&&write_count<5&&!phy_mc_data_full) operation=OP_WR;
   end
  end
 end
end
assign pop=(operation==OP_RD)||(operation==OP_WR);
wire fire_write=operation==OP_WR, fire_read=operation==OP_RD;
wire read_return=phy_rddata_valid&&(read_count!=0);
reg [5:0] read_count_q;
assign read_count=read_count_q;
always @(posedge clk)begin
 if(rst)read_count_q<=0;
 else case({fire_read,read_return})
  2'b10:read_count_q<=read_count_q+1'b1;
  2'b01:read_count_q<=read_count_q-1'b1;
  default:;
 endcase
end
assign rd_data=phy_rd_data;
assign rd_data_en=read_return;
assign rd_data_end=1'b1;
assign rd_data_addr='0;
assign rd_data_offset='0;
// Stage the PHY payload.  Driving mc_wrdata combinationally from the local-bus
// store puts the first 16-bit transfer of every beat on the store's tap
// transition, which the PHY samples as garbage; one payload register removes the
// path.  Fetch one cycle after the CAS, present to the PHY the cycle after that,
// matching the original controller's write-data cadence.
wire data_valid;
wire fetch_write=(write_count!=0)&&(!data_valid||mc_wrdata_en);
assign wr_data_en=fetch_write;
assign wr_data_addr='0;
assign wr_data_offset='0;
wire [WORD+MASK-1:0] write_head;
reg data_valid_q;
reg [WORD+MASK-1:0] write_payload;
assign data_valid=data_valid_q;
// PHY contract experiment: full constrains NEW WR CAS admission above.
// A committed CAS retains its registered payload delivery cadence,
// matching the vendor MC public-port trace; no late payload cancellation.
assign mc_wrdata_en=data_valid;
reg [3:0] write_count_q;
assign write_count=write_count_q;
assign write_head={wr_data,wr_data_mask};
always @(posedge clk)begin
 if(rst)write_count_q<=0;
 else case({wr1,fetch_write})
  2'b10:write_count_q<=write_count_q+1'b1;
  2'b01:write_count_q<=write_count_q-1'b1;
  default:;
 endcase
end
always @(posedge clk)begin
 if(rst)begin data_valid_q<=0;write_payload<='0;end
 else begin
  if(mc_wrdata_en)data_valid_q<=0;
  if(fetch_write)begin write_payload<=write_head;data_valid_q<=1;end
 end
end
assign {mc_wrdata,mc_wrdata_mask}=write_payload;
// The PHY samples its command/control inputs every core clock; these write
// enables gate that capture, not the local queue's readiness.  Gating them with
// phy_ready drops command frames whenever the PHY asserts full, which shifts the
// whole read stream by a beat.  The original controller holds them asserted.
assign mc_cmd_wren=1'b1;
assign mc_ctl_wren=1'b1;
assign mc_reset_n=1'b1;
assign bank_mach_next='0;
assign app_sr_active=1'b0;
assign app_ref_ack=(maintenance==3);
assign app_zq_ack=(maintenance==4);
assign mc_debug_port={9'h14c,refresh_due,zq_due,maintenance,requests,read_count,write_count};
integer i;
always @(posedge clk) begin
 if(rst) begin
  accept_q<=0;opened<=0;pre_wait<=0;read_wait<=0;write_wait<=0;
  refresh_timer<=REFI-64;refresh_due<=1;zq_due<=0;zq_refresh_count<=0;activate_wait<=0;maintenance<=1;maintenance_wait<=0;
  wr1<=0;wr2<=0;read_odt_left<=0;write_odt_left<=0;
  mc_ras_n<='1;mc_cas_n<='1;mc_we_n<='1;mc_address<='1;mc_bank<='1;
  mc_cs_n<='1;mc_cke<='1;mc_odt<=0;mc_cmd<=4;mc_cas_slot<=1;
  mc_aux_out0<=0;mc_aux_out1<=0;mc_rank_cnt<=0;
  for(i=0;i<8;i=i+1) begin ras_wait[i]<=0;rcd_wait[i]<=0;rp_wait[i]<=0;end
 end else begin
  accept_q<=accept_ns;
  wr1<=fire_write;wr2<=wr1;
  if(phy_ready) begin
  for(i=0;i<8;i=i+1) begin
   if(ras_wait[i]!=0) ras_wait[i]<=ras_wait[i]-1'b1;
   if(rcd_wait[i]!=0) rcd_wait[i]<=rcd_wait[i]-1'b1;
   if(rp_wait[i]!=0) rp_wait[i]<=rp_wait[i]-1'b1;
  end
  if(activate_wait!=0)activate_wait<=activate_wait-1'b1;
  if(pre_wait!=0)pre_wait<=pre_wait-1'b1;
  if(read_wait!=0)read_wait<=read_wait-1'b1;
  if(write_wait!=0)write_wait<=write_wait-1'b1;
  if(maintenance_wait!=0)maintenance_wait<=maintenance_wait-1'b1;
  end
  if(cal_done) begin
   if(refresh_timer!=0)refresh_timer<=refresh_timer-1'b1;
   else refresh_due<=1;
   if(app_ref_req)refresh_due<=1;
   if(app_zq_req)zq_due<=1;
  end
  if(maintenance==0&&(refresh_due||zq_due))maintenance<=1;
  if((maintenance==3||maintenance==4)&&maintenance_wait==0)maintenance<=0;
  // Physical commands are in phase 1 for CAS, phase 0 for row/maintenance.
  // Aux/code constants are measured at the original controller's public port.
  if(phy_ready) begin
  mc_ras_n<='1;mc_cas_n<='1;mc_we_n<='1;mc_address<='1;mc_bank<='1;
  mc_cs_n<='1;mc_cmd<=4;mc_cas_slot<=1;mc_aux_out0<=0;mc_aux_out1<=0;
  // ODT aperture: assert on the CAS and hold for exactly three controller-clock
  // samples, matching the original controller.  Tying ODT to the outstanding
  // write level kept it asserted across an entire burst instead.
  if(write_odt_left!=0)write_odt_left<=write_odt_left-1'b1;
  if(read_odt_left!=0)read_odt_left<=read_odt_left-1'b1;
  if(operation==OP_WR)write_odt_left<=2'd3;
  if(operation==OP_RD)read_odt_left<=2'd3;
  mc_odt<=(operation==OP_WR||write_odt_left>1)?2'b11:
          (operation==OP_RD||read_odt_left>1)?2'b10:2'b00;
  case(operation)
   OP_ACT:begin
    mc_cs_n[0]<=0;mc_ras_n[0]<=0;mc_bank[0+:BANK_WIDTH]<=qb;mc_address[0+:ROW_WIDTH]<=qr;
    activate_wait<=ACT_SPACING-1;opened[qb]<=1;open_row[qb]<=qr;ras_wait[qb]<=RAS-1;rcd_wait[qb]<=RCD-1;
   end
   OP_PRE:begin
    mc_cs_n[0]<=0;mc_ras_n[0]<=0;mc_we_n[0]<=0;
    mc_bank[0+:BANK_WIDTH]<=qb;mc_address[0+:ROW_WIDTH]<=0;
    opened[qb]<=0;rp_wait[qb]<=RP-1;
   end
   OP_RD,OP_WR:begin
    mc_cs_n[1]<=0;mc_cas_n[1]<=0;mc_we_n[1]<=operation==OP_RD;
    mc_bank[BANK_WIDTH+:BANK_WIDTH]<=qb;
    mc_address[ROW_WIDTH+:ROW_WIDTH]<=ROW_WIDTH'(qc)|ROW_WIDTH'('h1000);
    mc_cmd<=operation==OP_RD?3'd3:3'd1;
    mc_aux_out0<=operation==OP_RD?4'h8:4'ha;mc_odt<=operation==OP_RD?2'b10:2'b11;
    if(operation==OP_RD)begin write_wait<=RTW-1;pre_wait<=RTP;end
    else begin read_wait<=WTR-1;pre_wait<=WPRE;end
   end
   OP_PREALL:begin
    mc_cs_n[0]<=0;mc_ras_n[0]<=0;mc_we_n[0]<=0;mc_address[0+:ROW_WIDTH]<=ROW_WIDTH'('h400);
    opened<=0;maintenance<=2;maintenance_wait<=RP-1;
   end
   OP_REF:begin
    mc_cs_n[0]<=0;mc_ras_n[0]<=0;mc_cas_n[0]<=0;
    maintenance<=3;maintenance_wait<=RFC-1;refresh_due<=0;refresh_timer<=REFI-64;
    zq_refresh_count<=zq_refresh_count+1'b1;
    if(&zq_refresh_count)zq_due<=1;
   end
   OP_ZQ:begin
    mc_cs_n[0]<=0;mc_we_n[0]<=0;mc_address[0+:ROW_WIDTH]<=0;
    maintenance<=4;maintenance_wait<=cycles(tZQCS*tCK)-1;zq_due<=0;zq_refresh_count<=0;
   end
   default:;
  endcase
  end
 end
end
`ifdef SIM_ASSERT
always @(posedge clk)if(!rst)begin
 if(push&&cmd>1)$fatal(1,"unsupported local command");
 if(phy_rddata_valid&&read_count==0)$fatal(1,"unexpected PHY read return");
 if(app_sr_req)$fatal(1,"self refresh is outside project contract");
end
`endif
endmodule
