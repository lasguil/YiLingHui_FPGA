
/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
//
// Description:
// Example top file for ti60f225 dev kit OOB design
//
// Language:  Verilog 2001
//
// ------------------------------------------------------------------------------

/////////////////////////////////////////////////////////////////////////////////
//`define SOFT_TAP 1
`include "ddr3_controller/ddr3_parameter.vh"
`include "vid_params.vh"
`include "isp_params.vh"
// `include "define.v"

module ti60f225_oob_top #(
    // Temporary DDR isolation. Set to 1 to restore the complete accelerator.
    parameter DEMO_ACCEL_ENABLE = 1,

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
    input wire ch9350_rx,
    // J7 B5 (GPIOL_10): one-way 115200-baud input from the second board.
    input wire gesture_uart_rx,
    // J7 B3 (GPIOL_04): optional 115200-baud ACK output to the second board.
    output wire gesture_uart_tx,
    input	wire	i_mipi_rx_pclk,
    input wire  vid_clk_dvi2,
    input wire hdmi_tx_slow_clk,
    // input   wire    i_soc_clk,
    input wire camera_cfg_clk,
    input  wire CLK_25M,
	output  wire    pll_inst1_RSTN,
	input	wire	i_pll_locked,
	input 	wire  	pll_locked,
	output  wire  	USER_PLL_RSTN,
    output 	wire 	DDR3_PLL_RSTN,
	input 	wire  	user_pll_locked,
    //CSI Interface
    input	 wire		io_cam_sda_IN,
    output wire   io_cam_sda_OUT,
    output wire		io_cam_sda_OE,

    output io_cam_scl_OUT,
    input io_cam_scl_IN,
    output io_cam_scl_OE,

    output	wire		o_cam_rst_p,
    
    input	wire		i_cam_ck_LP_P_IN,
    input	wire		i_cam_ck_LP_N_IN,
    output	wire		o_cam_ck_HS_TERM,
    output	wire		o_cam_ck_HS_ENA,
    input	wire		i_cam_ck_CLKOUT,
    
    input	wire	[7:0]			cam_d0_HS_IN,
    input	  wire		      cam_d0_LP_P_IN,
    input	  wire		      cam_d0_LP_N_IN,
    output	wire		      cam_d0_HS_TERM,
    output	wire		      cam_d0_HS_ENA,
    output	wire		      cam_d0_RST,
    output	wire		      cam_d0_FIFO_RD,
    input	  wire		      cam_d0_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d1_HS_IN,
    input	  wire		        cam_d1_LP_P_IN,
    input	  wire		        cam_d1_LP_N_IN,
    output	wire		        cam_d1_HS_TERM,
    output	wire		        cam_d1_HS_ENA,
    output	wire		        cam_d1_RST,
    output	wire		        cam_d1_FIFO_RD,
    input	  wire		        cam_d1_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d2_HS_IN,
    input	  wire		        cam_d2_LP_P_IN,
    input	  wire		        cam_d2_LP_N_IN,
    output	wire		        cam_d2_HS_TERM,
    output	wire		        cam_d2_HS_ENA,
    output	wire		        cam_d2_RST,
    output	wire		        cam_d2_FIFO_RD,
    input	  wire		        cam_d2_FIFO_EMPTY,  
   
    input 	wire	[7:0]			cam_d3_HS_IN,
    input	  wire		        cam_d3_LP_P_IN,
    input	  wire		        cam_d3_LP_N_IN,
    output	wire		        cam_d3_HS_TERM,
    output	wire		        cam_d3_HS_ENA,
    output	wire		        cam_d3_RST,
    output	wire		        cam_d3_FIFO_RD,
    input	  wire		        cam_d3_FIFO_EMPTY,

	
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

       // MIPI DSI
       input	wire	                     i_mipi_tx_pclk		,


       output	wire	                     LCD_RST_P			,
       output wire                        LCD_POWER			,

       // hdmi interface

    input wire proc_clk,
    input wire proc_pll_locked,
    output wire proc_pll_RSTN,
    input wire jtag_inst1_TCK,jtag_inst1_TDI,jtag_inst1_SEL,
    input wire jtag_inst1_CAPTURE,jtag_inst1_SHIFT,jtag_inst1_UPDATE,jtag_inst1_RESET,
    input wire jtag_inst1_DRCK,jtag_inst1_TMS,jtag_inst1_RUNTEST,
    output wire jtag_inst1_TDO,
    output wire system_uart_0_io_txd,
    input wire system_uart_0_io_rxd,
    output wire flash_cs_n,flash_clk,flash_mosi,
    input wire flash_miso,
    output wire flash_wp_n,flash_hold_n,
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
    output tmds_tx_data2_TX_RST


);



//===============================================================================
//localparam
//===============================================================================
// DDR area trial: 64-bit capture FIFO = 4 KiB; 128-bit preview FIFO = 8 KiB.
// Board contention/underflow qualification remains required before release.
localparam WR_FIFO_DEPTH  = 512;
localparam RD_FIFO_DEPTH  = 512;

localparam	MAX_HRES		= 12'd1920;
localparam	MAX_VRES		= 12'd1080;
// CTA-861 1920x1080p60 timing, expressed in full-pixel units.
// The frame buffer emits two pixels per vid_clk_dvi2 cycle, so horizontal
// values are divided by two at the frame-buffer instance below.
localparam	HSP			= 8'd44;
localparam	HBP			= 8'd148;
localparam	HFP			= 8'd88;
localparam	VSP			= 8'd5;
localparam	VBP			= 8'd36;
localparam	VFP			= 8'd4;
//===============================================================================
//signal
//===============================================================================
   
wire                              app_sr_active;
wire                              app_ref_ack;
wire                              app_zq_ack;
wire                              cal_done;
wire                              cal_pass;
// 180MHz accelerator/AXI domain; the DDR PHY/control core remains 100MHz.
wire proc_reset_n;
wire vid_path_rst_n,ddr3_rstn,csi_init_rst_n;
wire [1:0] store_mode_hold;
(* async_reg = "true" *) reg [2:0] proc_reset_pipe;
always @(posedge proc_clk or negedge vid_path_rst_n)
 if(!vid_path_rst_n)proc_reset_pipe<=0;
 else proc_reset_pipe<={proc_reset_pipe[1:0],ddr3_rstn};
assign proc_reset_n=proc_reset_pipe[2];
assign proc_pll_RSTN=i_arstn;
reg [1:0] ddr_ready_pipe;
always @(posedge proc_clk)begin
 if(!proc_reset_n)ddr_ready_pipe<=0;
 else ddr_ready_pipe<={ddr_ready_pipe[0],cal_done};
end
wire proc_ddr_ready=ddr_ready_pipe[1];
demo_bus_pkg::axi_req_t demo_req[4],ddr_req,npu_buffer_req;
demo_bus_pkg::axi_rsp_t demo_rsp[4],ddr_rsp,npu_buffer_rsp;
demo_bus_pkg::csr_req_t demo_csr_req;
demo_bus_pkg::csr_rsp_t demo_csr_rsp;
wire demo_boot_done,demo_boot_fault,demo_fault,demo_final_valid;
wire [15:0] demo_frames,camera_sequence;
wire [31:0] demo_final_base,demo_active_base,camera_latest_base;
wire [1:0] camera_locked_bank,camera_latest_bank,camera_latest_mode,demo_final_mode;
wire display_source_pending;
wire [1:0] display_source_pending_bank;
wire [1:0] mode_request;
wire mode_request_toggle;
wire camera_lock,capture_urgent,fb_axi_error;
wire [31:0] renderer_camera_base;
wire [1:0] renderer_camera_bank=renderer_camera_base==32'h003f5000 ? 2'd1 :
    renderer_camera_base==32'h007ea000 ? 2'd2 : renderer_camera_base==32'h00bdf000 ? 2'd3 : 2'd0;
wire soc_reset_n;
wire [15:0] diag_addr;
wire cpu_psel,cpu_penable,cpu_pwrite,cpu_control_ready,cpu_control_error,cpu_control_irq;
wire [31:0] cpu_pwdata,cpu_control_rdata;
wire diag_select=diag_addr[15:5]==0;
wire ch9350_select=diag_addr[15:8]==8'h06;
wire ch9350_ready,ch9350_error;
wire [31:0] ch9350_rdata;
wire gesture_uart_select=diag_addr[15:8]==8'h07;
wire gesture_uart_ready,gesture_uart_error;
wire [31:0] gesture_uart_rdata;
// checker0 keeps only its camera capture write channel, so client 0 is left
// with a free read channel and the display subsystem takes it. The retired
// scan-out outputs feed dead wires, so the read datapath drops out.
wire [3:0] fb_arid_u; wire [31:0] fb_araddr_u; wire [7:0] fb_arlen_u;
wire [2:0] fb_arsize_u; wire [1:0] fb_arburst_u; wire fb_arvalid_u,fb_rready_u;
wire [7:0] wrlvl_dq_check,rd_level_dqs_check;
wire [6:0] init_cur_state;
wire idelay_ld,mpr_rdlvl_dly;
reg [25:0] diag_core_count=0;
wire [3:0] gpio0_out,gpio0_oe;


