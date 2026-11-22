`include "video_profile.vh"
`include "ddr3_controller/ddr3_parameter.vh"

module ti60f225_oob_top #(
	parameter                       RANK_RATIO         = 1,       // # of unique CS outputs per rank
	parameter                       ASYN_AXI_CLK       = `ASYN_AXI_CLK, 
	parameter                       RANKS              = `RANKS,
	parameter                       CK_WIDTH           = `CK_WIDTH,       // # of CK/CK# outputs to memory   
	parameter                       CKE_WIDTH          = `CKE_WIDTH,       // # of cke outputs
	parameter                       CS_WIDTH           = `CS_WIDTH,       // # of unique CS outputs
	parameter                       BANK_WIDTH         = `BANK_WIDTH,       // # of bank bits
	parameter                       ROW_WIDTH          = `ROW_WIDTH,       // DRAM address bus width
	parameter                       COL_WIDTH          = `COL_WIDTH,      // column address width
	parameter                       DM_WIDTH           = `DM_WIDTH,       // # of DM (data mask)
	parameter                       DQS_WIDTH          = `DQS_WIDTH,       // # of DQS (strobe)
	parameter                       DQ_WIDTH           = `DQ_WIDTH,      // # of DQ (data)
	parameter                       ODT_WIDTH          = `ODT_WIDTH,
	parameter                       DQ_CNT_WIDTH       = `DQ_CNT_WIDTH,       // = ceil(log2(DQ_WIDTH))
	parameter                       DQS_CNT_WIDTH      = `DQS_CNT_WIDTH,       // = ceil(log2(DQS_WIDTH))  
	parameter                       DRAM_WIDTH         = `DRAM_WIDTH,       // # of DQ per DQS   
	parameter                       DATA_WIDTH         = `DATA_WIDTH,
	parameter                       ADDR_WIDTH         = `ADDR_WIDTH,    
	parameter                       AXI_ID_WIDTH       = `AXI_ID_WIDTH,
	parameter                       AXI_ADDR_WIDTH     = `AXI_ADDR_WIDTH,
	parameter                       AXI_DATA_WIDTH     = `AXI_DATA_WIDTH
)
(
   //Clocks 
	input	wire	i_arstn,
	// KEY3 on the demo board; active low, used as an internal video soft reset.
	input	wire	key3_n,
    // input   wire    i_soc_clk,
    input  wire CLK_25M,
	input 	wire  	pll_locked,
	output  wire  	USER_PLL_RSTN,
    output 	wire 	DDR3_PLL_RSTN,
	input 	wire  	user_pll_locked,
	input wire proc_clk,                 // NPU/DDR AXI/video processing clock @ 180MHz
	input wire proc_pll_locked,
	output wire proc_pll_RSTN,

	
	input 					tx_cal_clk_90edge,
  	input 					rx_cal_clk,
  	input 					tx_cal_clk,
	input                              core_clk,     // AXI / fabric @ 100MHz
	input                              sdram_clk,    // SDRAM CK @ 400MHz
	// PLL status flags  
	output [2:0]                       pll_shift,  
	output [4:0]                       pll_shift_sel,
	output                             pll_shift_ena,  
	// memory interface ports
	output                             ddr_ck_hi,
	output                             ddr_ck_lo,
	output                             ddr_reset_n,
	output [CKE_WIDTH-1:0]             ddr_cke,     
	output [ROW_WIDTH-1:0]             ddr_addr,
	output [BANK_WIDTH-1:0]            ddr_ba,
	output                             ddr_cas_n,
 
	output [CS_WIDTH*RANK_RATIO-1:0]   ddr_cs_n,
	output                             ddr_ras_n,
	output                             ddr_we_n,
	
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_hi,
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_lo,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_hi,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_lo,
	
	output [DQS_WIDTH-1:0]             ddr_dqs_oe,
	output [DQS_WIDTH-1:0]             ddr_dqs_oe_n,
	output [DQ_WIDTH-1:0]              ddr_dq_oe,  
	output [DQS_WIDTH-1:0]             ddr_dqs_out_hi,
	output [DQS_WIDTH-1:0]             ddr_dqs_out_lo,
	output [DQ_WIDTH-1:0]              ddr_dq_out_hi,
	output [DQ_WIDTH-1:0]              ddr_dq_out_lo,
	output [DM_WIDTH-1:0]              ddr_dm_hi,
	output [DM_WIDTH-1:0]              ddr_dm_lo,
	output [ODT_WIDTH-1:0]             ddr_odt,

       //LED
       output [7:0] led,


       // hdmi interface

    input wire i_cam_ck_LP_P_IN, i_cam_ck_LP_N_IN, i_cam_ck_CLKOUT,
    output wire o_cam_ck_HS_TERM, o_cam_ck_HS_ENA,
    input wire jtag_inst1_TCK,jtag_inst1_TDI,jtag_inst1_SEL,
    input wire jtag_inst1_CAPTURE,jtag_inst1_SHIFT,jtag_inst1_UPDATE,jtag_inst1_RESET,
    input wire jtag_inst1_DRCK,jtag_inst1_TMS,jtag_inst1_RUNTEST,
    output wire jtag_inst1_TDO,
    output wire system_uart_0_io_txd,
    input wire system_uart_0_io_rxd,
    output wire flash_cs_n, flash_clk, flash_mosi, flash_wp_n, flash_hold_n,
    input wire flash_miso,
    output wire gesture_uart_tx,
    input wire gesture_uart_rx,
    output tmds_tx_clk_TX_OE,
    output [9:0] tmds_tx_clk_TX_DATA,
    output tmds_tx_clk_TX_RST,
    output tmds_tx_data0_TX_OE,
    output [9:0] tmds_tx_data0_TX_DATA,
    output tmds_tx_data0_TX_RST,
    output tmds_tx_data1_TX_OE,
    output [9:0] tmds_tx_data1_TX_DATA,
    output tmds_tx_data1_TX_RST,
    output tmds_tx_data2_TX_OE,
    output [9:0] tmds_tx_data2_TX_DATA,
    output tmds_tx_data2_TX_RST,

    input wire hdmi_rx_slow_clk,
    input wire hdmi_rx_clk_RX_DATA,
    input wire [9:0] hdmi_rx_d0_RX_DATA,
    input wire [9:0] hdmi_rx_d1_RX_DATA,
    input wire [9:0] hdmi_rx_d2_RX_DATA,
    output wire hdmi_rx_clk_RX_ENA,
    output wire hdmi_rx_d0_RX_RST,
    output wire hdmi_rx_d0_RX_ENA,
    output wire hdmi_rx_d1_RX_RST,
    output wire hdmi_rx_d1_RX_ENA,
    output wire hdmi_rx_d2_RX_RST,
    output wire hdmi_rx_d2_RX_ENA,
    output wire hdmi_rx_clk_RX_DLY_INC,
    output wire hdmi_rx_clk_RX_DLY_ENA,
    output wire hdmi_rx_clk_RX_DLY_RST,
    input wire hdmi_rx_pll_LOCKED,
    output wire hdmi_rx_pll_RSTN,
    output wire HPD_N,
    input wire HDMI_5V_N,
    input wire FPGA_HDMI_SCL_IN,
    input wire FPGA_HDMI_SDA_IN,
    output wire FPGA_HDMI_SCL_OUT,
    output wire FPGA_HDMI_SCL_OE,
    output wire FPGA_HDMI_SDA_OUT,
    output wire FPGA_HDMI_SDA_OE,
    input wire rxc,
    input wire [3:0] rxd_hi_i,rxd_lo_i,
    input wire rx_dv_HI,rx_dv_LO,
    output wire [3:0] txd_hi_o,txd_lo_o,
    output wire tx_en_o_HI,tx_en_o_LO,txc_hi_o,txc_lo_o,
    output wire mdc_o,mdio_o,mdio_oe,phy_rst_n,
    input wire mdio_i
);

