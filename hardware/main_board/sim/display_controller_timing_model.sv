// Timing model: production DDR bridge, CDC FIFOs, local and memory controllers.
// PHY returns one BL8 word after READ_LATENCY core clocks; no electrical/calibration model.
// Default payload is an address oracle; INTEGRITY=1 stores data by actual PHY bank/row/column.
`timescale 1ps/1ps
module display_controller_timing_model #(parameter PERF_PAYLOAD=0,STRIDE=3840,READ_LATENCY=8,BUF_BITS=5,COMMAND_DEPTH=256,CMD_QUANTUM=64,BANK_LSB=24,BANK_XOR_LSB=-1,INTEGRITY=0)(
 input wire clk,rst_n,service_pause,input wire [15:0] generation,
 input demo_bus_pkg::axi_req_t req,output demo_bus_pkg::axi_rsp_t rsp
);
 wire rst=!rst_n;
 reg core_clk=0;
 always #5000 core_clk=~core_clk;
wire  resetn;
wire [4-1:0] s_axi_awid;
reg [32-1:0] s_axi_awaddr;
reg [7:0] s_axi_awlen;
wire [2:0] s_axi_awsize;
wire [1:0] s_axi_awburst;
wire [0:0] s_axi_awlock;
wire [3:0] s_axi_awcache;
wire [2:0] s_axi_awprot;
wire [3:0] s_axi_awqos;
reg  s_axi_awvalid;
wire  s_axi_awready;
wire [128-1:0] s_axi_wdata;
wire [128/8-1:0] s_axi_wstrb;
reg  s_axi_wlast;
reg  s_axi_wvalid;
wire  s_axi_wready;
wire [4-1:0] s_axi_bid;
wire [1:0] s_axi_bresp;
wire  s_axi_bvalid;
wire  s_axi_bready;
reg [4-1:0] s_axi_arid;
reg [32-1:0] s_axi_araddr;
reg [7:0] s_axi_arlen;
wire [2:0] s_axi_arsize;
wire [1:0] s_axi_arburst;
wire [0:0] s_axi_arlock;
wire [3:0] s_axi_arcache;
wire [2:0] s_axi_arprot;
wire [3:0] s_axi_arqos;
reg  s_axi_arvalid;
wire  s_axi_arready;
wire [4-1:0] s_axi_rid;
wire [128-1:0] s_axi_rdata;
wire [1:0] s_axi_rresp;
wire  s_axi_rlast;
wire  s_axi_rvalid;
wire  s_axi_rready;
wire  axi_user_en;
wire [2:0] axi_user_cmd;
wire [28-1:0] axi_user_addr;
wire  axi_user_ready;
wire  axi_user_wren;
wire [128/8-1:0] axi_user_mask;
wire [128-1:0] axi_user_wdata;
wire  axi_user_end;
wire  axi_user_wrdy;
wire  axi_user_rd_valid;
wire [128-1:0] axi_user_rd_data;
wire  axi_user_rd_end;
wire  mc_user_ecc_err;
wire  mc_init_done;
wire  lb_user_en;
wire [2:0] lb_user_cmd;
wire [28-1:0] lb_user_addr;
wire  lb_user_ready;
wire  lb_user_wren;
wire [128-1:0] lb_user_wdata;
wire [16-1:0] lb_user_mask;
wire  lb_user_end;
wire  lb_user_wrdy;
wire [128-1:0] lb_user_rd_data;
wire  lb_user_rd_end;
wire  lb_user_rd_valid;
wire [BUF_BITS-1:0] wr_data_addr;
wire  wr_data_en;
wire  wr_data_offset;
wire [128-1:0] wr_data;
wire [16-1:0] wr_data_mask;
wire [128-1:0] rd_data;
wire [BUF_BITS-1:0] rd_data_addr;
wire  rd_data_en;
wire  rd_data_end;
wire  rd_data_offset;
wire [3-1:0] bank;
wire [2:0] cmd;
wire [10-1:0] col;
wire [BUF_BITS-1:0] data_buf_addr;
wire [1-1:0] rank;
wire [14-1:0] row;
wire  use_addr;
wire  accept_ns;
wire  accept;
wire [2-1:0] bank_mach_next;
wire [31:0] mc_debug_port;
wire  app_ref_req;
wire  app_zq_req;
wire  app_sr_req;
wire  app_sr_active;
wire  app_ref_ack;
wire  app_zq_ack;
wire [4-1:0] mc_ras_n;
wire [4-1:0] mc_cas_n;
wire [4-1:0] mc_we_n;
wire [4*14-1:0] mc_address;
wire [4*3-1:0] mc_bank;
wire [1*1*4-1:0] mc_cs_n;
wire [1:0] mc_odt;
wire [4-1:0] mc_cke;
wire  mc_reset_n;
wire [2*4*16-1:0] mc_wrdata;
wire [2*4*16/8-1:0] mc_wrdata_mask;
wire  mc_wrdata_en;
wire  mc_cmd_wren;
wire  mc_ctl_wren;
wire [2:0] mc_cmd;
wire [1:0] mc_cas_slot;
wire [3:0] mc_aux_out0;
wire [3:0] mc_aux_out1;
wire [1:0] mc_rank_cnt;
wire  phy_mc_ctl_full;
wire  phy_mc_cmd_full;
wire  phy_mc_data_full;
wire [2*4*16-1:0] phy_rd_data;
wire  phy_rddata_valid;
wire  cal_done;
reg [63:0] read_pipe;

function automatic [31:0] physical(input [31:0] addr);
 case(addr[31:28])
  1:physical=addr&32'h0fffffff;
  2:physical=(addr&32'h0fffffff)+32'h01400000;
  3:physical=(addr&32'h0fffffff)+32'h01000000;
  4:physical=(addr&32'h0fffffff)+32'h00800000;
  5:physical=(addr&32'h0fffffff)+32'h01800000;
  default:physical=addr;
 endcase
endfunction
assign s_axi_awid=req.awid;
assign s_axi_awaddr=physical(req.awaddr);
assign s_axi_awlen=req.awlen;
assign s_axi_awsize=req.awsize;
assign s_axi_awburst=req.awburst;
assign s_axi_awvalid=req.awvalid;
assign s_axi_wdata=req.wdata;
assign s_axi_wstrb=req.wstrb;
assign s_axi_wlast=req.wlast;
assign s_axi_wvalid=req.wvalid;
assign s_axi_bready=req.bready;
assign s_axi_arid=req.arid;
assign s_axi_araddr=physical(req.araddr);
assign s_axi_arlen=req.arlen;
assign s_axi_arsize=req.arsize;
assign s_axi_arburst=req.arburst;
assign s_axi_arvalid=req.arvalid;
assign s_axi_rready=req.rready;
assign s_axi_arlock='0;
assign s_axi_arcache='0;
assign s_axi_arprot='0;
assign s_axi_arqos='0;
assign s_axi_awlock='0;
assign s_axi_awcache='0;
assign s_axi_awprot='0;
assign s_axi_awqos='0;
assign resetn=rst_n;
assign mc_user_ecc_err=0;assign mc_init_done=rst_n;
assign app_ref_req=0;assign app_zq_req=0;assign app_sr_req=0;
assign phy_mc_ctl_full=service_pause;assign phy_mc_cmd_full=service_pause;assign phy_mc_data_full=0;
wire [127:0] integrity_data;
assign phy_rd_data=INTEGRITY ? integrity_data : 128'h12345678;
assign phy_rddata_valid=read_pipe[READ_LATENCY-1];assign cal_done=rst_n;
axi4_bus_ctl #(.AXI_ID(4), .AXI_AW(32), .AXI_DW(128), .MC_AW(28), .MC_DW(128), .CK_RATIO(4),.CMD_QUANTUM(CMD_QUANTUM)) u_axi (
    .aclk(clk),
    .aresetn(resetn),
    .s_axi_awid(s_axi_awid),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awlen(s_axi_awlen),
    .s_axi_awsize(s_axi_awsize),
    .s_axi_awburst(s_axi_awburst),
    .s_axi_awlock(s_axi_awlock),
    .s_axi_awcache(s_axi_awcache),
    .s_axi_awprot(s_axi_awprot),
    .s_axi_awqos(s_axi_awqos),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wlast(s_axi_wlast),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bid(s_axi_bid),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_arid(s_axi_arid),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arlen(s_axi_arlen),
    .s_axi_arsize(s_axi_arsize),
    .s_axi_arburst(s_axi_arburst),
    .s_axi_arlock(s_axi_arlock),
    .s_axi_arcache(s_axi_arcache),
    .s_axi_arprot(s_axi_arprot),
    .s_axi_arqos(s_axi_arqos),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rid(s_axi_rid),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rlast(s_axi_rlast),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .mc_user_en(axi_user_en),
    .mc_user_cmd(axi_user_cmd),
    .mc_user_addr(axi_user_addr),
    .mc_user_ready(axi_user_ready),
    .mc_user_wren(axi_user_wren),
    .mc_user_mask(axi_user_mask),
    .mc_user_wdata(axi_user_wdata),
    .mc_user_end(axi_user_end),
    .mc_user_wrdy(axi_user_wrdy),
    .mc_user_rd_valid(axi_user_rd_valid),
    .mc_user_rd_data(axi_user_rd_data),
    .mc_user_rd_end(axi_user_rd_end),
    .mc_user_ecc_err(mc_user_ecc_err),
    .mc_init_done(mc_init_done)
);
lb2_axi_clk #(.USER_DW(128), .USER_MW(16), .BANK_WIDTH(3), .COL_WIDTH(10), .RANK_WIDTH(1), .ROW_WIDTH(14), .ADDR_WIDTH(28),.COMMAND_DEPTH(COMMAND_DEPTH)) u_bridge (
    .axi_clk(clk),
    .core_clk(core_clk),
    .rstn(resetn),
    .axi_rstn(resetn),
    .axi_user_en(axi_user_en),
    .axi_user_cmd(axi_user_cmd),
    .axi_user_addr(axi_user_addr),
    .axi_user_ready(axi_user_ready),
    .axi_user_wren(axi_user_wren),
    .axi_user_wdata(axi_user_wdata),
    .axi_user_mask(axi_user_mask),
    .axi_user_end(axi_user_end),
    .axi_user_wrdy(axi_user_wrdy),
    .axi_user_rd_data(axi_user_rd_data),
    .axi_user_rd_end(axi_user_rd_end),
    .axi_user_rd_valid(axi_user_rd_valid),
    .lb_user_en(lb_user_en),
    .lb_user_cmd(lb_user_cmd),
    .lb_user_addr(lb_user_addr),
    .lb_user_ready(lb_user_ready),
    .lb_user_wren(lb_user_wren),
    .lb_user_wdata(lb_user_wdata),
    .lb_user_mask(lb_user_mask),
    .lb_user_end(lb_user_end),
    .lb_user_wrdy(lb_user_wrdy),
    .lb_user_rd_data(lb_user_rd_data),
    .lb_user_rd_end(lb_user_rd_end),
    .lb_user_rd_valid(lb_user_rd_valid)
);
local_bus_ctl #(.CK_RATIO(4), .USER_DW(128), .USER_MW(16), .BANK_WIDTH(3), .COL_WIDTH(10), .CWL(5), .BUF_AW(BUF_BITS), .RANKS(1), .RANK_WIDTH(1), .ROW_WIDTH(14), .ADDR_WIDTH(28),.BANK_LSB(BANK_LSB),.BANK_XOR_LSB(BANK_XOR_LSB)) u_local (
    .clk(core_clk),
    .rst(rst),
    .mc_user_en(lb_user_en),
    .mc_user_cmd(lb_user_cmd),
    .mc_user_addr(lb_user_addr),
    .mc_user_ready(lb_user_ready),
    .mc_user_wren(lb_user_wren),
    .mc_user_wdata(lb_user_wdata),
    .mc_user_mask(lb_user_mask),
    .mc_user_end(lb_user_end),
    .mc_user_wrdy(lb_user_wrdy),
    .mc_user_rd_data(lb_user_rd_data),
    .mc_user_rd_end(lb_user_rd_end),
    .mc_user_rd_valid(lb_user_rd_valid),
    .wr_data_addr(wr_data_addr),
    .wr_data_en(wr_data_en),
    .wr_data_offset(wr_data_offset),
    .wr_data(wr_data),
    .wr_data_mask(wr_data_mask),
    .rd_data(rd_data),
    .rd_data_addr(rd_data_addr),
    .rd_data_en(rd_data_en),
    .rd_data_end(rd_data_end),
    .rd_data_offset(rd_data_offset),
    .mc_bank(bank),
    .mc_cmd(cmd),
    .mc_col(col),
    .mc_data_buf_addr(data_buf_addr),
    .mc_rank(rank),
    .mc_row(row),
    .mc_use_addr(use_addr),
    .accept_ns(accept_ns)
);
memory_bus_ctl #(.BANK_WIDTH(3), .RANK_WIDTH(1), .ROW_WIDTH(14), .CK_RATIO(4), .BM_CNT_WIDTH(2), .BUF_AW(BUF_BITS), .BUF_OFTW(1), .RANKS(1), .RANK_RATIO(1), .COL_WIDTH(10), .CS_WIDTH(1), .PAYLOAD_WIDTH(16), .DATA_WIDTH(16), .DQ_WIDTH(16), .DQS_WIDTH(2), .CL(6), .CWL(5), .tCK(2500), .tCKE(7500), .tFAW(35000), .tRAS(35000), .tRCD(15000), .tREFI(7800000), .tRFC(350000), .tRP(15000), .tRRD(10000), .tRTP(10000), .tWTR(10000), .tZQI(128000000), .tZQCS(64)) u_mc (
    .clk(core_clk),
    .rst(rst),
    .cmd(cmd),
    .data_buf_addr(data_buf_addr),
    .bank(bank),
    .col(col),
    .rank(rank),
    .row(row),
    .use_addr(use_addr),
    .wr_data(wr_data),
    .wr_data_mask(wr_data_mask),
    .accept(accept),
    .accept_ns(accept_ns),
    .bank_mach_next(bank_mach_next),
    .rd_data(rd_data),
    .rd_data_addr(rd_data_addr),
    .rd_data_en(rd_data_en),
    .rd_data_end(rd_data_end),
    .rd_data_offset(rd_data_offset),
    .wr_data_addr(wr_data_addr),
    .wr_data_en(wr_data_en),
    .wr_data_offset(wr_data_offset),
    .mc_debug_port(mc_debug_port),
    .app_ref_req(app_ref_req),
    .app_zq_req(app_zq_req),
    .app_sr_req(app_sr_req),
    .app_sr_active(app_sr_active),
    .app_ref_ack(app_ref_ack),
    .app_zq_ack(app_zq_ack),
    .mc_ras_n(mc_ras_n),
    .mc_cas_n(mc_cas_n),
    .mc_we_n(mc_we_n),
    .mc_address(mc_address),
    .mc_bank(mc_bank),
    .mc_cs_n(mc_cs_n),
    .mc_odt(mc_odt),
    .mc_cke(mc_cke),
    .mc_reset_n(mc_reset_n),
    .mc_wrdata(mc_wrdata),
    .mc_wrdata_mask(mc_wrdata_mask),
    .mc_wrdata_en(mc_wrdata_en),
    .mc_cmd_wren(mc_cmd_wren),
    .mc_ctl_wren(mc_ctl_wren),
    .mc_cmd(mc_cmd),
    .mc_cas_slot(mc_cas_slot),
    .mc_aux_out0(mc_aux_out0),
    .mc_aux_out1(mc_aux_out1),
    .mc_rank_cnt(mc_rank_cnt),
    .phy_mc_ctl_full(phy_mc_ctl_full),
    .phy_mc_cmd_full(phy_mc_cmd_full),
    .phy_mc_data_full(phy_mc_data_full),
    .phy_rd_data(phy_rd_data),
    .phy_rddata_valid(phy_rddata_valid),
    .cal_done(cal_done)
);

 integer refreshes=0,cas_reads=0,cas_writes=0;
 generate if(INTEGRITY)begin:g_dram
  reg [127:0] memory[int unsigned];
  reg [13:0] bank_row[8];reg [7:0] opened=0;
  reg [127:0] data_pipe[64];
  integer whead=0,wtail=0;reg [26:0] write_addresses[16];
  assign integrity_data=data_pipe[READ_LATENCY-1];
  always @(posedge core_clk)begin
   if(rst)begin opened=0;whead=0;wtail=0;for(integer k=0;k<64;k++)data_pipe[k]<=0;end
   else begin
    for(integer k=1;k<64;k++)data_pipe[k]<=data_pipe[k-1];
    if(mc_wrdata_en)begin
     if(whead==wtail)$fatal(1,"PHY write payload without CAS");
     for(integer k=0;k<16;k++)if(!mc_wrdata_mask[k])memory[write_addresses[whead%16]][k*8+:8]=mc_wrdata[k*8+:8];
     whead++;
    end
    if(mc_ctl_wren)for(integer s=0;s<4;s++)if(!mc_cs_n[s])begin
     integer b;reg [13:0] a;reg [26:0] key;
     b=mc_bank[s*3+:3];a=mc_address[s*14+:14];
     key={3'(b),bank_row[b],a[9:0]}>>3;
     case({mc_ras_n[s],mc_cas_n[s],mc_we_n[s]})
      3'b011:begin if(opened[b])$fatal(1,"ACT to open bank");opened[b]=1;bank_row[b]=a;end
      3'b010:begin if(a[10])opened=0;else opened[b]=0;end
      3'b001:if(opened!=0)$fatal(1,"REF with open bank");
      3'b100:begin
       if(!opened[b])$fatal(1,"WRITE to closed bank");
       if(wtail-whead>=16)$fatal(1,"PHY write queue overflow");
       write_addresses[wtail%16]=key;wtail++;
      end
      3'b101:begin
       if(!opened[b] || !memory.exists(key))$fatal(1,"READ closed/uninitialized physical address %h",key);
       data_pipe[0]<=memory[key];
      end
      default:begin end
     endcase
    end
   end
  end
 end else assign integrity_data=0;endgenerate
 reg new_read;
 always @(posedge core_clk)begin
  new_read=0;
  if(!rst && mc_ctl_wren)for(integer i=0;i<4;i++)if(!mc_cs_n[i])begin
   case({mc_ras_n[i],mc_cas_n[i],mc_we_n[i]})
    3'b101:begin new_read=1;cas_reads++;end
    3'b100:cas_writes++;
    3'b001:refreshes++;
   endcase
  end
  if(rst)read_pipe<=0;else read_pipe<={read_pipe[62:0],new_read};
 end
 reg [7:0] model_payload[0:12799];
 initial if(PERF_PAYLOAD)$readmemh("common_model.hex",model_payload);
 reg [31:0] addrq[2];reg [8:0] leftq[2];reg [15:0] genq[2];
 reg head=0,tail=0;integer count=0;
 wire push=req.arvalid && s_axi_arready;
 wire pop=s_axi_rvalid && req.rready && s_axi_rlast;
 always @(posedge clk)begin
  if(rst)begin head<=0;tail<=0;count<=0;end
  else begin
   if(push)begin addrq[tail]<=req.araddr;leftq[tail]<={1'b0,req.arlen}+1'b1;genq[tail]<=generation;tail<=!tail;end
   if(s_axi_rvalid&&req.rready)begin
    if(count==0 || s_axi_rlast!=(leftq[head]==1))$fatal(1,"controller timing response framing");
    addrq[head]<=addrq[head]+16;leftq[head]<=leftq[head]-1;
   end
   if(pop)head<=!head;
   case({push,pop})2'b10:count<=count+1;2'b01:count<=count-1;endcase
  end
 end
 function automatic [15:0] pixel(input [31:0] a,input [15:0] gen);
  reg [31:0] off;integer source;
  source=a[31:28]==2;off=a-(source?32'h20000000:32'h10000000);
  pixel=16'h4000+16'h2000*16'(source)+16'h0080*16'(off/STRIDE)+16'((off%STRIDE)/2)+gen;
 endfunction
 always_comb begin
  rsp='0;
  rsp.arready=s_axi_arready;rsp.rvalid=s_axi_rvalid;rsp.rid=s_axi_rid;
  rsp.rlast=s_axi_rlast;rsp.rresp=s_axi_rresp;
  rsp.awready=s_axi_awready;rsp.wready=s_axi_wready;
  rsp.bvalid=s_axi_bvalid;rsp.bid=s_axi_bid;rsp.bresp=s_axi_bresp;
  if(PERF_PAYLOAD)begin
   rsp.rdata=0;
   for(integer i=0;i<16;i++)if(addrq[head]+i>=32'h01c00000 && addrq[head]+i<32'h01c03200)
    rsp.rdata[i*8+:8]=model_payload[addrq[head]+i-32'h01c00000];
  end
  else if(INTEGRITY)rsp.rdata=s_axi_rdata;
  else for(integer i=0;i<8;i++)rsp.rdata[i*16+:16]=pixel(addrq[head]+2*i,genq[head]);
 end
 final $display("DDR_TIMING CAS_R=%0d CAS_W=%0d REF=%0d PHY_LATENCY=%0d core_clocks",cas_reads,cas_writes,refreshes,READ_LATENCY);
endmodule