// Slave Interface Write Address Ports
wire [AXI_ID_WIDTH-1:0]           s_axi_awid;
wire [AXI_ADDR_WIDTH-1:0]         s_axi_awaddr;
wire [7:0]                        s_axi_awlen;
wire [2:0]                        s_axi_awsize;
wire [1:0]                        s_axi_awburst;
wire [0:0]                        s_axi_awlock;
wire [3:0]                        s_axi_awcache;
wire [2:0]                        s_axi_awprot;
wire                              s_axi_awvalid;
wire                              s_axi_awready;
// Slave Interface Write Data Ports
wire [AXI_DATA_WIDTH-1:0]         s_axi_wdata;
wire [(AXI_DATA_WIDTH/8)-1:0]     s_axi_wstrb;
wire                              s_axi_wlast;
wire                              s_axi_wvalid;
wire                              s_axi_wready;
// Slave Interface Write Response Ports
wire                              s_axi_bready;
wire [AXI_ID_WIDTH-1:0]           s_axi_bid;
wire [1:0]                        s_axi_bresp;
wire                              s_axi_bvalid;
// Slave Interface Read Address Ports
wire [AXI_ID_WIDTH-1:0]           s_axi_arid;
wire [AXI_ADDR_WIDTH-1:0]         s_axi_araddr;
wire [7:0]                        s_axi_arlen;
wire [2:0]                        s_axi_arsize;
wire [1:0]                        s_axi_arburst;
wire [0:0]                        s_axi_arlock;
wire [3:0]                        s_axi_arcache;
wire [2:0]                        s_axi_arprot;
wire                              s_axi_arvalid;
wire                              s_axi_arready;
// Slave Interface Read Data Ports
wire                              s_axi_rready;
wire [AXI_ID_WIDTH-1:0]           s_axi_rid;
wire [AXI_DATA_WIDTH-1:0]         s_axi_rdata;
wire [1:0]                        s_axi_rresp;
wire                              s_axi_rlast;
wire                              s_axi_rvalid;




////////////////////////////////////////////////////////////////
// System & Debugger
wire    w_arstn;
wire	w_mipi_rx_pclk_arstn;
wire	w_mipi_rx_pclk_arst;

// KEY3 requests a safe geometry/FPS change. Do not reset the AXI frame buffer here:
// a mid-burst reset hangs the DDR controller until power-cycle, which
// is the persistent black after the first or second press.
wire video_soft_rst_n = 1'b1;


wire		       w_mipi_rx_vs;
wire		       w_mipi_rx_hs;
wire	       w_mipi_rx_de;
wire	[63:0]			w_mipi_rx_data	;
reg [31:0] csi_hs_byte_q;
reg [3:0] csi_fifo_empty_q;
reg csi_byte_input_valid_q;
wire [3:0] csi_fifo_empty_to_parser = csi_byte_input_valid_q ? csi_fifo_empty_q : 4'hf;



//===================================================================================================
//reset module
//===================================================================================================