`include "ddr3_controller/ddr3_parameter.vh"
import demo_bus_pkg::*;

wire [7:0] soc_awid,soc_arid,soc_bid,soc_rid;
wire [31:0] soc_awaddr,soc_araddr,soc_wdata,soc_rdata; wire [3:0] soc_wstrb;
wire [7:0] soc_awlen,soc_arlen;wire [2:0] soc_awsize,soc_arsize;
wire [1:0] soc_awburst,soc_arburst,soc_bresp,soc_rresp;
wire soc_awvalid,soc_awready,soc_wvalid,soc_wready,soc_wlast,soc_bvalid,soc_bready;
wire soc_arvalid,soc_arready,soc_rvalid,soc_rready,soc_rlast;
wire soc_uart_txd;wire [3:0] gpio_out,gpio_oe;wire jtag_tdo_w;

wire rx_hsync,rx_vsync,rx_de;
wire [7:0] rdata_in,gdata_in,bdata_in;
wire [9:0] tx_symbol_blue,tx_symbol_green,tx_symbol_red;

wire arst_ok = i_arstn & user_pll_locked & pll_locked & proc_pll_locked;
assign USER_PLL_RSTN = i_arstn;
assign proc_pll_RSTN = i_arstn;
assign o_cam_ck_HS_TERM=1'b0, o_cam_ck_HS_ENA=1'b0;

// DDR calibration and CPU reset are independent of the HDMI receive path.
localparam CAL_TIMEOUT_BITS=25, CAL_RESET_BITS=11;
reg [CAL_TIMEOUT_BITS-1:0] cal_wait_cnt;
reg [CAL_RESET_BITS-1:0] cal_rst_cnt;
reg [2:0] cal_retry_cnt;
reg cal_rst_active, cal_retry_done;
wire cal_done, cal_pass;
wire cal_watchdog_rst_n=i_arstn & user_pll_locked & proc_pll_locked;
wire ddr3_rstn=arst_ok & ~cal_rst_active;
assign DDR3_PLL_RSTN=i_arstn & ~(cal_rst_active && cal_retry_cnt==3'd7);
always @(posedge core_clk or negedge cal_watchdog_rst_n) begin
    if (!cal_watchdog_rst_n) begin
        cal_wait_cnt<=0; cal_rst_cnt<=0; cal_retry_cnt<=0;
        cal_rst_active<=0; cal_retry_done<=0;
    end else if (cal_done || cal_retry_done) begin
        cal_rst_active<=0; cal_rst_cnt<=0; cal_retry_done<=cal_done;
    end else if (cal_rst_active) begin
        if (&cal_rst_cnt) begin
            cal_rst_active<=0; cal_wait_cnt<=0;
            cal_retry_cnt<=cal_retry_cnt+1'b1;
        end else cal_rst_cnt<=cal_rst_cnt+1'b1;
    end else if (&cal_wait_cnt) begin
        cal_rst_active<=1; cal_rst_cnt<=0;
    end else cal_wait_cnt<=cal_wait_cnt+1'b1;
end

wire cpu_reset_n, proc_cdc_reset_n, proc_reset_n, proc_ddr_ready, runtime_cal_lost;
wire cal_done_core;
gesture_clock_reset u_clock_reset(
    .core_clk(core_clk), .proc_clk(proc_clk), .async_reset_n(i_arstn),
    .core_pll_locked(user_pll_locked & pll_locked), .proc_pll_locked(proc_pll_locked),
    .cal_done(cal_done), .cpu_reset_n(cpu_reset_n),
    .proc_cdc_reset_n(proc_cdc_reset_n), .proc_reset_n(proc_reset_n),
    .proc_ddr_ready(proc_ddr_ready), .runtime_cal_lost(runtime_cal_lost),
    .cal_done_core(cal_done_core));

// All accelerator/video DDR clients run at 180MHz. Sapphire remains at 100MHz;
// its AXI-A path crosses through a request/response mailbox bridge. HDMI's
// recovered pixel clock is asynchronous and crosses only in capture.
axi_req_t client_req[5], ddr_req;
axi_rsp_t client_rsp[5], ddr_rsp;
wire ddr_idle;
demo_axi_merge #(.CLIENTS(5)) u_merge(
    .clk(proc_clk), .reset(!proc_reset_n), .ddr_ready(proc_ddr_ready),
    .display_urgent(1'b0), .capture_urgent(client_req[0].awvalid),
    .req(client_req), .rsp(client_rsp), .mem_req(ddr_req), .mem_rsp(ddr_rsp),
    .idle(ddr_idle));

wire [AXI_ID_WIDTH-1:0] s_axi_awid, s_axi_arid, s_axi_bid, s_axi_rid;
wire [AXI_ADDR_WIDTH-1:0] s_axi_awaddr, s_axi_araddr;
wire [7:0] s_axi_awlen, s_axi_arlen;
wire [2:0] s_axi_awsize, s_axi_arsize;
wire [1:0] s_axi_awburst, s_axi_arburst, s_axi_bresp, s_axi_rresp;
wire s_axi_awvalid,s_axi_awready,s_axi_wvalid,s_axi_wready,s_axi_wlast;
wire [AXI_DATA_WIDTH-1:0] s_axi_wdata,s_axi_rdata;
wire [AXI_DATA_WIDTH/8-1:0] s_axi_wstrb;
wire s_axi_bvalid,s_axi_bready,s_axi_arvalid,s_axi_arready,s_axi_rvalid,s_axi_rready,s_axi_rlast;
assign s_axi_awid=ddr_req.awid; assign s_axi_awaddr=ddr_req.awaddr;
assign s_axi_awlen=ddr_req.awlen; assign s_axi_awsize=ddr_req.awsize;
assign s_axi_awburst=ddr_req.awburst; assign s_axi_awvalid=ddr_req.awvalid;
assign s_axi_wdata=ddr_req.wdata; assign s_axi_wstrb=ddr_req.wstrb;
assign s_axi_wlast=ddr_req.wlast; assign s_axi_wvalid=ddr_req.wvalid;
assign s_axi_bready=ddr_req.bready; assign s_axi_arid=ddr_req.arid;
assign s_axi_araddr=ddr_req.araddr; assign s_axi_arlen=ddr_req.arlen;
assign s_axi_arsize=ddr_req.arsize; assign s_axi_arburst=ddr_req.arburst;
assign s_axi_arvalid=ddr_req.arvalid; assign s_axi_rready=ddr_req.rready;
assign ddr_rsp.awready=s_axi_awready; assign ddr_rsp.wready=s_axi_wready;
assign ddr_rsp.bid=s_axi_bid; assign ddr_rsp.bresp=s_axi_bresp;
assign ddr_rsp.bvalid=s_axi_bvalid; assign ddr_rsp.arready=s_axi_arready;
assign ddr_rsp.rid=s_axi_rid; assign ddr_rsp.rdata=s_axi_rdata;
assign ddr_rsp.rresp=s_axi_rresp; assign ddr_rsp.rlast=s_axi_rlast;
assign ddr_rsp.rvalid=s_axi_rvalid;

ddr3_top u_ddr3_top(
    .axi_clk(proc_clk), .core_clk(core_clk), .sdram_clk(sdram_clk),
    .rx_cal_clk(rx_cal_clk), .tx_cal_clk(tx_cal_clk),
    .tx_cal_clk_90edge(tx_cal_clk_90edge), .rstn(ddr3_rstn),
    .pll_shift(pll_shift), .pll_shift_sel(pll_shift_sel), .pll_shift_ena(pll_shift_ena),
    .ddr_ck_hi(ddr_ck_hi), .ddr_ck_lo(ddr_ck_lo), .ddr_cke(ddr_cke),
    .ddr_reset_n(ddr_reset_n), .ddr_cs_n(ddr_cs_n), .ddr_ras_n(ddr_ras_n),
    .ddr_cas_n(ddr_cas_n), .ddr_we_n(ddr_we_n), .ddr_addr(ddr_addr), .ddr_ba(ddr_ba),
    .ddr_dqs_oe(ddr_dqs_oe), .ddr_dqs_oe_n(ddr_dqs_oe_n), .ddr_dq_oe(ddr_dq_oe),
    .ddr_dqs_in_hi(ddr_dqs_in_hi), .ddr_dqs_in_lo(ddr_dqs_in_lo),
    .ddr_dq_in_hi(ddr_dq_in_hi), .ddr_dq_in_lo(ddr_dq_in_lo),
    .ddr_dqs_out_hi(ddr_dqs_out_hi), .ddr_dqs_out_lo(ddr_dqs_out_lo),
    .ddr_dq_out_hi(ddr_dq_out_hi), .ddr_dq_out_lo(ddr_dq_out_lo),
    .ddr_dm_hi(ddr_dm_hi), .ddr_dm_lo(ddr_dm_lo), .ddr_odt(ddr_odt),
    .app_sr_req(1'b0),.app_ref_req(1'b0),.app_zq_req(1'b0),
    .app_sr_active(),.app_ref_ack(),.app_zq_ack(),
    .s_axi_awid(s_axi_awid),.s_axi_awaddr(s_axi_awaddr),.s_axi_awlen(s_axi_awlen),
    .s_axi_awsize(s_axi_awsize),.s_axi_awburst(s_axi_awburst),.s_axi_awlock(1'b0),
    .s_axi_awcache(4'b0011),.s_axi_awprot(3'b010),.s_axi_awqos(4'h0),
    .s_axi_awvalid(s_axi_awvalid),.s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),.s_axi_wstrb(s_axi_wstrb),.s_axi_wlast(s_axi_wlast),
    .s_axi_wvalid(s_axi_wvalid),.s_axi_wready(s_axi_wready),
    .s_axi_bid(s_axi_bid),.s_axi_bresp(s_axi_bresp),.s_axi_bvalid(s_axi_bvalid),.s_axi_bready(s_axi_bready),
    .s_axi_arid(s_axi_arid),.s_axi_araddr(s_axi_araddr),.s_axi_arlen(s_axi_arlen),
    .s_axi_arsize(s_axi_arsize),.s_axi_arburst(s_axi_arburst),.s_axi_arlock(1'b0),
    .s_axi_arcache(4'b0011),.s_axi_arprot(3'b010),.s_axi_arqos(4'h0),
    .s_axi_arvalid(s_axi_arvalid),.s_axi_arready(s_axi_arready),
    .s_axi_rid(s_axi_rid),.s_axi_rdata(s_axi_rdata),.s_axi_rresp(s_axi_rresp),
    .s_axi_rlast(s_axi_rlast),.s_axi_rvalid(s_axi_rvalid),.s_axi_rready(s_axi_rready),
    .wrlvl_dq_check(),.rd_level_dqs_check(),.init_cur_state(),.idelay_ld(),
    .mpr_rdlvl_dly(),.cal_done(cal_done));

// Sapphire APB windows: 0xf8101000 (gesture), 0xf8102000 (video),
// 0xf8103000 (J7 UART), and 0xf8104000 (web/UART command mailbox).
wire [15:0] cpu_paddr;
wire net_reset_n;
wire cpu_psel,cpu_penable,cpu_pwrite;
wire [31:0] cpu_pwdata;
wire diag_select=(cpu_paddr[15:5]==0);
wire gesture_select=(cpu_paddr[15:12]==4'h1);
wire video_select=(cpu_paddr[15:12]==4'h2);
wire uart_select=(cpu_paddr[15:12]==4'h3);
wire web_select=(cpu_paddr[15:12]==4'h4);
wire flash_select=(cpu_paddr[15:12]==4'h5);
wire [31:0] diag_rdata, gesture_cpu_rdata, video_cpu_rdata, uart_cpu_rdata, web_cpu_rdata, flash_cpu_rdata;
wire diag_error=cpu_pwrite;
wire gesture_cpu_ready,gesture_cpu_error,video_cpu_ready,video_cpu_error;
wire uart_cpu_ready,uart_cpu_error;
wire web_cpu_ready,web_cpu_error;
wire flash_cpu_ready,flash_cpu_error;
(* async_reg = "true" *) reg capture_frame_valid_core_meta, capture_frame_valid_core;
(* async_reg = "true" *) reg npu_busy_core_meta, npu_busy_core;
always @(posedge core_clk or negedge cpu_reset_n) begin
    if (!cpu_reset_n) begin
        capture_frame_valid_core_meta<=1'b0;
        capture_frame_valid_core<=1'b0;
        npu_busy_core_meta<=1'b0;
        npu_busy_core<=1'b0;
    end else begin
        capture_frame_valid_core_meta<=capture_frame_valid;
        capture_frame_valid_core<=capture_frame_valid_core_meta;
        npu_busy_core_meta<=npu_busy;
        npu_busy_core<=npu_busy_core_meta;
    end
end
assign diag_rdata=(cpu_paddr[4:2]==0)?32'h47455354:
                  (cpu_paddr[4:2]==1)?{31'd0,cal_done_core}:
                  (cpu_paddr[4:2]==2)?{31'd0,capture_frame_valid_core}:
                  (cpu_paddr[4:2]==3)?{31'd0,npu_busy_core}:
                  32'h0;
wire [31:0] cpu_prdata=diag_select?diag_rdata:
                       gesture_select?gesture_cpu_rdata:
                       video_select?video_cpu_rdata:
                       uart_select?uart_cpu_rdata:
                       web_select?web_cpu_rdata:
                       flash_select?flash_cpu_rdata:32'h0;
wire cpu_pready=diag_select?1'b1:
                gesture_select?gesture_cpu_ready:
                video_select?video_cpu_ready:
                uart_select?uart_cpu_ready:
                web_select?web_cpu_ready:
                flash_select?flash_cpu_ready:1'b1;
wire cpu_pslverr=diag_select?diag_error:
                 gesture_select?gesture_cpu_error:
                 video_select?video_cpu_error:
                 uart_select?uart_cpu_error:
                 web_select?web_cpu_error:
                 flash_select?flash_cpu_error:1'b1;

flash_model_apb u_flash_model_apb(
    .clk(core_clk), .reset(!cpu_reset_n),
    .psel(cpu_psel && flash_select), .penable(cpu_penable),
    .pwrite(cpu_pwrite), .paddr(cpu_paddr[11:0]), .pwdata(cpu_pwdata),
    .prdata(flash_cpu_rdata), .pready(flash_cpu_ready), .pslverr(flash_cpu_error),
    .flash_cs_n(flash_cs_n), .flash_clk(flash_clk), .flash_mosi(flash_mosi),
    .flash_miso(flash_miso));
assign flash_wp_n = 1'b1;
assign flash_hold_n = 1'b1;

wire g_psel,g_penable,g_pwrite;
wire [11:0] g_paddr; wire [31:0] g_pwdata,g_prdata; wire g_pready,g_pslverr;
apb_csr_cdc g_apb_cdc(.s_clk(core_clk),.s_reset(!cpu_reset_n),
    .s_psel(cpu_psel&&gesture_select),.s_penable(cpu_penable),.s_pwrite(cpu_pwrite),
    .s_paddr(cpu_paddr[11:0]),.s_pwdata(cpu_pwdata),.s_prdata(gesture_cpu_rdata),
    .s_pready(gesture_cpu_ready),.s_pslverr(gesture_cpu_error),
    .m_clk(proc_clk),.m_reset(!proc_cdc_reset_n),.m_psel(g_psel),.m_penable(g_penable),
    .m_pwrite(g_pwrite),.m_paddr(g_paddr),.m_pwdata(g_pwdata),.m_prdata(g_prdata),
    .m_pready(g_pready && proc_ddr_ready),.m_pslverr(g_pslverr));

wire v_psel,v_penable,v_pwrite;
wire [11:0] v_paddr; wire [31:0] v_pwdata,v_prdata; wire v_pready,v_pslverr;
apb_csr_cdc v_apb_cdc(.s_clk(core_clk),.s_reset(!cpu_reset_n),
    .s_psel(cpu_psel&&video_select),.s_penable(cpu_penable),.s_pwrite(cpu_pwrite),
    .s_paddr(cpu_paddr[11:0]),.s_pwdata(cpu_pwdata),.s_prdata(video_cpu_rdata),
    .s_pready(video_cpu_ready),.s_pslverr(video_cpu_error),
    .m_clk(proc_clk),.m_reset(!proc_cdc_reset_n),.m_psel(v_psel),.m_penable(v_penable),
    .m_pwrite(v_pwrite),.m_paddr(v_paddr),.m_pwdata(v_pwdata),.m_prdata(v_prdata),
    .m_pready(v_pready && proc_ddr_ready),.m_pslverr(v_pslverr));

// Gesture result/ACK transport UART is deliberately separate from Sapphire's
// diagnostic UART and stays local to the 100 MHz CPU/APB clock domain.
gesture_uart u_gesture_uart(
    .clk(core_clk),.reset(!cpu_reset_n),
    .psel(cpu_psel && uart_select),.penable(cpu_penable),.pwrite(cpu_pwrite),
    .paddr(cpu_paddr[11:0]),.pwdata(cpu_pwdata),.prdata(uart_cpu_rdata),
    .pready(uart_cpu_ready),.pslverr(uart_cpu_error),
    .uart_rx(gesture_uart_rx),.uart_tx(gesture_uart_tx));

wire net_a_cmd_clk,net_a_cmd_valid,net_a_cmd_ready;
wire [31:0] net_a_cmd_token;
wire [7:0] net_a_cmd_type,net_a_cmd_length;
wire [431:0] net_a_cmd_payload;
wire net_a_status_valid;
wire [63:0] net_a_status_data;
web_control_mailbox u_web_control_mailbox(
    .net_clk(net_a_cmd_clk),.cpu_clk(core_clk),
    .arst(!cpu_reset_n || !net_reset_n),
    .cmd_valid(net_a_cmd_valid),.cmd_ready(net_a_cmd_ready),
    .cmd_token(net_a_cmd_token),.cmd_type(net_a_cmd_type),
    .cmd_length(net_a_cmd_length),.cmd_payload(net_a_cmd_payload),
    .psel(cpu_psel && web_select),.penable(cpu_penable),.pwrite(cpu_pwrite),
    .paddr(cpu_paddr[11:0]),.pwdata(cpu_pwdata),.prdata(web_cpu_rdata),
    .pready(web_cpu_ready),.pslverr(web_cpu_error),
    .net_status_valid(net_a_status_valid),.net_status_data(net_a_status_data));

wire [3:0] cpu_axi_awid,cpu_axi_bid;
wire [31:0] cpu_axi_awaddr,cpu_axi_araddr,cpu_axi_wdata,cpu_axi_rdata;
wire [7:0] cpu_axi_awlen,cpu_axi_arlen;
wire [2:0] cpu_axi_awsize,cpu_axi_arsize;
wire [1:0] cpu_axi_awburst,cpu_axi_arburst,cpu_axi_bresp,cpu_axi_rresp;
wire cpu_axi_awvalid,cpu_axi_awready,cpu_axi_wvalid,cpu_axi_wready,cpu_axi_wlast;
wire [3:0] cpu_axi_wstrb;
wire cpu_axi_bvalid,cpu_axi_bready,cpu_axi_arvalid,cpu_axi_arready,cpu_axi_rvalid,cpu_axi_rready,cpu_axi_rlast;
wire [3:0] cpu_axi_arid;
wire [127:0] cpu_ddr_rdata;
cpu_axi32_ddr128_cdc u_cpu_ddr_bridge(
 .s_clk(core_clk),.s_reset(!cpu_reset_n),.m_clk(proc_clk),.m_reset(!proc_cdc_reset_n),
 .m_enable(proc_ddr_ready),
 .s_awid(soc_awid),.s_awaddr(soc_awaddr),.s_awlen(soc_awlen),.s_awsize(soc_awsize),.s_awburst(soc_awburst),
 .s_awvalid(soc_awvalid),.s_awready(soc_awready),.s_wdata(soc_wdata),.s_wstrb(soc_wstrb),
 .s_wlast(soc_wlast),.s_wvalid(soc_wvalid),.s_wready(soc_wready),.s_bid(soc_bid),.s_bresp(soc_bresp),
 .s_bvalid(soc_bvalid),.s_bready(soc_bready),.s_arid(soc_arid),.s_araddr(soc_araddr),.s_arlen(soc_arlen),
 .s_arsize(soc_arsize),.s_arburst(soc_arburst),.s_arvalid(soc_arvalid),.s_arready(soc_arready),
 .s_rid(soc_rid),.s_rdata(soc_rdata),.s_rresp(soc_rresp),.s_rlast(soc_rlast),.s_rvalid(soc_rvalid),
 .s_rready(soc_rready),.m_req(client_req[3]),.m_rsp(client_rsp[3]));

wire [127:0] npu_diag_snapshot;
wire [7:0] npu_layer; wire npu_busy,npu_irq;
wire [3:0] npu_arid,npu_awid; wire [31:0] npu_araddr,npu_awaddr;
wire [7:0] npu_arlen,npu_awlen; wire [2:0] npu_arsize,npu_awsize;
wire [1:0] npu_arburst,npu_awburst; wire npu_arvalid,npu_arready,npu_rready;
wire [3:0] npu_rid,npu_bid; wire [127:0] npu_rdata,npu_wdata;
wire [1:0] npu_rresp,npu_bresp; wire npu_rlast,npu_rvalid;
wire npu_awvalid,npu_awready,npu_wlast,npu_wvalid,npu_wready,npu_bvalid,npu_bready;
wire [15:0] npu_wstrb;
gesture_top u_gesture(
 .dbg_snapshot(npu_diag_snapshot),
 .clk(proc_clk),.reset(!proc_reset_n),.apb_psel(g_psel),.apb_penable(g_penable),
 .apb_pwrite(g_pwrite),.apb_paddr(g_paddr),.apb_pwdata(g_pwdata),.apb_prdata(g_prdata),
 .apb_pready(g_pready),.apb_pslverr(g_pslverr),
 .m_axi_arid(npu_arid),.m_axi_araddr(npu_araddr),.m_axi_arlen(npu_arlen),.m_axi_arsize(npu_arsize),
 .m_axi_arburst(npu_arburst),.m_axi_arvalid(npu_arvalid),.m_axi_arready(npu_arready),
 .m_axi_rid(npu_rid),.m_axi_rdata(npu_rdata),.m_axi_rresp(npu_rresp),.m_axi_rlast(npu_rlast),
 .m_axi_rvalid(npu_rvalid),.m_axi_rready(npu_rready),.m_axi_awid(npu_awid),.m_axi_awaddr(npu_awaddr),
 .m_axi_awlen(npu_awlen),.m_axi_awsize(npu_awsize),.m_axi_awburst(npu_awburst),.m_axi_awvalid(npu_awvalid),
 .m_axi_awready(npu_awready),.m_axi_wdata(npu_wdata),.m_axi_wstrb(npu_wstrb),.m_axi_wlast(npu_wlast),
 .m_axi_wvalid(npu_wvalid),.m_axi_wready(npu_wready),.m_axi_bid(npu_bid),.m_axi_bresp(npu_bresp),
 .m_axi_bvalid(npu_bvalid),.m_axi_bready(npu_bready),.irq(npu_irq),.dbg_layer(npu_layer),.dbg_busy(npu_busy));
always_comb begin
    client_req[1]='0;
    client_req[1].arid=npu_arid;client_req[1].araddr=npu_araddr;client_req[1].arlen=npu_arlen;
    client_req[1].arsize=npu_arsize;client_req[1].arburst=npu_arburst;client_req[1].arvalid=npu_arvalid;
    client_req[1].rready=npu_rready;client_req[1].awid=npu_awid;client_req[1].awaddr=npu_awaddr;
    client_req[1].awlen=npu_awlen;client_req[1].awsize=npu_awsize;client_req[1].awburst=npu_awburst;
    client_req[1].awvalid=npu_awvalid;client_req[1].wdata=npu_wdata;client_req[1].wstrb=npu_wstrb;
    client_req[1].wlast=npu_wlast;client_req[1].wvalid=npu_wvalid;client_req[1].bready=npu_bready;
end
assign npu_arready=client_rsp[1].arready;assign npu_rid=client_rsp[1].rid;
assign npu_rdata=client_rsp[1].rdata;assign npu_rresp=client_rsp[1].rresp;
assign npu_rlast=client_rsp[1].rlast;assign npu_rvalid=client_rsp[1].rvalid;
assign npu_awready=client_rsp[1].awready;assign npu_wready=client_rsp[1].wready;
assign npu_bid=client_rsp[1].bid;assign npu_bresp=client_rsp[1].bresp;assign npu_bvalid=client_rsp[1].bvalid;

csr_req_t v_csr_req; csr_rsp_t v_csr_rsp;
wire capture_frame_valid,capture_slot,capture_overflow,capture_error,capture_video_lost;
wire mjpeg_frame_available;
wire [30:0] capture_seq,roi_selected_seq;
wire clear_capture_errors,roi_lock,roi_lock_slot;
wire net_lock,net_lock_slot;
wire net_available,net_busy,net_error,net_pixel_valid,net_pop,net_begin,net_end;
wire [15:0] net_pixel;
wire [31:0] net_frame_count;
wire net_stream_reset_n;
(* async_reg="true" *) reg [2:0] net_reset_pipe;
always @(posedge rxc or negedge i_arstn)
    if(!i_arstn)net_reset_pipe<=0;else net_reset_pipe<={net_reset_pipe[1:0],1'b1};
assign net_reset_n=net_reset_pipe[2];
(* async_reg="true" *) reg [6:0] net_status_meta,net_status_sync;
always @(posedge rxc or negedge i_arstn)
    if(!i_arstn)begin net_status_meta<=0;net_status_sync<=0;end
    else begin
    net_status_meta<={mjpeg_frame_available,cal_done,hdmi_rx_pll_LOCKED,!HDMI_5V_N,
                      capture_error,capture_overflow,capture_video_lost};
        net_status_sync<=net_status_meta;
    end

wire [31:0] frame0_base,frame1_base;
wire roi_busy,roi_done,roi_error;
axi_req_t capture_axi_req,roi_axi_req;
always_comb begin
    v_csr_req='0;
    v_csr_req.valid=v_psel && v_penable;
    v_csr_req.write=v_pwrite;
    v_csr_req.address=v_paddr;
    v_csr_req.wdata=v_pwdata;
    v_csr_req.wstrb=4'hf;
end
assign v_prdata=v_csr_rsp.rdata;assign v_pready=v_csr_rsp.ready;assign v_pslverr=v_csr_rsp.error;
gesture_frame_capture #(.AUTO_INPUT_MODE(1'b0)) u_capture(
 .net_lock(net_lock),.net_lock_slot(net_lock_slot),
 .proc_clk(proc_clk),.pclk(hdmi_rx_slow_clk),.reset(!proc_reset_n),
 .hdmi_vs(rx_vsync),.hdmi_de(rx_de),.hdmi_r(rdata_in),.hdmi_g(gdata_in),.hdmi_b(bdata_in),
 .frame0_base(frame0_base),.frame1_base(frame1_base),.roi_lock(roi_lock),.roi_lock_slot(roi_lock_slot),
 .clear_errors(clear_capture_errors),.frame_valid(capture_frame_valid),.published_slot(capture_slot),
 .published_seq(capture_seq),.overflow_sticky(capture_overflow),.error_sticky(capture_error),
 .video_lost(capture_video_lost),.axi_req(client_req[0]),.axi_rsp(client_rsp[0]));
gesture_roi_resize u_roi(
 .clk(proc_clk),.reset(!proc_reset_n),.csr_req(v_csr_req),.csr_rsp(v_csr_rsp),
 .frame_valid(capture_frame_valid),.published_slot(capture_slot),.published_seq(capture_seq),
 .capture_overflow(capture_overflow),.capture_error(capture_error),.capture_video_lost(capture_video_lost),
 .clear_capture_errors(clear_capture_errors),.roi_lock(roi_lock),.roi_lock_slot(roi_lock_slot),
 .frame0_base(frame0_base),.frame1_base(frame1_base),.axi_req(client_req[2]),.axi_rsp(client_rsp[2]),
 .busy(roi_busy),.done_sticky(roi_done),.error_sticky(roi_error),.selected_seq(roi_selected_seq));

// The 720p capture and encoder reader share DDR client 4. The existing
// 640x360 capture/ROI clients retain their separate buffers and ownership.
assign net_lock=1'b0, net_lock_slot=1'b0;
wire [23:0] mjpeg_rgb;
wire mjpeg_src_active,mjpeg_src_tvalid,mjpeg_src_tready,mjpeg_src_tlast,mjpeg_src_tuser;
wire mjpeg_jpg_valid,mjpeg_jpg_last;
wire [7:0] mjpeg_jpg_byte;
wire [8:0] mjpeg_fifo_data;
wire mjpeg_fifo_full,mjpeg_fifo_empty,mjpeg_fifo_write_empty;
wire mjpeg_overflow;
wire encoder_init_done;
wire mjpeg_source_overflow,mjpeg_source_error,mjpeg_source_frame_done;
wire [4:0] enc_awaddr,enc_araddr;
wire enc_awvalid,enc_awready,enc_wvalid,enc_wready,enc_bvalid,enc_bready;
wire [31:0] enc_wdata,enc_rdata;
wire [3:0] enc_wstrb;
wire [1:0] enc_bresp,enc_rresp;
wire enc_arvalid,enc_arready,enc_rvalid,enc_rready;
wire [1:0] enc_quality_unused;
wire mjpeg_start_toggle;
reg mjpeg_start_toggle_q;
(* async_reg="true" *) reg [2:0] mjpeg_start_sync;
(* async_reg="true" *) reg [1:0] mjpeg_error_sync,mjpeg_busy_sync;
(* async_reg="true" *) reg [1:0] mjpeg_source_overflow_sync,mjpeg_source_error_sync;
(* async_reg="true" *) reg [1:0] mjpeg_output_overflow_sync;
(* async_reg="true" *) reg [1:0] mjpeg_source_frame_sync;
reg mjpeg_source_frame_seen;
reg [31:0] mjpeg_source_frame_count;
wire mjpeg_start_pulse=mjpeg_start_sync[2]^mjpeg_start_sync[1];
reg mjpeg_overflow_sticky;
reg mjpeg_link_abort;
(* async_reg="true" *) reg [1:0] mjpeg_stream_up;
reg mjpeg_frame_active;
// Also hold the output while the FIFO's local reset release is in flight.
wire mjpeg_jpg_ready=mjpeg_stream_up[1]&&!mjpeg_fifo_full;
wire mjpeg_jpg_fire=mjpeg_jpg_valid&&mjpeg_jpg_ready;

// A link reset flushes the FIFO, not the DDR reader's outstanding AXI burst.
// Discard the interrupted frame through EOF before permitting another start.
always @(posedge proc_clk or negedge net_stream_reset_n)
    if(!net_stream_reset_n)mjpeg_stream_up<=0;
    else mjpeg_stream_up<={mjpeg_stream_up[0],1'b1};
always @(posedge proc_clk or negedge mjpeg_stream_up[1])
    if(!mjpeg_stream_up[1])mjpeg_link_abort<=1'b1;
    else if(!mjpeg_frame_active&&mjpeg_fifo_write_empty)mjpeg_link_abort<=1'b0;

always @(posedge net_a_cmd_clk or negedge net_reset_n)
    if(!net_reset_n)mjpeg_start_toggle_q<=1'b0;
    else if(net_begin)mjpeg_start_toggle_q<=~mjpeg_start_toggle_q;
assign mjpeg_start_toggle=mjpeg_start_toggle_q;
always @(posedge proc_clk or negedge proc_reset_n)
    if(!proc_reset_n)mjpeg_start_sync<=0;
    else mjpeg_start_sync<={mjpeg_start_sync[1:0],mjpeg_start_toggle};

// Count completed HDMI-source frames in the network clock domain. The source
// emits one toggle per captured frame; synchronize the toggle before counting
// so the webpage status does not cross a binary counter between domains.
always @(posedge net_a_cmd_clk or negedge net_reset_n)
    if(!net_reset_n)begin
        mjpeg_source_frame_sync<=0;
        mjpeg_source_frame_seen<=0;
        mjpeg_source_frame_count<=0;
    end else begin
        mjpeg_source_frame_sync<={mjpeg_source_frame_sync[0],mjpeg_source_frame_done};
        if(mjpeg_source_frame_sync[1]!=mjpeg_source_frame_seen)begin
            mjpeg_source_frame_seen<=mjpeg_source_frame_sync[1];
            mjpeg_source_frame_count<=mjpeg_source_frame_count+1'b1;
        end
    end
// Temporary hardware-trial diagnostics in register 0x0040:
// [5] DDR ready, [4] MJPEG busy, [3] pixel FIFO overflow,
// [2] DDR reader error, [1] JPEG FIFO backpressure observed, [0] video lost.
// Bit 1 is informational: output full now stalls rather than corrupting frames.
wire [5:0] net_board_status={net_status_sync[5],mjpeg_busy_sync[1],
                             mjpeg_source_overflow_sync[1],mjpeg_source_error_sync[1],
                             mjpeg_output_overflow_sync[1],net_status_sync[0]};

mjpeg_ddr_source #(.AUTO_INPUT_MODE(1'b0)) u_mjpeg_source(
    .pclk(hdmi_rx_slow_clk),.proc_clk(proc_clk),.reset(!proc_reset_n),
    .request(mjpeg_start_pulse&&encoder_init_done),
    .hdmi_vs(rx_vsync),.hdmi_de(rx_de),
    .hdmi_r(rdata_in),.hdmi_g(gdata_in),.hdmi_b(bdata_in),
    .tdata(mjpeg_rgb),.tvalid(mjpeg_src_tvalid),.tready(mjpeg_src_tready),
    .tlast(mjpeg_src_tlast),.tuser(mjpeg_src_tuser),
    .overflow_sticky(mjpeg_source_overflow),.source_error_sticky(mjpeg_source_error),
    .frame_done_toggle(mjpeg_source_frame_done),.frame_available(mjpeg_frame_available),
    .input_is_720p(),.input_mode_valid(),
    .axi_req(client_req[4]),.axi_rsp(client_rsp[4]));

axi_init u_mjpeg_axi_init(
    .clk(proc_clk),.rst_n(proc_reset_n),
    .m_axi_awaddr(enc_awaddr),.m_axi_awvalid(enc_awvalid),.m_axi_awready(enc_awready),
    .m_axi_wdata(enc_wdata),.m_axi_wstrb(enc_wstrb),.m_axi_wvalid(enc_wvalid),
    .m_axi_wready(enc_wready),.m_axi_bresp(enc_bresp),.m_axi_bvalid(enc_bvalid),.m_axi_bready(enc_bready),
    .m_axi_araddr(enc_araddr),.m_axi_arvalid(enc_arvalid),.m_axi_arready(enc_arready),
    .m_axi_rdata(enc_rdata),.m_axi_rresp(enc_rresp),.m_axi_rvalid(enc_rvalid),.m_axi_rready(enc_rready),
    .quality_req(1'b0),.quality_value(7'd75),.quality_busy(),.quality_done(),.init_done(encoder_init_done));

mjpegzero_enc_top #(.LITE_MODE(1),.LITE_QUALITY(75),.OUTPUT_BACKPRESSURE(1),.IMG_WIDTH(1280),.IMG_HEIGHT(720),
                    .RGB_INPUT(1),.HUFF_BANKS(8)) u_mjpegzero(
    .clk(proc_clk),.rst_n(proc_reset_n),
    .s_axis_vid_tdata(mjpeg_rgb),.s_axis_vid_tvalid(mjpeg_src_tvalid),
    .s_axis_vid_tready(mjpeg_src_tready),.s_axis_vid_tlast(mjpeg_src_tlast),.s_axis_vid_tuser(mjpeg_src_tuser),
    .m_axis_jpg_tready(mjpeg_jpg_ready),
    .m_axis_jpg_tvalid(mjpeg_jpg_valid),.m_axis_jpg_tdata(mjpeg_jpg_byte),.m_axis_jpg_tlast(mjpeg_jpg_last),
    .s_axi_awaddr(enc_awaddr),.s_axi_awvalid(enc_awvalid),.s_axi_awready(enc_awready),
    .s_axi_wdata(enc_wdata),.s_axi_wstrb(enc_wstrb),.s_axi_wvalid(enc_wvalid),.s_axi_wready(enc_wready),
    .s_axi_bresp(enc_bresp),.s_axi_bvalid(enc_bvalid),.s_axi_bready(enc_bready),
    .s_axi_araddr(enc_araddr),.s_axi_arvalid(enc_arvalid),.s_axi_arready(enc_arready),
    .s_axi_rdata(enc_rdata),.s_axi_rresp(enc_rresp),.s_axi_rvalid(enc_rvalid),.s_axi_rready(enc_rready));

always @(posedge proc_clk or negedge proc_reset_n)
    if(!proc_reset_n)mjpeg_overflow_sticky<=1'b0;
    else if(mjpeg_jpg_valid&&!mjpeg_jpg_ready)mjpeg_overflow_sticky<=1'b1;
always @(posedge proc_clk or negedge proc_reset_n)
    if(!proc_reset_n)mjpeg_frame_active<=1'b0;
    else if(mjpeg_start_pulse&&encoder_init_done)mjpeg_frame_active<=1'b1;
    else if(mjpeg_jpg_fire&&mjpeg_jpg_last)mjpeg_frame_active<=1'b0;

gesture_async_fifo #(.DATA_W(9),.ADDR_W(13)) u_mjpeg_fifo(
    .arst(!proc_reset_n || !net_stream_reset_n),.wclk(proc_clk),
    .wr_en(mjpeg_jpg_fire),.wr_data({mjpeg_jpg_last,mjpeg_jpg_byte}),
    .full(mjpeg_fifo_full),.write_empty(mjpeg_fifo_write_empty),.rclk(rxc),.rd_en(net_pop),
    .rd_data(mjpeg_fifo_data),.empty(mjpeg_fifo_empty));

always @(posedge net_a_cmd_clk or negedge net_stream_reset_n)
    if(!net_stream_reset_n)begin
        // Fail closed until both producer status synchronizers are populated.
        mjpeg_error_sync<=2'b11;mjpeg_busy_sync<=2'b11;
        mjpeg_source_overflow_sync<=0;mjpeg_source_error_sync<=0;
        mjpeg_output_overflow_sync<=0;
    end
    else begin
        // Invalid capture frames are never published. A capture overrun must
        // not abort encoding a different, pinned complete frame from DDR.
        mjpeg_error_sync<={mjpeg_error_sync[0],mjpeg_link_abort|mjpeg_source_error};
        mjpeg_busy_sync<={mjpeg_busy_sync[0],mjpeg_frame_active};
        mjpeg_source_overflow_sync<={mjpeg_source_overflow_sync[0],mjpeg_source_overflow};
        mjpeg_source_error_sync<={mjpeg_source_error_sync[0],mjpeg_source_error};
        mjpeg_output_overflow_sync<={mjpeg_output_overflow_sync[0],mjpeg_overflow_sticky};
    end
assign net_available=1'b1;
assign net_busy=mjpeg_busy_sync[1];
assign net_error=mjpeg_error_sync[1];
assign net_pixel_valid=!mjpeg_fifo_empty;
assign net_pixel={7'd0,mjpeg_fifo_data};
assign net_frame_count=mjpeg_source_frame_count;

udp_test_top #(.JPEG_MODE(1)) u_network(
 .rst_n(net_reset_n),.rxc(rxc),
 .source_mac_addr(48'h000a3501fec0),.TTL(8'h80),
 .source_ip_addr(32'hc0a80002),.destination_ip_addr(32'hc0a80003),
 .udp_send_source_port(16'd8080),.udp_send_destination_port(16'd5001),
 .rxd_hi_i(rxd_hi_i),.rxd_lo_i(rxd_lo_i),.rx_dv_HI(rx_dv_HI),.rx_dv_LO(rx_dv_LO),
 .txd_hi_o(txd_hi_o),.txd_lo_o(txd_lo_o),.tx_en_o_HI(tx_en_o_HI),.tx_en_o_LO(tx_en_o_LO),
 .txc_hi_o(txc_hi_o),.txc_lo_o(txc_lo_o),.mdc_o(mdc_o),.mdio_o(mdio_o),.mdio_oe(mdio_oe),
 .mdio_i(mdio_i),.phy_rst_n(phy_rst_n),
 // Geometry metadata is fixed at 1080p; frame health comes from live network status.
 .hd_frame_valid(net_status_sync[6]&&!net_status_sync[0]),.cap_available(net_available),
 .board_status(net_board_status),.hd_frame_cnt(net_frame_count),.hd_src_w(12'd1920),.hd_src_h(12'd1080),
 .hd_cap_using(),.cap_data(net_pixel),.cap_data_valid(net_pixel_valid),.cap_last(mjpeg_fifo_data[8]),.cap_error(net_error),
 .cap_busy(net_busy),.cap_pop(net_pop),.cap_rd_begin(net_begin),.cap_rd_end(net_end),
 .a_cmd_valid(net_a_cmd_valid),.a_cmd_ready(net_a_cmd_ready),.a_cmd_clk(net_a_cmd_clk),
 .a_cmd_token(net_a_cmd_token),.a_cmd_type(net_a_cmd_type),
 .a_cmd_length(net_a_cmd_length),.a_cmd_payload(net_a_cmd_payload),
 .a_status_valid(net_a_status_valid),.a_status_data(net_a_status_data),
 .stream_reset_n(net_stream_reset_n));

// HDMI RX-to-TX direct decoded-pixel path. The same RGB/DE/VS bus is tapped
// into capture; no frame buffer or overlay is inserted into the TX path.
reg [22:0] rx_wait_cnt,rx_lock_wait_cnt;
always @(posedge CLK_25M or negedge i_arstn)
    if(!i_arstn)begin rx_wait_cnt<=0;rx_lock_wait_cnt<=0;end
    else begin
        if(!HPD_N)begin if(!rx_wait_cnt[22])rx_wait_cnt<=rx_wait_cnt+1'b1;end else rx_wait_cnt<=0;
        if(!hdmi_rx_pll_LOCKED)begin if(rx_lock_wait_cnt[20])rx_lock_wait_cnt<=0;else rx_lock_wait_cnt<=rx_lock_wait_cnt+1'b1;end
        else rx_lock_wait_cnt<=0;
    end
assign hdmi_rx_pll_RSTN=rx_wait_cnt[22] && !rx_lock_wait_cnt[20] && i_arstn;
assign hdmi_rx_clk_RX_ENA=1'b1;assign hdmi_rx_d0_RX_ENA=1'b1;
assign hdmi_rx_d1_RX_ENA=1'b1;assign hdmi_rx_d2_RX_ENA=1'b1;
assign hdmi_rx_d0_RX_RST=1'b0;assign hdmi_rx_d1_RX_RST=1'b0;assign hdmi_rx_d2_RX_RST=1'b0;
assign tmds_tx_clk_TX_OE=1'b1;assign tmds_tx_data0_TX_OE=1'b1;
assign tmds_tx_data1_TX_OE=1'b1;assign tmds_tx_data2_TX_OE=1'b1;
assign tmds_tx_clk_TX_RST=1'b0;assign tmds_tx_data0_TX_RST=1'b0;
assign tmds_tx_data1_TX_RST=1'b0;assign tmds_tx_data2_TX_RST=1'b0;
hdmi_rx u_hdmi_rx(.cfg_clk(CLK_25M),.rst_n(i_arstn),.hdmi_rx_5v_n(HDMI_5V_N),.hdmi_rx_hpd_n(HPD_N),
 .scl_i(FPGA_HDMI_SCL_IN),.scl_o(FPGA_HDMI_SCL_OUT),.scl_oe(FPGA_HDMI_SCL_OE),
 .sda_i(FPGA_HDMI_SDA_IN),.sda_o(FPGA_HDMI_SDA_OUT),.sda_oe(FPGA_HDMI_SDA_OE));
board1_dvi_rx u_board1_dvi_rx(
 .pclk(hdmi_rx_slow_clk),.pll_locked(hdmi_rx_pll_LOCKED),
 .rx_blue(~hdmi_rx_d0_RX_DATA),.rx_green(~hdmi_rx_d1_RX_DATA),.rx_red(~hdmi_rx_d2_RX_DATA),
 .tx_blue(tx_symbol_blue),.tx_green(tx_symbol_green),.tx_red(tx_symbol_red),
 .hsync(rx_hsync),.vsync(rx_vsync),.de(rx_de),.red(rdata_in),.green(gdata_in),.blue(bdata_in),
 .rx_dly_inc(hdmi_rx_clk_RX_DLY_INC),.rx_dly_rst(hdmi_rx_clk_RX_DLY_RST),
 .rx_dly_ena(hdmi_rx_clk_RX_DLY_ENA),
 .debug_cal_done(),.debug_align_success(),.debug_de_sync_pass(),.debug_all_align(),
 .debug_bond_ready(),.debug_blue_ready(),.debug_green_ready(),.debug_red_ready(),
 .debug_b_align(),.debug_g_align(),.debug_r_align(),.debug_pass_open());
assign tmds_tx_clk_TX_DATA=10'h01f;
assign tmds_tx_data0_TX_DATA=~tx_symbol_blue;
assign tmds_tx_data1_TX_DATA=~tx_symbol_green;
assign tmds_tx_data2_TX_DATA=~tx_symbol_red;

assign led={runtime_cal_lost,roi_done,roi_busy,npu_busy,npu_irq,capture_overflow,capture_frame_valid,cal_done};

// Sapphire APB port and AXI-A master. AXI-A is restored to DDR through the
// narrow-beat adapter above; IDs are retained across serialized wide beats.
// Independent temporary status trace, alive when CPU waits on DDR/reset.
reg [25:0] diag_page_timer;
always @(posedge core_clk or negedge i_arstn)
    if(!i_arstn)diag_page_timer<=0;
    else diag_page_timer<=diag_page_timer+1'b1;
wire [1:0] diag_page=diag_page_timer[25:24];
wire [31:0] diag_word=diag_page==0?npu_diag_snapshot[31:0]:
                      diag_page==1?npu_diag_snapshot[63:32]:
                      diag_page==2?npu_diag_snapshot[95:64]:npu_diag_snapshot[127:96];
wire [63:0] independent_status={16'h4e50,6'd0,diag_page,
    i_arstn,user_pll_locked,proc_pll_locked,cal_done,
    cpu_reset_n,proc_reset_n,runtime_cal_lost,cal_done_core,diag_word};
demo_diag_uart #(.BIT_CLOCKS(868),.PERIOD_BITS(23)) u_npu_diag_uart(
    .clk(core_clk),.rst_n(i_arstn),.status_async(independent_status),
    .tx(system_uart_0_io_txd));
soc u_sapphire_soc(
 .io_systemClk(core_clk),.io_asyncReset(!cpu_reset_n),.io_systemReset(),
 .jtagCtrl_tck(jtag_inst1_TCK),.jtagCtrl_tdi(jtag_inst1_TDI),.jtagCtrl_tdo(jtag_tdo_w),
 .jtagCtrl_enable(jtag_inst1_SEL),.jtagCtrl_capture(jtag_inst1_CAPTURE),.jtagCtrl_shift(jtag_inst1_SHIFT),
 .jtagCtrl_update(jtag_inst1_UPDATE),.jtagCtrl_reset(jtag_inst1_RESET),
 .system_uart_0_io_txd(soc_uart_txd),.system_uart_0_io_rxd(system_uart_0_io_rxd),
 .system_gpio_0_io_write(gpio_out),.system_gpio_0_io_writeEnable(gpio_oe),
 .system_gpio_0_io_read({3'd0,key3_n}),
 .io_apbSlave_0_PADDR(cpu_paddr),.io_apbSlave_0_PSEL(cpu_psel),.io_apbSlave_0_PENABLE(cpu_penable),
 .io_apbSlave_0_PWRITE(cpu_pwrite),.io_apbSlave_0_PWDATA(cpu_pwdata),.io_apbSlave_0_PRDATA(cpu_prdata),
 .io_apbSlave_0_PREADY(cpu_pready),.io_apbSlave_0_PSLVERROR(cpu_pslverr),.userInterruptA(npu_irq),
 .axiA_awready(soc_awready),.axiA_awlen(soc_awlen),.axiA_awsize(soc_awsize),.axiA_awburst(soc_awburst),
 .axiA_awlock(),.axiA_awcache(),.axiA_awqos(),.axiA_awprot(),.axiA_awaddr(soc_awaddr),
 .axiA_awid(soc_awid),.axiA_awvalid(soc_awvalid),.axiA_wready(soc_wready),.axiA_wdata(soc_wdata),
 .axiA_wstrb(soc_wstrb),.axiA_wlast(soc_wlast),.axiA_wvalid(soc_wvalid),.axiA_bvalid(soc_bvalid),
 .axiA_bready(soc_bready),.axiA_bid(soc_bid),.axiA_bresp(soc_bresp),.axiA_arready(soc_arready),
 .axiA_arvalid(soc_arvalid),.axiA_araddr(soc_araddr),.axiA_arid(soc_arid),.axiA_arlen(soc_arlen),
 .axiA_arsize(soc_arsize),.axiA_arburst(soc_arburst),.axiA_arlock(),.axiA_arcache(),.axiA_arqos(),
 .axiA_arprot(),.axiA_rvalid(soc_rvalid),.axiA_rready(soc_rready),.axiA_rdata(soc_rdata),
 .axiA_rid(soc_rid),.axiA_rresp(soc_rresp),.axiA_rlast(soc_rlast),.axiAInterrupt(1'b0));
assign jtag_inst1_TDO=jtag_tdo_w;

endmodule