assign w_arstn  		       = i_pll_locked & pll_locked & user_pll_locked & proc_pll_locked;
assign pll_inst1_RSTN  		= i_arstn;
assign USER_PLL_RSTN      		= i_arstn;
// MIPI TX PLL still exists in peri.xml because it also makes core_clk.
assign mipi_dsi_tx_pll_RSTN 	= i_arstn;
// DDR3_PLL_RSTN is driven by the calibration watchdog further down.
reset_ctrl
#(
	.NUM_RST		(2),
	.CYCLE			(1),
	.IN_RST_ACTIVE	(4'b00),
	.OUT_RST_ACTIVE	(4'b10)
)
inst_reset_ctrl
(
	.i_arst		({2{w_arstn}}),//({{4{i_pll_locked}},                  {2{i_arstn}}}),
	.i_clk			({2{i_mipi_rx_pclk}}),
	.o_srst		({w_mipi_rx_pclk_arst, w_mipi_rx_pclk_arstn})
);


// DDR3 calibration watchdog.
// Soft calibration on this board sometimes never asserts cal_done on the
// first configuration, so HDMI stays black until the chip is programmed
// again. Restart the controller (20.48 us pulse) if cal_done is still low
// after 335.54 ms; after 8 misses also pulse DDR3_PLL_RSTN. The watchdog
// runs from an independent PLL: losing DDR lock cannot shorten its pulse.
// Keep retrying until calibration succeeds. Frame buffer issues
// no AXI traffic before ddr_init_done, so a retry cannot hit a burst.
localparam CAL_TIMEOUT_BITS = 25;
localparam CAL_RESET_BITS   = 11;
localparam CAL_RETRY_LIMIT  = 3'd7;

reg [CAL_TIMEOUT_BITS-1:0] cal_wait_cnt;
reg [CAL_RESET_BITS-1:0]   cal_rst_cnt;
reg [2:0]                  cal_retry_cnt;
reg                        cal_rst_active;
reg                        cal_retry_done;
wire cal_watchdog_rst_n=i_arstn & i_pll_locked & user_pll_locked & proc_pll_locked;
assign ddr3_rstn = w_arstn & ~cal_rst_active;
assign DDR3_PLL_RSTN = i_arstn & ~(cal_rst_active && (cal_retry_cnt == CAL_RETRY_LIMIT));

always @(posedge core_clk or negedge cal_watchdog_rst_n) begin
  if (!cal_watchdog_rst_n) begin
    cal_wait_cnt   <= {CAL_TIMEOUT_BITS{1'b0}};
    cal_rst_cnt    <= {CAL_RESET_BITS{1'b0}};
    cal_retry_cnt  <= 3'd0;
    cal_rst_active <= 1'b0;
    cal_retry_done <= 1'b0;
  end else if (cal_done || cal_retry_done) begin
    cal_rst_active <= 1'b0;
    cal_rst_cnt    <= {CAL_RESET_BITS{1'b0}};
  end else if (cal_rst_active) begin
    if (&cal_rst_cnt) begin
      cal_rst_active <= 1'b0;
      cal_wait_cnt   <= {CAL_TIMEOUT_BITS{1'b0}};
      if (cal_retry_cnt == CAL_RETRY_LIMIT)
        cal_retry_cnt <= 3'd0;
      else
        cal_retry_cnt <= cal_retry_cnt + 1'b1;
    end else begin
      cal_rst_cnt <= cal_rst_cnt + 1'b1;
    end
  end else if (&cal_wait_cnt) begin
    cal_rst_active <= 1'b1;
    cal_rst_cnt    <= {CAL_RESET_BITS{1'b0}};
  end else begin
    cal_wait_cnt <= cal_wait_cnt + 1'b1;
  end
end

// FIFO diagnostics.  LED0 is a latched capture-FIFO overflow indication.
// LED1 indicates that a complete DDR frame is available.
wire cap_fifo_overflow;
wire rd_fifo_full_seen;
wire fb_write_done;
wire csi_fifo_overflow;
// Mode 3 reuses 480p geometry; FPS is controlled separately.
wire [1:0] camera_mode_active;
reg [1:0] active_mode_meta, active_mode_pix;
always @(posedge hdmi_tx_slow_clk or negedge w_arstn) begin
 if(!w_arstn)begin active_mode_meta<=1;active_mode_pix<=1;end
 else begin active_mode_meta<=camera_mode_active;active_mode_pix<=active_mode_meta;end
end
wire [1:0] scale_mode=(active_mode_pix==2'd3) ? 2'd2 : active_mode_pix;
wire camera_capture_ready, camera_mode_switching,sensor_ae_fault;
wire camera_rx_enable,camera_config_ready;
wire [1:0] mode_active_proc_meta,mode_active_proc;
wire mode_switch_proc_meta,mode_switch_proc,mode_fault_proc_meta,mode_fault_proc;
for(genvar mb=0;mb<2;mb=mb+1)begin : g_mode_active
 EFX_FF head(.D(camera_mode_active[mb]),.CLK(proc_clk),.CE(1'b1),.SR(!proc_reset_n),.Q(mode_active_proc_meta[mb]));
 EFX_FF tail(.D(mode_active_proc_meta[mb]),.CLK(proc_clk),.CE(1'b1),.SR(!proc_reset_n),.Q(mode_active_proc[mb]));
end
EFX_FF mode_switch_head(.D(camera_mode_switching),.CLK(proc_clk),.CE(1'b1),.SR(!proc_reset_n),.Q(mode_switch_proc_meta));
EFX_FF mode_switch_tail(.D(mode_switch_proc_meta),.CLK(proc_clk),.CE(1'b1),.SR(!proc_reset_n),.Q(mode_switch_proc));
EFX_FF mode_fault_head(.D(sensor_ae_fault),.CLK(proc_clk),.CE(1'b1),.SR(!proc_reset_n),.Q(mode_fault_proc_meta));
EFX_FF mode_fault_tail(.D(mode_fault_proc_meta),.CLK(proc_clk),.CE(1'b1),.SR(!proc_reset_n),.Q(mode_fault_proc));
reg capture_meta,capture_pix;
always @(posedge hdmi_tx_slow_clk or negedge w_arstn)begin
 if(!w_arstn)begin capture_meta<=0;capture_pix<=0;end
 else begin capture_meta<=camera_capture_ready;capture_pix<=capture_meta;end
end
// Reset only the input ISP/gearbox/packer, never DDR/HDMI or FIFO pointers.
reg isp_release_meta,isp_release;
wire isp_rst_n=vid_path_rst_n & isp_release;
always @(posedge hdmi_tx_slow_clk or negedge csi_init_rst_n)begin
 if(!csi_init_rst_n)begin isp_release_meta<=0;isp_release<=0;end
 else begin isp_release_meta<=1;isp_release<=isp_release_meta;end
end
// Temporary bring-up LEDs: direct PLL/reset state survives video resets.
localparam DDR_BRINGUP_LEDS=1;
assign led[0] = DDR_BRINGUP_LEDS ? diag_core_count[25] : cap_fifo_overflow;
assign led[1] = DDR_BRINGUP_LEDS ? pll_locked : fb_write_done;
reg csi_overflow_seen;
always @(posedge i_mipi_rx_pclk or negedge w_mipi_rx_pclk_arstn)
 if(!w_mipi_rx_pclk_arstn)csi_overflow_seen<=0;
 else if(csi_fifo_overflow)csi_overflow_seen<=1;
assign led[2]=DDR_BRINGUP_LEDS ? user_pll_locked : csi_overflow_seen;
reg csi_data_seen;
always @(posedge i_mipi_rx_pclk or negedge w_mipi_rx_pclk_arstn)
 if(!w_mipi_rx_pclk_arstn)csi_data_seen<=0;
 else if(w_mipi_rx_de)csi_data_seen<=1;
assign led[3]=DDR_BRINGUP_LEDS ? proc_pll_locked : csi_data_seen;
// LED[5:4]: 00=1080p30,01=720p30,10=480p30,11=480p60.
assign led[4]=DDR_BRINGUP_LEDS ? w_arstn : demo_frames[0];
assign led[5]=DDR_BRINGUP_LEDS ? ddr3_rstn : (demo_fault | demo_boot_fault | fb_axi_error);
wire camera_config_done;
assign camera_config_done=camera_config_ready && camera_rx_enable;
// Keep the soft RX and native lane FIFOs reset until this configuration's
// sensor register sequence has finished. This also flushes a running camera
// stream when the FPGA is reprogrammed through JTAG.
reg camera_done_meta,camera_done_sync;
always @(posedge core_clk or negedge w_arstn)begin
 if(!w_arstn)begin camera_done_meta<=0;camera_done_sync<=0;end
 else begin camera_done_meta<=camera_config_done;camera_done_sync<=camera_done_meta;end
end
assign csi_init_rst_n=w_arstn & camera_done_sync;

// Register the hard PHY FIFO head and EMPTY together on the true byte clock.
// The parser consumes this aligned one-cycle bundle; the vendor controller owns
// the actual hard-FIFO read enables and all physical ENA/TERM controls.
always @(posedge i_cam_ck_CLKOUT or negedge csi_init_rst_n) begin
  if (!csi_init_rst_n) begin
    csi_hs_byte_q <= 32'b0;
    csi_fifo_empty_q <= 4'hf;
    csi_byte_input_valid_q <= 1'b0;
  end else begin
    csi_hs_byte_q <= {cam_d3_HS_IN,cam_d2_HS_IN,cam_d1_HS_IN,cam_d0_HS_IN};
    csi_fifo_empty_q <= {cam_d3_FIFO_EMPTY,cam_d2_FIFO_EMPTY,cam_d1_FIFO_EMPTY,cam_d0_FIFO_EMPTY};
    csi_byte_input_valid_q <= 1'b1;
  end
end

csi_phy_control_vendor inst_csi_phy_control_vendor (
  .reset_n(csi_init_rst_n), .clk(i_mipi_clk),
  .reset_byte_HS_n(csi_init_rst_n), .clk_byte_HS(i_cam_ck_CLKOUT),
  .reset_pixel_n(w_mipi_rx_pclk_arstn & csi_init_rst_n), .clk_pixel(i_mipi_rx_pclk),
  .Rx_LP_CLK_P(i_cam_ck_LP_P_IN), .Rx_LP_CLK_N(i_cam_ck_LP_N_IN),
  .Rx_HS_enable_C(o_cam_ck_HS_ENA), .LVDS_termen_C(o_cam_ck_HS_TERM),
  .Rx_LP_D_P({cam_d3_LP_P_IN,cam_d2_LP_P_IN,cam_d1_LP_P_IN,cam_d0_LP_P_IN}),
  .Rx_LP_D_N({cam_d3_LP_N_IN,cam_d2_LP_N_IN,cam_d1_LP_N_IN,cam_d0_LP_N_IN}),
  .Rx_HS_D_0(cam_d0_HS_IN), .Rx_HS_D_1(cam_d1_HS_IN), .Rx_HS_D_2(cam_d2_HS_IN), .Rx_HS_D_3(cam_d3_HS_IN),
  .Rx_HS_D_4(8'h00), .Rx_HS_D_5(8'h00), .Rx_HS_D_6(8'h00), .Rx_HS_D_7(8'h00),
  .Rx_HS_enable_D({cam_d3_HS_ENA,cam_d2_HS_ENA,cam_d1_HS_ENA,cam_d0_HS_ENA}),
  .LVDS_termen_D({cam_d3_HS_TERM,cam_d2_HS_TERM,cam_d1_HS_TERM,cam_d0_HS_TERM}),
  .fifo_rd_enable({cam_d3_FIFO_RD,cam_d2_FIFO_RD,cam_d1_FIFO_RD,cam_d0_FIFO_RD}),
  .fifo_rd_empty({cam_d3_FIFO_EMPTY,cam_d2_FIFO_EMPTY,cam_d1_FIFO_EMPTY,cam_d0_FIFO_EMPTY}),
  .DLY_enable_D(), .DLY_inc_D(), .u_dly_enable_D(4'h0), .u_dly_inc_D(4'h0),
  .axi_clk(1'b0), .axi_reset_n(1'b0), .axi_awaddr(6'b0), .axi_awvalid(1'b0),
  .axi_awready(), .axi_wdata(32'b0), .axi_wvalid(1'b0), .axi_wready(), .axi_bvalid(), .axi_bready(1'b0),
  .axi_araddr(6'b0), .axi_arvalid(1'b0), .axi_arready(), .axi_rdata(), .axi_rvalid(), .axi_rready(1'b1)
);

assign led[6] = cal_done;
// LED6 retains DDR-ready; LED7 now reports camera I2C/AE write failure.
assign led[7] = gpio0_out[0];

//========================================================================================================
//MIPI RX
//========================================================================================================
wire i_mipi_clk ;
assign i_mipi_clk = core_clk;

		assign cam_d0_RST=~csi_init_rst_n;
		assign cam_d1_RST=~csi_init_rst_n;
		assign cam_d2_RST=~csi_init_rst_n;
    assign cam_d3_RST=~csi_init_rst_n;
	
	
		

		csi_rx_controller inst_csi_rx_self (
  .reset_n(csi_init_rst_n), .clk(i_mipi_clk),
  .reset_byte_HS_n(csi_init_rst_n), .clk_byte_HS(i_cam_ck_CLKOUT),
  .reset_pixel_n(w_mipi_rx_pclk_arstn & csi_init_rst_n), .clk_pixel(i_mipi_rx_pclk),
  .Rx_LP_CLK_P(i_cam_ck_LP_P_IN), .Rx_LP_CLK_N(i_cam_ck_LP_N_IN),
  .Rx_HS_enable_C(), .LVDS_termen_C(),
  .Rx_LP_D_P({cam_d3_LP_P_IN,cam_d2_LP_P_IN,cam_d1_LP_P_IN,cam_d0_LP_P_IN}),
  .Rx_LP_D_N({cam_d3_LP_N_IN,cam_d2_LP_N_IN,cam_d1_LP_N_IN,cam_d0_LP_N_IN}),
  .Rx_HS_D_0(csi_hs_byte_q[7:0]), .Rx_HS_D_1(csi_hs_byte_q[15:8]),
  .Rx_HS_D_2(csi_hs_byte_q[23:16]), .Rx_HS_D_3(csi_hs_byte_q[31:24]),
  .Rx_HS_D_4(8'h00), .Rx_HS_D_5(8'h00), .Rx_HS_D_6(8'h00), .Rx_HS_D_7(8'h00),
  .Rx_HS_enable_D(), .LVDS_termen_D(), .fifo_rd_enable(),
  .fifo_rd_empty(csi_fifo_empty_to_parser),
  .DLY_enable_D(), .DLY_inc_D(), .u_dly_enable_D(4'h0), .u_dly_inc_D(4'h0),
  .axi_clk(1'b0), .axi_reset_n(1'b0), .axi_awaddr(6'b0), .axi_awvalid(1'b0),
  .axi_awready(), .axi_wdata(32'b0), .axi_wvalid(1'b0), .axi_wready(), .axi_bvalid(), .axi_bready(1'b0),
  .axi_araddr(6'b0), .axi_arvalid(1'b0), .axi_arready(), .axi_rdata(), .axi_rvalid(), .axi_rready(1'b1),
  .hsync_vc0(w_mipi_rx_hs), .hsync_vc1(), .hsync_vc2(), .hsync_vc3(),
  .vsync_vc0(w_mipi_rx_vs), .vsync_vc1(), .vsync_vc2(), .vsync_vc3(),
  .vc(), .vcx(), .word_count(), .shortpkt_data_field(), .datatype(), .pixel_per_clk(),
  .pixel_data(w_mipi_rx_data), .pixel_data_valid(w_mipi_rx_de), .irq()
);

//========================================================================================================
//
//========================================================================================================
		

//*************** imx219 config********************/
// mipi_config_imx219_top u_config_imx219(
// 										.i_sys_clk(camera_cfg_clk)    	,    /////48M 
// 										.sys_rstn(vid_rst_n )    ,
// 										.o_sen_rst_n(o_cam_rstn)  	,
										
										// .o_iic_sda_OE(io_cam_sda_OE) ,
										// .i_iic_sda(io_cam_sda_IN)   	,
										// .o_iic_sda(io_cam_sda_OUT)   	,
										// .o_iic_scl(io_cam_scl)    	
										// ); 	

wire sensor_ae_frame_toggle;
wire [1:0] sensor_ae_action;
// CPU bit-bangs open-drain GPIO. Pad data is hardwired low; GPIO output
// enables only pull SCL/SDA low and release them for the external pull-ups.
assign io_cam_scl_OUT = 1'b0;
assign io_cam_sda_OUT = 1'b0;
assign io_cam_scl_OE = gpio0_oe[1];
assign io_cam_sda_OE = gpio0_oe[2];
assign o_cam_rst_p = ~w_arstn;

//=====================================================================================
// ISP: CSI 4xRAW10 -> 1ppc -> color pipeline -> RGB888 in DDR
//=====================================================================================
wire        pix_vs, pix_de;
wire [9:0]  pix_raw;
wire        isp_vs, isp_de;
wire [7:0]  isp_r, isp_g, isp_b;
wire        isp_win_keep;

csi4_to_pix1 u_csi4_to_pix1 (
    .wr_clk    (i_mipi_rx_pclk),
    .wr_rst_n  (w_mipi_rx_pclk_arstn & csi_init_rst_n),
    .in_vs     (w_mipi_rx_vs),
    .in_hs     (w_mipi_rx_hs),
    .in_de     (w_mipi_rx_de & w_mipi_rx_hs),
    .in_data   (w_mipi_rx_data),
    .rd_clk    (hdmi_tx_slow_clk),
    .rd_rst_n  (isp_rst_n),
    .rd_stall  (1'b0),
    .out_vs    (pix_vs),
    .out_hs    (),
    .out_de    (pix_de),
    .out_raw   (pix_raw),
    .overflow  (csi_fifo_overflow)
);

// CSI vsync is a frame-level signal in the working capture bitstream.
reg cam_vs_meta, cam_vs_hdmi;
always @(posedge hdmi_tx_slow_clk or negedge isp_rst_n) begin
  if (!isp_rst_n) begin
    cam_vs_meta <= 1'b0;
    cam_vs_hdmi <= 1'b0;
  end else begin
    cam_vs_meta <= w_mipi_rx_vs;
    cam_vs_hdmi <= cam_vs_meta;
  end
end

wire [10:0] isp_raw_x,isp_raw_y;
wire isp_raw_y0;
sensor_ae_stats u_sensor_ae_stats (
    .clk(hdmi_tx_slow_clk), .rst_n(isp_rst_n),
    .in_vs(cam_vs_hdmi), .in_de(pix_de), .in_raw(pix_raw),
    .in_x(isp_raw_x), .in_y0(isp_raw_y0),
    .frame_toggle(sensor_ae_frame_toggle), .action(sensor_ae_action)
);

// Passive ISP-green 8x8 observer; existing pixel and DDR paths are unchanged.
wire wave_frame_start,wave_block_valid,wave_event_toggle,wave_left_toggle;
wire wave_left_meta,wave_left_cpu;
wire [5:0] wave_block_index,wave_block_mean;
wire wave_enable=isp_rst_n&&capture_pix;
wave_roi_stats u_wave_stats(.clk(hdmi_tx_slow_clk),.rst_n(w_arstn),.enable(wave_enable),
 .in_vs(isp_vs),.in_de(isp_de),.in_green(isp_g),.mode(store_mode_hold),
 .frame_start(wave_frame_start),.block_valid(wave_block_valid),.block_index(wave_block_index),.block_mean(wave_block_mean));
wave_pulse_detector u_wave_detect(.clk(hdmi_tx_slow_clk),.rst_n(w_arstn),.enable(wave_enable),
 .frame_start(wave_frame_start),.block_valid(wave_block_valid),.block_index(wave_block_index),.block_mean(wave_block_mean),
 .event_toggle(wave_event_toggle),.left_toggle(wave_left_toggle),
 .mode_60(active_mode_pix==2'd3),.event_valid(),.event_dir(),.decision_done(),.debug_state(),.debug_changed());
wire camera_bayer_y_xor;
(* async_reg="true" *) reg camera_bayer_y_xor_meta,camera_bayer_y_xor_pix;
always @(posedge hdmi_tx_slow_clk or negedge isp_rst_n)begin
  if(!isp_rst_n)begin camera_bayer_y_xor_meta<=1'b0;camera_bayer_y_xor_pix<=1'b0;end
  else begin camera_bayer_y_xor_meta<=camera_bayer_y_xor;camera_bayer_y_xor_pix<=camera_bayer_y_xor_meta;end
end
isp_top u_isp (
    .clk    (hdmi_tx_slow_clk),
    .rst_n  (isp_rst_n),
    .in_vs  (cam_vs_hdmi),
    .in_de  (pix_de),
    .in_raw (pix_raw),
    .mode(scale_mode), .bayer_y_xor(camera_bayer_y_xor_pix), .mode_hold(store_mode_hold),
    .out_vs (isp_vs),
    .out_de (isp_de),
    .out_r  (isp_r),
    .out_g  (isp_g),
    .out_b  (isp_b),
    .win_keep (isp_win_keep),
    .raw_x(isp_raw_x), .raw_y(isp_raw_y), .raw_y0(isp_raw_y0)
);

// Capture stays low throughout a stopped-stream mode change.
wire store_vs = cam_vs_hdmi & capture_pix;

// Target RGB is produced inside the ISP; no RGB point-decimation stage.
wire sc_vs=isp_vs, sc_de=isp_de;
wire [7:0] sc_r=isp_r,sc_g=isp_g,sc_b=isp_b;


// Four unique RGB565 pixels -> one 64-bit word. Same as pre-IP-swap.
reg  [1:0]  pack_cnt;
reg         pack_de;
reg  [15:0] pack_p0, pack_p1, pack_p2;
reg  [63:0] pack_vin;
reg  [10:0] pack_x, pack_y;
reg [3:0] pack_pad;

function [3:0] bayer4;
  input [1:0] bx, by;
  begin
    case ({by, bx})
      4'b00_00: bayer4 = 4'd0;
      4'b00_01: bayer4 = 4'd8;
      4'b00_10: bayer4 = 4'd2;
      4'b00_11: bayer4 = 4'd10;
      4'b01_00: bayer4 = 4'd12;
      4'b01_01: bayer4 = 4'd4;
      4'b01_10: bayer4 = 4'd14;
      4'b01_11: bayer4 = 4'd6;
      4'b10_00: bayer4 = 4'd3;
      4'b10_01: bayer4 = 4'd11;
      4'b10_10: bayer4 = 4'd1;
      4'b10_11: bayer4 = 4'd9;
      4'b11_00: bayer4 = 4'd15;
      4'b11_01: bayer4 = 4'd7;
      4'b11_10: bayer4 = 4'd13;
      4'b11_11: bayer4 = 4'd5;
      default:  bayer4 = 4'd0;
    endcase
  end
endfunction

wire [3:0] dth = bayer4(pack_x[1:0], pack_y[1:0]);
// Same pack as pre-IP-swap: unique RGB565, four pixels per 64-bit word.
wire [4:0] r5 = sc_r[7:3];
wire [5:0] g6 = sc_g[7:2];
wire [4:0] b5 = sc_b[7:3];
wire [4:0] r5q = ((sc_r[2:0] > dth[3:1]) && (r5 != 5'h1f)) ? (r5 + 5'd1) : r5;
wire [5:0] g6q = ((sc_g[1:0] > dth[3:2]) && (g6 != 6'h3f)) ? (g6 + 6'd1) : g6;
wire [4:0] b5q = ((sc_b[2:0] > dth[3:1]) && (b5 != 5'h1f)) ? (b5 + 5'd1) : b5;
wire [15:0] isp_rgb565 = {r5q, g6q, b5q};
wire [10:0] pack_w_m1 =
    (store_mode_hold == 2'd1) ? 11'd1279 :
    (store_mode_hold == 2'd2) ? 11'd863  : 11'd1919;
wire [10:0] pack_h_m1 =
    (store_mode_hold == 2'd1) ? 11'd719 :
    (store_mode_hold == 2'd2) ? 11'd479 : 11'd1079;
// Hard clip to one standard stored frame. Extra scaler pixels (replay
// glue, CSI jitter) must not become a 721st/481st DDR line.
wire pack_keep = (sc_de || pack_pad!=0) && (pack_y <= pack_h_m1);
wire [15:0] pack_pixel = (pack_pad!=0) ? 16'd0 : isp_rgb565;
always @(posedge hdmi_tx_slow_clk or negedge isp_rst_n) begin
  if (!isp_rst_n) begin
    pack_cnt <= 2'd0;
    pack_de  <= 1'b0;
    pack_p0  <= 16'd0;
    pack_p1  <= 16'd0;
    pack_p2  <= 16'd0;
    pack_vin <= 64'd0;
    pack_x   <= 11'd0;
    pack_y   <= 11'd0;
    pack_pad <= 4'd0;
  end else begin
    pack_de <= 1'b0;
    if (!store_vs) begin
      pack_cnt <= 2'd0;
      pack_x   <= 11'd0;
      pack_y   <= 11'd0;
    pack_pad <= 4'd0;
    end else if (pack_keep) begin
      if(pack_pad!=0) pack_pad<=pack_pad-4'd1;
      else if(store_mode_hold==2'd2 && pack_x==11'd853) pack_pad<=4'd10;
      if (pack_x == pack_w_m1) begin
        pack_x <= 11'd0;
        pack_y <= pack_y + 11'd1;
      end else begin
        pack_x <= pack_x + 11'd1;
      end
      case (pack_cnt)
        2'd0: begin
          pack_p0  <= pack_pixel;
          pack_cnt <= 2'd1;
        end
        2'd1: begin
          pack_p1  <= pack_pixel;
          pack_cnt <= 2'd2;
        end
        2'd2: begin
          pack_p2  <= pack_pixel;
          pack_cnt <= 2'd3;
        end
        default: begin
          pack_vin <= {pack_p0, pack_p1, pack_p2, pack_pixel};
          pack_cnt <= 2'd0;
          pack_de  <= 1'b1;
        end
      endcase
    end
  end
end

wire [15:0] fb_pix;
wire        ch0_vs;
wire        ch0_hs;
wire        ch0_de;

  frame_buffer_axi_white #(
.I_VID_WIDTH         (64),
.O_VID_WIDTH         (16),
.START_ADDR          (32'h00000        ),
.AXI_DATA_WIDTH      ( AXI_DATA_WIDTH	),
.AXI_ADDR_WIDTH      ( AXI_ADDR_WIDTH	),
.WR_FIFO_DEPTH          ( WR_FIFO_DEPTH ),
.RD_FIFO_DEPTH 	      ( RD_FIFO_DEPTH		),
.BURST_LEN  	       (15),
.FB_NUM	            (4),
.DISPLAY_LOCK_ENABLE(1),
.MAX_VID_WIDTH	    (1920) ,
.MAX_VID_HIGHT	    (1080) 

)checker0(
       .npu_lock(camera_lock),.npu_locked_bank(camera_locked_bank),
       .display_lock(demo_active_base!=0),.display_locked_bank(renderer_camera_bank),
       .pending_display_lock(display_source_pending),.pending_display_locked_bank(display_source_pending_bank),
       .capture_sequence(camera_sequence),.capture_base(camera_latest_base),.capture_mode(camera_latest_mode),
       .final_valid(1'b0),.final_base(32'd0),.final_mode(2'd0),
       .active_final_base(),.display_urgent(),
       .capture_urgent(capture_urgent),
       .axi_clk		(proc_clk 	        ),
       .rst_n			(proc_reset_n),
       .ddr_init_done	(proc_ddr_ready),

/*i*/.i_clk			(hdmi_tx_slow_clk    ),
/*i*/.i_vs			(store_vs	),
/*i*/.i_de			(pack_de & capture_pix),
/*i*/.vin 			(pack_vin),
/*i*/.i_store_mode	(scale_mode),
      .i_cam_60(active_mode_pix==2'd3),
                     
/*i*/.o_clk			(hdmi_tx_slow_clk),
/*i*/.o_hs    		(ch0_hs		),			
/*i*/.o_vs    		(ch0_vs		),			
/*i*/.o_de    		(ch0_de		),			
/*i*/.vout    		(fb_pix	),

/*i*/.H_FRONT_PORCH (HFP  		),
/*i*/.H_SYNC 	 	    (HSP	 	),
/*i*/.H_VALID 	 	  (MAX_HRES     ),
/*i*/.H_BACK_PORCH	(HBP		),
/*i*/.V_FRONT_PORCH (VFP  		),
/*i*/.V_SYNC 	 	    (VSP 	 	),
/*i*/.V_VALID 	 	  (MAX_VRES     ),
/*i*/.V_BACK_PORCH	(VBP		),

       .awid			(demo_req[0].awid	),      
       .awaddr		(demo_req[0].awaddr	),
       .awlen			(demo_req[0].awlen	),
       .awsize		(demo_req[0].awsize	),
       .awburst		(demo_req[0].awburst),
       .awprot(),
       .awcache(),
       .awlock(),
       .awvalid		(demo_req[0].awvalid),
       .awready		(demo_rsp[0].awready),

       .arid			(fb_arid_u	  ),
       .araddr		(fb_araddr_u),
       .arlen			(fb_arlen_u	),
       .arsize		(fb_arsize_u	),
       .arburst 	(fb_arburst_u),

       .arprot(),
       .arcache(),
       .arlock(),
       .arvalid		(fb_arvalid_u),
       .arready		(1'b0),

       .wdata			(demo_req[0].wdata	),
       .wstrb			(demo_req[0].wstrb	),
       .wlast			(demo_req[0].wlast	),
       .wvalid		(demo_req[0].wvalid	),
       .wready		(demo_rsp[0].wready	),


       .rid			  (4'd0),
       .rdata			('0),
       .rlast			(1'b0),
       .rvalid 		(1'b0),
       .rready		(fb_rready_u),
       .rresp			('0),

       .bresp(demo_rsp[0].bresp),
       .bid			  (demo_rsp[0].bid	),
       .bvalid		(demo_rsp[0].bvalid	),
       .bready	  (demo_req[0].bready	),
       .cap_fifo_overflow (cap_fifo_overflow),
       .rd_fifo_full_seen (rd_fifo_full_seen),
       .rd_fifo_empty_seen(),
       .axi_error(fb_axi_error),
       .dbg_wstate        (),
       .dbg_rstate        (),
       .dbg_cam_frame_start(),
       .dbg_cam_frame_end (),
       .dbg_cap_used      (),
       .dbg_display_bank  (camera_latest_bank),
       .dbg_rd_bank       (),
       .dbg_write_done    (fb_write_done),
       .dbg_video_started ()
);


ddr3_top                 u_ddr3_top
(

.axi_clk                (proc_clk            ),
.core_clk               (core_clk            ),
.sdram_clk              (sdram_clk           ),  
.rx_cal_clk             (rx_cal_clk          ),
.tx_cal_clk             (tx_cal_clk          ),
.tx_cal_clk_90edge      (tx_cal_clk_90edge   ),
.rstn                   (ddr3_rstn           ),      
.pll_shift              (pll_shift           ),
.pll_shift_sel          (pll_shift_sel       ),
.pll_shift_ena          (pll_shift_ena       ),       
///////////////DDR BUS
.ddr_ck_hi              (ddr_ck_hi           ),
.ddr_ck_lo              (ddr_ck_lo           ),
.ddr_cke                (ddr_cke             ),    
.ddr_reset_n            (ddr_reset_n         ),
.ddr_cs_n               (ddr_cs_n            ),
.ddr_ras_n              (ddr_ras_n           ),
.ddr_cas_n              (ddr_cas_n           ),
.ddr_we_n               (ddr_we_n            ),     
.ddr_addr               (ddr_addr            ),
.ddr_ba                 (ddr_ba              ),

.ddr_dqs_oe             (ddr_dqs_oe          ),
.ddr_dqs_oe_n           (ddr_dqs_oe_n        ),
.ddr_dq_oe              (ddr_dq_oe           ),
.ddr_dqs_in_hi          (ddr_dqs_in_hi       ),
.ddr_dqs_in_lo          (ddr_dqs_in_lo       ),
.ddr_dq_in_hi           (ddr_dq_in_hi        ),
.ddr_dq_in_lo           (ddr_dq_in_lo        ),

.ddr_dqs_out_hi         (ddr_dqs_out_hi      ),
.ddr_dqs_out_lo         (ddr_dqs_out_lo      ),
.ddr_dq_out_hi          (ddr_dq_out_hi       ),
.ddr_dq_out_lo          (ddr_dq_out_lo       ),

.ddr_dm_hi              (ddr_dm_hi           ),
.ddr_dm_lo              (ddr_dm_lo           ),
.ddr_odt                (ddr_odt             ),

// Application interface ports
.app_sr_req                     (1'b0),
.app_ref_req                    (1'b0),
.app_zq_req                     (1'b0),
.app_sr_active                  (app_sr_active),
.app_ref_ack                    (app_ref_ack),
.app_zq_ack                     (app_zq_ack),

// Slave Interface Write Address Ports
.s_axi_awid                     (s_axi_awid        ),
.s_axi_awaddr                   (s_axi_awaddr      ),
.s_axi_awlen                    (s_axi_awlen       ),
.s_axi_awsize                   (s_axi_awsize      ),
.s_axi_awburst                  (s_axi_awburst     ),
.s_axi_awlock                   (s_axi_awlock      ),
.s_axi_awcache                  (s_axi_awcache     ),
.s_axi_awprot                   (s_axi_awprot      ),
.s_axi_awqos                    (4'h0              ),
.s_axi_awvalid                  (s_axi_awvalid     ),
.s_axi_awready                  (s_axi_awready     ),
// Slave Interface Write Data Ports
.s_axi_wdata                    (s_axi_wdata       ),
.s_axi_wstrb                    (s_axi_wstrb       ),
.s_axi_wlast                    (s_axi_wlast       ),
.s_axi_wvalid                   (s_axi_wvalid      ),
.s_axi_wready                   (s_axi_wready      ),
// Slave Interface Write Response Ports
.s_axi_bid                      (s_axi_bid         ),
.s_axi_bresp                    (s_axi_bresp       ),
.s_axi_bvalid                   (s_axi_bvalid      ),
.s_axi_bready                   (s_axi_bready      ),
// Slave Interface Read Address Ports
.s_axi_arid                     (s_axi_arid        ),
.s_axi_araddr                   (s_axi_araddr      ),
.s_axi_arlen                    (s_axi_arlen       ),
.s_axi_arsize                   (s_axi_arsize      ),
.s_axi_arburst                  (s_axi_arburst     ),
.s_axi_arlock                   (s_axi_arlock      ),
.s_axi_arcache                  (s_axi_arcache     ),
.s_axi_arprot                   (s_axi_arprot      ),
.s_axi_arqos                    (4'h0              ),
.s_axi_arvalid                  (s_axi_arvalid     ),
.s_axi_arready                  (s_axi_arready     ),
// Slave Interface Read Data Ports
.s_axi_rid                      (s_axi_rid         ),
.s_axi_rdata                    (s_axi_rdata       ),
.s_axi_rresp                    (s_axi_rresp       ),
.s_axi_rlast                    (s_axi_rlast       ),
.s_axi_rvalid                   (s_axi_rvalid      ),
.s_axi_rready                   (s_axi_rready      ),
//DEBUG       
.wrlvl_dq_check                 (wrlvl_dq_check    ) ,
.rd_level_dqs_check             (rd_level_dqs_check) ,
.init_cur_state                 (init_cur_state    ) ,
.idelay_ld                      (idelay_ld         ) ,
.mpr_rdlvl_dly                  (mpr_rdlvl_dly     ) ,
.cal_done                       (cal_done          )
);
assign cal_pass = cal_done;

//***************************************************************************
// HDMI is 1 pixel/clock at 150 MHz. The frame buffer holds hs/vs/de low
// and pixels at 0 until the first camera frame is in DDR, then it emits
// 1080p60. ISP RGB is already 1ppc; a 2-sample splitter draws green columns.
//***************************************************************************
function [23:0] rgb565_to_888;
  input [15:0] p;
  begin
    rgb565_to_888 = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
  end
endfunction
wire [23:0] cam_rgb888 = rgb565_to_888(fb_pix);
wire [7:0]  hdmi_tx_rdata = cam_rgb888[23:16];
wire [7:0]  hdmi_tx_gdata = cam_rgb888[15:8];
wire [7:0]  hdmi_tx_bdata = cam_rgb888[7:0];
wire       hdmi_tx_vs    = ch0_vs;
wire       hdmi_tx_hs    = ch0_hs;
wire       hdmi_tx_de    = ch0_de;

// DSI controller is gone. Pads stay out of reset and are not driven,
// so the hard PHY is not held in RST. Video reset no longer waits on
// the panel init done flag.
assign  LCD_POWER             = i_arstn;
assign  LCD_RST_P             = ~w_arstn;

reg [26:0] dly_cnt = 'd0;

always @(posedge vid_clk_dvi2 or negedge w_arstn) begin
  if (!w_arstn)
    dly_cnt <= 'd0;
  else if (!dly_cnt[26])
    dly_cnt <= dly_cnt + 1'b1;
end

assign vid_rst_n      = dly_cnt[26];
assign vid_path_rst_n = vid_rst_n & video_soft_rst_n;

// Keep the MIPI byte clock in the netlist. The TX PHY still uses it.
(* syn_keep = 1 *) reg mipi_tx_pclk_keep;
always @(posedge i_mipi_tx_pclk or negedge i_arstn) begin
  if (!i_arstn)
    mipi_tx_pclk_keep <= 1'b0;
  else
    mipi_tx_pclk_keep <= ~mipi_tx_pclk_keep;
end

//=================================================================================
//hdmi tx ctrl 
//=================================================================================
assign tmds_tx_data0_TX_OE = 1'b1;
assign tmds_tx_data1_TX_OE = 1'b1;
assign tmds_tx_data2_TX_OE = 1'b1;
assign tmds_tx_clk_TX_OE   = 1'b1;

assign tmds_tx_data0_TX_RST = 1'b0;
assign tmds_tx_data1_TX_RST = 1'b0;
assign tmds_tx_data2_TX_RST = 1'b0;
assign tmds_tx_clk_TX_RST   = 1'b0;

wire [9:0] tmds_data0;
wire [9:0] tmds_data1;
wire [9:0] tmds_data2;
wire [9:0] tmds_clk_symbol;

// Display subsystem: CPU display CSRs, two DDR-backed RGB565 sources, the
// compositor and all three TMDS encoders. It replaces the old frame-buffer
// scan-out, so checker0 now only captures camera frames into DDR.
wire disp_select=diag_addr[15:8]==8'h04;
wire camera_select=diag_addr[15:8]==8'h05;
wire disp_ready,disp_error,disp_axi_error_a,disp_axi_error_b;
wire [31:0] disp_rdata;
wire [1:0] cfg_scene_mode;
wire [31:0] disp_base_a,disp_base_b;
wire [15:0] disp_stride_a,disp_stride_b;
wire [11:0] disp_src_w,disp_src_h,disp_src_x,disp_src_y;
wire [11:0] disp_dst_x,disp_dst_y,disp_dst_w,disp_dst_h,disp_wipe_x,disp_fps_bcd;
wire [31:0] disp_x_step,disp_y_step;
wire disp_ui_enable,disp_status_ok,disp_config_applied,disp_in_vs;

display_system_top #(.READ_BURST_BEATS(64),.PIPELINE_READS(1'b1)) u_display(
    .cfg_clk(core_clk),.cfg_rst_n(soc_reset_n),
    .cfg_valid(cpu_psel && cpu_penable && disp_select),.cfg_write(cpu_pwrite),
    .cfg_addr(diag_addr[7:0]),.cfg_wdata(cpu_pwdata),.cfg_wstrb(4'hf),
    .cfg_ready(disp_ready),.cfg_error(disp_error),.cfg_rdata(disp_rdata),
    .axi_clk(proc_clk),.axi_rst_n(proc_reset_n),
    .pix_clk(hdmi_tx_slow_clk),.pix_rst_n(vid_rst_n),
    .axi_error_a(disp_axi_error_a),.axi_error_b(disp_axi_error_b),
    .m_axi_arid(demo_req[0].arid),.m_axi_araddr(demo_req[0].araddr),
    .m_axi_arlen(demo_req[0].arlen),.m_axi_arsize(demo_req[0].arsize),
    .m_axi_arburst(demo_req[0].arburst),
    .m_axi_arcache(),.m_axi_arprot(),.m_axi_arlock(),.m_axi_arqos(),
    .m_axi_arvalid(demo_req[0].arvalid),.m_axi_arready(demo_rsp[0].arready),
    .m_axi_rid(demo_rsp[0].rid),.m_axi_rdata(demo_rsp[0].rdata),
    .m_axi_rresp(demo_rsp[0].rresp),.m_axi_rlast(demo_rsp[0].rlast),
    .m_axi_rvalid(demo_rsp[0].rvalid),.m_axi_rready(demo_req[0].rready),
    .tmds_clk_data(tmds_clk_symbol),.tmds_data0(tmds_data0),
    .tmds_data1(tmds_data1),.tmds_data2(tmds_data2),
    .tmds_tx_oe(),.tmds_tx_reset(),
    .debug_rgb565(),.debug_de(),.debug_hs(),.debug_vs(),
    .active_base_a(renderer_camera_base),.active_base_b(demo_active_base),
    .display_read_active());

assign tmds_tx_clk_TX_DATA   = tmds_clk_symbol;
assign tmds_tx_data0_TX_DATA = tmds_data0;
assign tmds_tx_data1_TX_DATA = tmds_data1;
assign tmds_tx_data2_TX_DATA = tmds_data2;

wire camera_csr_ready,camera_csr_error;
wire [31:0] camera_csr_rdata;
ch9350_uart_rx_csr u_ch9350_uart(
 .clk(core_clk),.reset_n(soc_reset_n),.uart_rx(ch9350_rx),.uart_tx(),.paddr(diag_addr),
 .psel(cpu_psel && ch9350_select),.penable(cpu_penable),
 .pwrite(cpu_pwrite),.pwdata(cpu_pwdata),.prdata(ch9350_rdata),
 .pready(ch9350_ready),.pslverror(ch9350_error));

// Shares the tested UART RX CSR implementation; a 1024-byte FIFO absorbs a
// complete command burst while the CPU is inside a bounded control wait.
ch9350_uart_rx_csr #(.ENABLE_TX(1)) u_gesture_uart_rx(
 .clk(core_clk),.reset_n(soc_reset_n),.uart_rx(gesture_uart_rx),.uart_tx(gesture_uart_tx),
 .paddr(diag_addr),
 .psel(cpu_psel && gesture_uart_select),.penable(cpu_penable),
 .pwrite(cpu_pwrite),.pwdata(cpu_pwdata),.prdata(gesture_uart_rdata),
 .pready(gesture_uart_ready),.pslverror(gesture_uart_error));

camera_cpu_csr u_camera_cpu_csr(
 .clk(core_clk),.reset_n(soc_reset_n),.paddr(diag_addr),
 .psel(cpu_psel && !diag_select && !disp_select && camera_select),
 .penable(cpu_penable),.pwrite(cpu_pwrite),.pwdata(cpu_pwdata),
 .prdata(camera_csr_rdata),.pready(camera_csr_ready),.pslverror(camera_csr_error),
 .ae_toggle_async(sensor_ae_frame_toggle),.ae_action_async(sensor_ae_action),.wave_left(wave_left_cpu),
 .vs_async(cam_vs_hdmi),.rx_effective(csi_init_rst_n),.capture_effective(capture_pix),
 .config_ready(camera_config_ready),.rx_enable(camera_rx_enable),
 .capture_enable(camera_capture_ready),.camera_fault(sensor_ae_fault),
 .switching(camera_mode_switching),.mode_active(camera_mode_active),
 .bayer_y_xor(camera_bayer_y_xor));


generate if (DEMO_ACCEL_ENABLE) begin : g_accelerated
wire style_idle,style_n_irq,style_p_irq,model_boot_start;
style_pipeline_top u_style(
    .clk(proc_clk),
    .reset(!proc_reset_n),
    .control_idle(style_idle),
    .csr_valid(demo_csr_req.valid),
    .csr_write(demo_csr_req.write),
    .csr_address(demo_csr_req.address),
    .csr_wdata(demo_csr_req.wdata),
    .csr_wstrb(demo_csr_req.wstrb),
    .csr_ready(demo_csr_rsp.ready),
    .csr_error(demo_csr_rsp.error),
    .csr_rdata(demo_csr_rsp.rdata),
    .csr_target(demo_csr_req.target),
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    .n_irq(style_n_irq),
    .n_m_axi_arid(npu_buffer_req.arid),
    .n_m_axi_araddr(npu_buffer_req.araddr),
    .n_m_axi_arlen(npu_buffer_req.arlen),
    .n_m_axi_arsize(npu_buffer_req.arsize),
    .n_m_axi_arburst(npu_buffer_req.arburst),
    .n_m_axi_arvalid(npu_buffer_req.arvalid),
    .n_m_axi_arready(npu_buffer_rsp.arready),
    .n_m_axi_rid(npu_buffer_rsp.rid),
    .n_m_axi_rdata(npu_buffer_rsp.rdata),
    .n_m_axi_rresp(npu_buffer_rsp.rresp),
    .n_m_axi_rlast(npu_buffer_rsp.rlast),
    .n_m_axi_rvalid(npu_buffer_rsp.rvalid),
    .n_m_axi_rready(npu_buffer_req.rready),
    .n_m_axi_awid(npu_buffer_req.awid),
    .n_m_axi_awaddr(npu_buffer_req.awaddr),
    .n_m_axi_awlen(npu_buffer_req.awlen),
    .n_m_axi_awsize(npu_buffer_req.awsize),
    .n_m_axi_awburst(npu_buffer_req.awburst),
    .n_m_axi_awvalid(npu_buffer_req.awvalid),
    .n_m_axi_awready(npu_buffer_rsp.awready),
    .n_m_axi_wdata(npu_buffer_req.wdata),
    .n_m_axi_wstrb(npu_buffer_req.wstrb),
    .n_m_axi_wlast(npu_buffer_req.wlast),
    .n_m_axi_wvalid(npu_buffer_req.wvalid),
    .n_m_axi_wready(npu_buffer_rsp.wready),
    .n_m_axi_bid(npu_buffer_rsp.bid),
    .n_m_axi_bresp(npu_buffer_rsp.bresp),
    .n_m_axi_bvalid(npu_buffer_rsp.bvalid),
    .n_m_axi_bready(npu_buffer_req.bready),
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    .p_irq(style_p_irq),
    .p_m_axi_arid(demo_req[2].arid),
    .p_m_axi_awid(demo_req[2].awid),
    .p_m_axi_araddr(demo_req[2].araddr),
    .p_m_axi_awaddr(demo_req[2].awaddr),
    .p_m_axi_arlen(demo_req[2].arlen),
    .p_m_axi_awlen(demo_req[2].awlen),
    .p_m_axi_arsize(demo_req[2].arsize),
    .p_m_axi_awsize(demo_req[2].awsize),
    .p_m_axi_arburst(demo_req[2].arburst),
    .p_m_axi_awburst(demo_req[2].awburst),
    .p_m_axi_arvalid(demo_req[2].arvalid),
    .p_m_axi_awvalid(demo_req[2].awvalid),
    .p_m_axi_rready(demo_req[2].rready),
    .p_m_axi_wlast(demo_req[2].wlast),
    .p_m_axi_wvalid(demo_req[2].wvalid),
    .p_m_axi_bready(demo_req[2].bready),
    .p_m_axi_arready(demo_rsp[2].arready),
    .p_m_axi_awready(demo_rsp[2].awready),
    .p_m_axi_rlast(demo_rsp[2].rlast),
    .p_m_axi_rvalid(demo_rsp[2].rvalid),
    .p_m_axi_wready(demo_rsp[2].wready),
    .p_m_axi_bvalid(demo_rsp[2].bvalid),
    .p_m_axi_rid(demo_rsp[2].rid),
    .p_m_axi_bid(demo_rsp[2].bid),
    .p_m_axi_rdata(demo_rsp[2].rdata),
    .p_m_axi_rresp(demo_rsp[2].rresp),
    .p_m_axi_bresp(demo_rsp[2].bresp),
    .p_m_axi_wdata(demo_req[2].wdata),
    .p_m_axi_wstrb(demo_req[2].wstrb));

// Resource-reduction candidate: reconnect the original NPU AXI boundary.
assign demo_req[1]=npu_buffer_req;
assign npu_buffer_rsp=demo_rsp[1];

// Prioritize pending display requests without reserving a complete row.
demo_axi_merge #(.RESERVE_DISPLAY_ROW(1'b0),.PIPELINE_DISPLAY(1'b1),.URGENT_EMPTY_ONLY(1'b0)) u_merge(
 .clk(proc_clk),.reset(!proc_reset_n),.ddr_ready(proc_ddr_ready),
 .display_urgent(demo_req[0].arvalid),.capture_urgent(capture_urgent),
 .req(demo_req),.rsp(demo_rsp),.mem_req(ddr_req),.mem_rsp(ddr_rsp),.idle());
demo_model_boot #(.FLASH_ADDRESS(demo_model_asset_pkg::MODEL_FLASH_BUNDLE_ADDRESS),
 .BUNDLE_BYTES(demo_model_asset_pkg::MODEL_BUNDLE_BYTES),
 .BUNDLE_CRC16(demo_model_asset_pkg::MODEL_BUNDLE_CRC16)) u_model_boot(
 .clk(proc_clk),.reset(!proc_reset_n),.start(model_boot_start),
 .ddr_ready(proc_ddr_ready),.req(demo_req[3]),.rsp(demo_rsp[3]),
 .flash_cs_n(flash_cs_n),.flash_clk(flash_clk),.flash_mosi(flash_mosi),
 .flash_miso(flash_miso),
 .done(demo_boot_done),.fault(demo_boot_fault));
style_cpu_control u_cpu_control(.cpu_clk(core_clk),.cpu_reset_n(soc_reset_n),
 .clk(proc_clk),.reset_n(proc_reset_n),
 .paddr(diag_addr),.psel(cpu_psel && !diag_select && !disp_select && !camera_select && !ch9350_select && !gesture_uart_select),.penable(cpu_penable),
 .pwrite(cpu_pwrite),.pwdata(cpu_pwdata),.prdata(cpu_control_rdata),
 .pready(cpu_control_ready),.pslverror(cpu_control_error),.cpu_irq(cpu_control_irq),
 .ddr_ready(proc_ddr_ready),.boot_done(demo_boot_done),.boot_fault(demo_boot_fault),
 .control_idle(style_idle),.n_irq(style_n_irq),.p_irq(style_p_irq),.axi_fault(fb_axi_error),
 .camera_valid(fb_write_done),.camera_sequence(camera_sequence),
 .camera_bank(camera_latest_bank),.camera_base(camera_latest_base),
 .camera_mode(camera_latest_mode),.camera_mode_active(mode_active_proc),
 .camera_switching(mode_switch_proc),.camera_fault(mode_fault_proc),
 .mode_request(mode_request),.mode_toggle(mode_request_toggle),.display_mode(demo_final_mode),
 .display_active_base(demo_active_base),.camera_lock(camera_lock),
 .camera_locked_bank(camera_locked_bank),.display_source_pending(display_source_pending),
 .display_source_pending_bank(display_source_pending_bank),.display_valid(demo_final_valid),
 .display_base(demo_final_base),.fault(demo_fault),.completed_frames(demo_frames),
 .boot_start(model_boot_start),.req(demo_csr_req),.rsp(demo_csr_rsp));
end else begin : g_camera_preview
 // One camera/display master reaches DDR directly, without the merger.
 assign ddr_req=demo_req[0];
 assign demo_rsp[0]=ddr_rsp;
 for(genvar disabled_master=1;disabled_master<4;disabled_master=disabled_master+1)begin
  assign demo_req[disabled_master]='0;
  assign demo_rsp[disabled_master]='0;
 end
 assign demo_csr_req='0;
 assign demo_csr_rsp='0;
 assign demo_final_valid=fb_write_done;
 assign demo_final_base=camera_latest_base;
 assign demo_final_mode=camera_latest_mode;
 assign display_source_pending=1'b0;
 assign display_source_pending_bank=2'd0;
 assign mode_request=2'd2;assign mode_request_toggle=0;
 // Preserve the camera bank being scanned by HDMI (same 4KiB-aligned stride).
 assign camera_lock=fb_write_done;
 assign camera_locked_bank=(demo_active_base==32'h003f5000) ? 2'd1 :
                           (demo_active_base==32'h007ea000) ? 2'd2 : 2'd0;
 assign demo_boot_done=0;assign demo_boot_fault=0;assign demo_fault=0;
 assign flash_cs_n=1'b1;assign flash_clk=1'b0;assign flash_mosi=1'b0;
 assign demo_frames=camera_sequence;
 assign cpu_control_rdata=0;assign cpu_control_ready=1;assign cpu_control_error=1;
 assign cpu_control_irq=0;
end endgenerate
assign flash_wp_n=1'b1;
assign flash_hold_n=1'b1;
assign s_axi_arid=ddr_req.arid;
assign s_axi_araddr=ddr_req.araddr;
assign s_axi_arlen=ddr_req.arlen;
assign s_axi_arsize=ddr_req.arsize;
assign s_axi_arburst=ddr_req.arburst;
assign s_axi_arvalid=ddr_req.arvalid;
assign s_axi_rready=ddr_req.rready;
assign s_axi_awid=ddr_req.awid;
assign s_axi_awaddr=ddr_req.awaddr;
assign s_axi_awlen=ddr_req.awlen;
assign s_axi_awsize=ddr_req.awsize;
assign s_axi_awburst=ddr_req.awburst;
assign s_axi_awvalid=ddr_req.awvalid;
assign s_axi_wdata=ddr_req.wdata;
assign s_axi_wstrb=ddr_req.wstrb;
assign s_axi_wlast=ddr_req.wlast;
assign s_axi_wvalid=ddr_req.wvalid;
assign s_axi_bready=ddr_req.bready;
assign ddr_rsp.arready=s_axi_arready;
assign ddr_rsp.rid=s_axi_rid;
assign ddr_rsp.rdata=s_axi_rdata;
assign ddr_rsp.rresp=s_axi_rresp;
assign ddr_rsp.rlast=s_axi_rlast;
assign ddr_rsp.rvalid=s_axi_rvalid;
assign ddr_rsp.awready=s_axi_awready;
assign ddr_rsp.wready=s_axi_wready;
assign ddr_rsp.bid=s_axi_bid;
assign ddr_rsp.bresp=s_axi_bresp;
assign ddr_rsp.bvalid=s_axi_bvalid;
assign s_axi_awlock=0;assign s_axi_arlock=0;
assign s_axi_awcache=4'b0011;assign s_axi_arcache=4'b0011;
assign s_axi_awprot=3'b010;assign s_axi_arprot=3'b010;
// Read-only bring-up status on the existing RISC-V APB port (0xf8100000).
// The CPU must remain usable while the DDR watchdog restarts the DDR PLL.
// Hold CPU reset through 1024 actual core-clock edges after configuration.
// Its release stays independent of DDR calibration and retry resets.
reg [9:0] soc_start_count=0;
always @(posedge core_clk or negedge i_arstn)
 if(!i_arstn)soc_start_count<=0;
 else if(!i_pll_locked)soc_start_count<=0;
 else if(!(&soc_start_count))soc_start_count<=soc_start_count+1'b1;
assign soc_reset_n=i_arstn & i_pll_locked & (&soc_start_count);
reg [31:0] diag_rdata;
reg [17:0] diag_proc_count;
always @(posedge proc_clk or negedge i_arstn)
 if(!i_arstn)diag_proc_count<=0;
 else diag_proc_count<=diag_proc_count+1'b1;
(* async_reg="true" *) reg [15:0] diag_flags_meta,diag_flags;
(* async_reg="true" *) reg [23:0] diag_phy_meta,diag_phy;
(* async_reg="true" *) reg [18:0] diag_engine_meta,diag_engine;
reg diag_reset_prev;
reg [31:0] diag_reset_count;
reg [15:0] diag_seen;
always @(posedge core_clk or negedge soc_reset_n)begin
 if(!soc_reset_n)begin
  diag_flags_meta<=0;diag_flags<=0;diag_phy_meta<=0;diag_phy<=0;diag_engine_meta<=0;diag_engine<=0;
  diag_reset_prev<=0;diag_reset_count<=0;diag_seen<=0;
 end else begin
  diag_flags_meta<={diag_proc_count[17],sensor_ae_fault,camera_config_done,
    csi_data_seen,proc_reset_n,vid_path_rst_n,cal_retry_done,cal_rst_active,
    cal_done,ddr3_rstn,w_arstn,proc_pll_locked,user_pll_locked,pll_locked,i_pll_locked,i_arstn};
  diag_flags<=diag_flags_meta;
  diag_phy_meta<={idelay_ld,init_cur_state,rd_level_dqs_check,wrlvl_dq_check};
  diag_phy<=diag_phy_meta;
  diag_engine_meta<={demo_frames,demo_boot_done,demo_boot_fault,demo_fault};
  diag_engine<=diag_engine_meta;
  diag_seen<=diag_seen | diag_flags;
  diag_reset_prev<=w_arstn;
  if(diag_reset_prev && !w_arstn && !(&diag_reset_count))diag_reset_count<=diag_reset_count+1'b1;
 end
end
always @* begin
 case(diag_addr[4:2])
  0:diag_rdata=32'h44445231;
  1:diag_rdata={16'd0,diag_flags};
  2:diag_rdata={8'd0,diag_phy};
  3:diag_rdata={3'd0,cal_retry_done,cal_retry_cnt,cal_wait_cnt};
  4:diag_rdata=diag_reset_count;
  5:diag_rdata={16'd0,diag_seen};
  6:diag_rdata={16'd0,diag_engine[18:3]};
  7:diag_rdata={29'd0,diag_engine[2:0]};
 endcase
end
// Hardware diagnostics use the video PLL; DDR and CPU may be stalled.
always @(posedge core_clk or negedge i_arstn)
 if(!i_arstn)diag_core_count<=0;else diag_core_count<=diag_core_count+1'b1;
wire soc_uart_txd,ddr_uart_txd;
wire [63:0] ddr_uart_status={
 {gpio0_out[0],sensor_ae_fault,camera_config_done,proc_reset_n,
  vid_path_rst_n,diag_proc_count[17],diag_core_count[25],cal_rst_active,
  cal_done,ddr3_rstn,w_arstn,proc_pll_locked,user_pll_locked,pll_locked,i_pll_locked,i_arstn},
 idelay_ld,init_cur_state,rd_level_dqs_check,wrlvl_dq_check,
 1'b0,cal_retry_cnt,cal_wait_cnt[24:5]};
demo_diag_uart u_ddr_uart(.clk(hdmi_tx_slow_clk),
 .rst_n(i_arstn & user_pll_locked),.status_async(ddr_uart_status),.tx(ddr_uart_txd));
// UART command replies belong to the CPU. KEY3 reaches GPIO input bit 0.
assign system_uart_0_io_txd=DEMO_ACCEL_ENABLE ? soc_uart_txd : ddr_uart_txd;
wire key3_cpu_meta,key3_cpu;
EFX_FF key3_head(.D(key3_n),.CLK(core_clk),.CE(1'b1),.SR(!soc_reset_n),.Q(key3_cpu_meta));
EFX_FF key3_tail(.D(key3_cpu_meta),.CLK(core_clk),.CE(1'b1),.SR(!soc_reset_n),.Q(key3_cpu));
wire wave_event_meta,wave_event_cpu;
EFX_FF wave_event_head(.D(wave_event_toggle),.CLK(core_clk),.CE(1'b1),.SR(!soc_reset_n),.Q(wave_event_meta));
EFX_FF wave_event_tail(.D(wave_event_meta),.CLK(core_clk),.CE(1'b1),.SR(!soc_reset_n),.Q(wave_event_cpu));
EFX_FF wave_left_head(.D(wave_left_toggle),.CLK(core_clk),.CE(1'b1),.SR(!soc_reset_n),.Q(wave_left_meta));
EFX_FF wave_left_tail(.D(wave_left_meta),.CLK(core_clk),.CE(1'b1),.SR(!soc_reset_n),.Q(wave_left_cpu));
wire jtag_tdo_w;
soc u_sapphire_soc (
    .io_systemClk                 (core_clk),
    .io_asyncReset                (~soc_reset_n),
    .io_systemReset               (),
    // --- JTAG 调试口 ---
    .jtagCtrl_tck                 (jtag_inst1_TCK),
    .jtagCtrl_tdi                 (jtag_inst1_TDI),
    .jtagCtrl_tdo                 (jtag_tdo_w),
    .jtagCtrl_enable              (jtag_inst1_SEL),
    .jtagCtrl_capture             (jtag_inst1_CAPTURE),
    .jtagCtrl_shift               (jtag_inst1_SHIFT),
    .jtagCtrl_update              (jtag_inst1_UPDATE),
    .jtagCtrl_reset               (jtag_inst1_RESET),
    // --- 调试串口 ---
    .system_uart_0_io_txd         (soc_uart_txd),
    .system_uart_0_io_rxd         (system_uart_0_io_rxd),
    // --- GPIO ---
    .system_gpio_0_io_write       (gpio0_out),
    .system_gpio_0_io_writeEnable (gpio0_oe),
    .system_gpio_0_io_read        ({wave_event_cpu,io_cam_sda_IN,io_cam_scl_IN,!key3_cpu}),
    // --- APB 控制面 ---
    .io_apbSlave_0_PADDR          (diag_addr),
    .io_apbSlave_0_PSEL           (cpu_psel),
    .io_apbSlave_0_PENABLE        (cpu_penable),
    .io_apbSlave_0_PWRITE         (cpu_pwrite),
    .io_apbSlave_0_PWDATA         (cpu_pwdata),
    .io_apbSlave_0_PRDATA         (diag_select ? diag_rdata : disp_select ? disp_rdata : camera_select ? camera_csr_rdata : ch9350_select ? ch9350_rdata : gesture_uart_select ? gesture_uart_rdata : cpu_control_rdata),
    .io_apbSlave_0_PREADY         (diag_select ? 1'b1 : disp_select ? disp_ready : camera_select ? camera_csr_ready : ch9350_select ? ch9350_ready : gesture_uart_select ? gesture_uart_ready : cpu_control_ready),
    .io_apbSlave_0_PSLVERROR      (diag_select ? cpu_pwrite : disp_select ? disp_error : camera_select ? camera_csr_error : ch9350_select ? ch9350_error : gesture_uart_select ? gesture_uart_error : cpu_control_error),
    // --- 整帧完成/模型/错误通知，SoC 内已有跨域同步和 PLIC ---
    .userInterruptA               (cpu_control_irq),
    .axiAInterrupt                (1'b0),
    // --- SoC 的 AXI 主口：本步不用 ---
    .axiA_awready(1'b0), .axiA_wready(1'b0), .axiA_arready(1'b0),
    .axiA_bvalid(1'b0),  .axiA_bid(8'd0),    .axiA_bresp(2'd0),
    .axiA_rvalid(1'b0),  .axiA_rdata(32'd0), .axiA_rid(8'd0),
    .axiA_rresp(2'd0),   .axiA_rlast(1'b0),
    .axiA_awaddr(),   .axiA_awlen(),   .axiA_awsize(),  .axiA_awburst(),
    .axiA_awlock(),   .axiA_awcache(), .axiA_awprot(),  .axiA_awqos(),
    .axiA_awregion(), .axiA_awid(),    .axiA_awvalid(),
    .axiA_araddr(),   .axiA_arlen(),   .axiA_arsize(),  .axiA_arburst(),
    .axiA_arlock(),   .axiA_arcache(), .axiA_arprot(),  .axiA_arqos(),
    .axiA_arregion(), .axiA_arid(),    .axiA_arvalid(),
    .axiA_wdata(),    .axiA_wstrb(),   .axiA_wlast(),   .axiA_wvalid(),
    .axiA_bready(),   .axiA_rready()
);


assign jtag_inst1_TDO=jtag_tdo_w;

endmodule
