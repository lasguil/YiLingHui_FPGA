//=================================================================
//
//  Copyright (C) 2022 Persion All rights reserved.
//  文件名称：top.v
//  创 建 者：Ramsey Wang
//  创建日期：2022.04.01
//  描    述：led test
//
//=================================================================


`include "video_profile.vh"
module udp_test_top #(
    parameter JPEG_MODE = 0
)
(

    ////////////////////////    CLOCK & PLL     ////////////////////////
       input                rst_n,
       input  [47:0]        source_mac_addr ,       //source mac address
       input  [7:0]         TTL,
       input  [31:0]        source_ip_addr,
       input  [31:0]        destination_ip_addr,
       input  [15:0]        udp_send_source_port,
       input  [15:0]        udp_send_destination_port,
  //ETH
   input			rxc,   
   input  [3:0]             rxd_hi_i    ,
   input  [3:0]             rxd_lo_i    ,
   input 			rx_dv_HI    ,
   input 			rx_dv_LO    ,
   output 			tx_en_o_HI  ,
   output 		       tx_en_o_LO  ,
   output                   txc_hi_o,
   output                   txc_lo_o,
   output 	  [3:0]       txd_hi_o,
   output 	  [3:0]       txd_lo_o,

  output 			  mdc_o,
   output                     mdio_o,
   output                     mdio_oe,     
   input                      mdio_i,     
   output 			  phy_rst_n,
   output                 dbg_tx_act,     // 【诊断】mac_top 的 GMII 发送使能
   output                 dbg_buf_act,     // 【诊断】客户端请求活动
   output                 dbg_en100,       // 【诊断】10/100M 通路使能
   output                 dbg_txen100,     // 【诊断】齿轮箱输出 tx_en
   output                 dbg_grant,       // 【诊断】仲裁器授权
   output                 dbg_arp_ok,      // 【诊断】ARP 是否已解析
   output                 dbg_arp_req,     // 【诊断】udp_regs 拉 ARP 请求的脉冲
   output                 dbg_mac_busy,    // 【诊断】仲裁器认为 MAC 忙
   output                 dbg_vid_busy,    // 【诊断】mac_top 的 mac_send_end 脉冲

   input wire hd_frame_valid, cap_available,
   input wire [5:0] board_status,
   input wire [31:0] hd_frame_cnt,
   input wire [11:0] hd_src_w, hd_src_h,
   output wire hd_cap_using,
   output wire a_cmd_valid,
   input wire a_cmd_ready,
   output wire a_cmd_clk,
   output wire [31:0] a_cmd_token,
   output wire [7:0] a_cmd_type,
   output wire [7:0] a_cmd_length,
   output wire [431:0] a_cmd_payload,
   input wire a_status_valid,
   input wire [63:0] a_status_data,
   input wire [15:0] cap_data,
   input wire cap_data_valid, cap_last, cap_error, cap_busy,
   output wire cap_pop, cap_rd_begin, cap_rd_end,
   output wire stream_reset_n

);

  

reg    [ 7:0]   gmii_txd     ;      // 由下面 mac_top 的输出打一拍驱动
reg             gmii_tx_en   ;
wire            gmii_tx_er   ;
wire            gmii_tx_clk  ;
wire            gmii_crs     ;
wire            gmii_col     ;
wire   [ 7:0]   gmii_rxd     ;
wire            gmii_rx_dv   ;
wire            gmii_rx_er   ;
wire            gmii_rx_clk  ;

wire  [31:0]    pack_total_len ;
wire            duplex_mode;     // 1 full, 0 half

assign duplex_mode = 1'b1;

wire [1:0]      speed      ;
wire            link       ;
wire            e_rx_dv    ;
wire [7:0]      e_rxd      ;
wire            e_tx_en    ;
wire [7:0]      e_txd      ;
wire            e_rst_n    ;



// Do not hold PHY reset from its own recovered-clock reset chain.
assign phy_rst_n = 1'b1;
assign mdc_o=1'b0; assign mdio_o=1'b1; assign mdio_oe=1'b0;
assign gmii_tx_clk_o = gmii_tx_clk;
assign txc_hi_o = 1'b1;
assign txc_lo_o = 1'b0;



/*
smi_config  smi_config_inst
       (
        .clk         (clk_50m  ),
        .rst_n       (rst_n    ),		 
        .mdc         (e_mdc    ),
        .mdio        (e_mdio   ),
        .speed       (speed    ),
        .link        (link     ),
        .led         (led      )	
       );
*/


	
//=====================================================================
// 我们自己的控制面：mac_top + udp_regs（替换厂家的 mac_test）
//   ─ mac_top 的 mac_data_valid/mac_tx_data 要打一拍再给 gmii_arbi
//   ─ gmii_arbi 回来的 e_rx_dv/e_rxd 也要打一拍再给 mac_top
//     （这两拍是厂家 mac_test 里的胶合逻辑，照抄，别省）
//   ─ ARP 由 udp_regs 自己拉 arp_request_req（mac_top 不会自动发）
//=====================================================================
// ---- 仲裁器到 mac_top ----
wire [7:0]  a_tx_data ;   wire        a_tx_wr   ;   wire [15:0] a_tx_len ;
wire        a_tx_req  ;   wire [15:0] a_dest_port, a_source_port ;  wire        a_ram_req ;
wire        c0_ram_req, c1_ram_req ;
// ---- 视频分包器 ----
wire [7:0]  v_tx_data ;   wire        v_tx_wr   ;   wire [15:0] v_tx_len ;
wire        v_tx_req  ;   wire [15:0] v_tx_port ;   wire v_tx_busy ;
wire [31:0] v_frame_cnt, v_pkt_cnt, v_drop_cnt ;
wire [15:0] v_w, v_h ;

wire [7:0]  u_tx_data ;   wire        u_tx_wr   ;   wire [15:0] u_tx_len ;   wire u_tx_busy ;
wire        u_tx_req  ;   wire        u_arp_req ;   wire [15:0] u_dest_port ;
wire        u_tx_ram_req ;  wire     u_mac_send_end ;
// ★★ 必须在所有实例化之前声明：下面三处实例化都把它当输入端口用。
//    以前这个 net 是"先用后声明"，Efinity 生成的是**未驱动的隐式网络**（恒 0），
//    导致仲裁器永远等超时（37Mbps 天花板）+ 控制面发完第一包就死锁。
wire        mac_send_end_g ;
wire udp_payload_end, tx_accept_ready, tx_overflow;
wire [23:0] tx_timeout_count;
reg udp_payload_seen;
always @(posedge gmii_tx_clk or negedge e_rst_n)
    if (!e_rst_n) udp_payload_seen<=0;
    else if (mac_send_end_g) udp_payload_seen<=0;
    else if (udp_payload_end) udp_payload_seen<=1;
wire        tx_play_busy, rx_replay_busy ;
wire        u_arp_found ;   wire     u_mac_not_exist ;
wire [31:0] u_cfg_dest_ip;
wire [7:0]  u_rx_data ;   wire [10:0] u_rx_addr ;   wire [15:0] u_rx_len ;
wire        u_rx_valid ;
wire        gmii_tx_en_tmp ;   wire [7:0] gmii_txd_tmp ;
reg         gmii_rx_dv_d0  ;   reg  [7:0] gmii_rxd_d0  ;

wire [15:0] u_cfg_w, u_cfg_h, u_cfg_pkt ;
wire [15:0] u_cfg_video_gap;
wire [7:0]  u_cfg_fps ;
wire        u_cfg_en ;
wire [1:0]  u_cfg_src ;
wire [31:0] u_a_eff, u_a_str, u_a_sty, u_a_frz ;
wire u_a_cmd_valid;
wire [31:0] u_a_cmd_token;
wire [7:0] u_a_cmd_type,u_a_cmd_length;
wire [431:0] u_a_cmd_payload;
wire [31:0] u_dbg_rx, u_dbg_tx ;
// ---- 抓帧��路 ----
wire [15:0] cap_addr;

wire cap_frame_valid = hd_frame_valid;
wire [31:0] cap_frame_cnt = hd_frame_cnt;
wire [15:0] cap_frame_sum ;
wire [11:0] cap_src_w=hd_src_w, cap_src_h=hd_src_h;
wire cap_on = cap_busy;


// RX 打一拍
always @(posedge gmii_rx_clk or negedge rst_n)
  if (!rst_n) begin gmii_rx_dv_d0 <= 1'b0 ; gmii_rxd_d0 <= 8'd0 ; end
  else        begin gmii_rx_dv_d0 <= e_rx_dv ; gmii_rxd_d0 <= e_rxd ; end

// TX 打一拍
always @(posedge gmii_tx_clk or negedge rst_n)
  if (!rst_n) begin gmii_tx_en <= 1'b0 ; gmii_txd <= 8'd0 ; end
  else        begin gmii_tx_en <= gmii_tx_en_tmp ; gmii_txd <= gmii_txd_tmp ; end

// 【诊断】mac_top 到底有没有在发帧
assign dbg_tx_act = gmii_tx_en;
// 【诊断】改成看发送缓冲有没有在播帧（tx_play_busy 来自 gmii_arbi → TX buffer）
// 【诊断】改成看两个客户端（udp_regs / vid_packet）有没有在向仲裁器请求发帧
assign dbg_buf_act  = u_tx_req | v_tx_req;
wire   u_arp_ok;
assign dbg_arp_ok   = u_arp_ok;      // 来自 udp_regs = ~mac_not_exist
assign dbg_arp_req  = u_arp_req;     // udp_regs → mac_top 的 ARP 请求脉冲
assign dbg_vid_busy = u_mac_send_end;   // 【诊断】改成看 mac_top 的 mac_send_end 脉冲

mac_top mac_top0
(
  .tx_accept_ready(tx_accept_ready),
  .udp_tx_pending(dbg_grant),
  /*I*/.gmii_tx_clk                 (gmii_tx_clk)             ,
  /*I*/.gmii_rx_clk                 (gmii_rx_clk)             ,
  /*I*/.rst_n                       (e_rst_n)                 ,

  /*I*/.source_mac_addr             (source_mac_addr)         ,
  /*I*/.TTL                         (TTL)                     ,
  /*I*/.source_ip_addr              (source_ip_addr)          ,
  /*I*/.destination_ip_addr         (u_cfg_dest_ip)          ,
  /*I*/.udp_send_source_port        (a_source_port)           ,
  /*I*/.udp_send_destination_port   (a_dest_port)             ,  // ← 仲裁器按包类型切（控制 5000 / 视频 5001）

  /*I*/.ram_wr_data                 (a_tx_data)               ,
  /*I*/.ram_wr_en                   (a_tx_wr)                 ,
  /*O*/.udp_ram_data_req            (a_ram_req)               ,
  /*I*/.udp_send_data_length        (a_tx_len)                ,

  /*I*/.udp_tx_req                  (a_tx_req)                ,
  /*I*/.arp_request_req             (u_arp_req)               ,

  /*O*/.mac_data_valid              (gmii_tx_en_tmp)          ,
  /*O*/.mac_send_end                (u_mac_send_end)          ,
  .udp_payload_end(udp_payload_end),
  /*O*/.mac_tx_data                 (gmii_txd_tmp)            ,

  /*I*/.rx_dv                       (gmii_rx_dv_d0)           ,
  /*I*/.mac_rx_datain               (gmii_rxd_d0)             ,

  /*O*/.udp_rec_ram_rdata           (u_rx_data)               ,
  /*I*/.udp_rec_ram_read_addr       (u_rx_addr)               ,
  /*O*/.udp_rec_data_length         (u_rx_len)                ,
  /*O*/.udp_rec_data_valid          (u_rx_valid)              ,

  /*O*/.arp_found                   (u_arp_found)             ,
  /*O*/.mac_not_exist               (u_mac_not_exist)
);

udp_regs #(.DEF_W(`NET_VIDEO_W), .DEF_H(`NET_VIDEO_H), .DEF_FPS(`NET_VIDEO_FPS), .FIXED_VIDEO(1), .PERSIST_DEST(1)) u_udp_regs
(
  .clk                 (gmii_tx_clk)      ,
  .rst_n               (e_rst_n)          ,
  .cfg_reset_n         (rst_n)            ,

  .tx_data             (u_tx_data)        ,
  .tx_wr               (u_tx_wr)          ,
  .tx_len              (u_tx_len)         ,
  .tx_req              (u_tx_req)         ,
  .arp_req             (u_arp_req)        ,
  .dest_port           (u_dest_port)      ,
  .tx_ram_req          (c0_ram_req)       ,
  // ★★ 2026-10-18 修复：这个输出原来**根本没接**，u_tx_busy 是未驱动网络(恒0)，
  //    仲裁器的 c0_busy 永远为 0 -> 控制面一旦进入 S_TX_WR(req 落下)授权就被
  //    切给视频通路，dest_port 变成 5001，控制包永远到不了 PC 的 5000 端口。
  //    这也是"网页控制按钮从来是死的"的另一半原因。
  .tx_busy             (u_tx_busy)         ,
  .arp_send_end        (u_mac_send_end),
  .mac_send_end        (mac_send_end_g)   ,
  .arp_found           (u_arp_found)      ,
  .mac_not_exist       (u_mac_not_exist)  ,

  .rx_data             (u_rx_data)        ,
  .rx_addr             (u_rx_addr)        ,
  .rx_len              (u_rx_len)         ,
  .rx_valid            (u_rx_valid)       ,

  // 板级状态：暂时是占位值（还没做 MDIO，链路按千兆直连处理）
  .ddr_ready(board_status[5]),.board_status(board_status),
  .default_dest_ip_addr(destination_ip_addr),
  .link_speed          (2'b01)            ,
  .link_up             (1'b1)             ,
  .src5v               (board_status[3])             ,   // 本工程没接 HDMI 的 +5V
  .pll_lock            (board_status[4])             ,
  .rxc_alive           (1'b1)             ,

  .cfg_w               (u_cfg_w)          ,
  .cfg_h               (u_cfg_h)          ,
  .cfg_fps             (u_cfg_fps)        ,
  .cfg_stream_en       (u_cfg_en)         ,
  .cfg_pkt_size        (u_cfg_pkt)        ,
  .cfg_video_packet_gap(u_cfg_video_gap)  ,
  .cfg_test_src        (u_cfg_src)        ,
  .cfg_dest_ip         (u_cfg_dest_ip)     ,
  .cfg_a_effect        (u_a_eff)          ,
  .cfg_a_strength      (u_a_str)          ,
  .cfg_a_style         (u_a_sty)          ,
  .cfg_a_freeze        (u_a_frz)          ,
  .a_cmd_valid         (u_a_cmd_valid)    ,
  .a_cmd_ready         (a_cmd_ready)      ,
  .a_cmd_token         (u_a_cmd_token)    ,
  .a_cmd_type          (u_a_cmd_type)     ,
  .a_cmd_length        (u_a_cmd_length)   ,
  .a_cmd_payload       (u_a_cmd_payload)  ,
  .a_status_valid      (a_status_valid)  ,
  .a_status_data       (a_status_data)   ,
  .stat_frame_cnt      (v_frame_cnt)      ,   // 视频模块回填，网页上能看帧计数
  .stat_pkt_cnt        (v_pkt_cnt)        ,
  .stat_tx_err         (v_drop_cnt+{31'd0,tx_overflow}+{8'd0,tx_timeout_count})       ,
  .dbg_rx_pkts         (u_dbg_rx)         ,
  .dbg_tx_pkts         (u_dbg_tx)         ,
  .dbg_arp_ok          (u_arp_ok)         ,

  // ---- HDMI 抓帧状态（网页可读）----
  .hd_frame_valid      (cap_frame_valid)  ,
  .hd_cap_using        (hd_cap_using)     ,
  .hd_cap_on           (cap_on)           ,
  .hd_src_w            (cap_src_w)        ,
  .hd_src_h            (cap_src_h)        ,
  .hd_frame_cnt        (cap_frame_cnt)
);
assign a_cmd_valid=u_a_cmd_valid;
assign a_cmd_clk=gmii_tx_clk;
assign a_cmd_token=u_a_cmd_token;
assign a_cmd_type=u_a_cmd_type;
assign a_cmd_length=u_a_cmd_length;
assign a_cmd_payload=u_a_cmd_payload;

//=====================================================================
// TX 仲裁：控制面(c0, 高优先) / 视频分包(c1) -> mac_top
//=====================================================================
udp_tx_arb u_tx_arb
(
  .clk         (gmii_tx_clk) ,
  .rst_n       (e_rst_n)     ,
  .c0_data     (u_tx_data)   ,  .c0_wr (u_tx_wr),  .c0_len (u_tx_len),
  .c0_req      (u_tx_req)    ,  .c0_busy (u_tx_busy),  .c0_port (u_dest_port),
  .c0_source_port(16'd5000), .c0_ram_req (c0_ram_req),
  .c1_data     (v_tx_data)   ,  .c1_wr (v_tx_wr),  .c1_len (v_tx_len),
  .c1_req      (v_tx_req)    ,  .c1_busy (v_tx_busy),  .c1_port (v_tx_port),
  .c1_source_port(udp_send_source_port), .c1_ram_req (c1_ram_req),
  .tx_data     (a_tx_data)   ,  .tx_wr (a_tx_wr),  .tx_len (a_tx_len),
  .tx_req      (a_tx_req)    ,  .dest_port (a_dest_port), .source_port(a_source_port), .tx_ram_req (a_ram_req),
  .mac_send_end (mac_send_end_g),
  // Only UDP admission waits for ARP. Keep MAC/replay ready unchanged so
  // ARP itself can still transmit and resolve the peer.
  // Leave one idle MAC edge for the registered destination address to settle
  // when ARP learning occurs during an unrelated outgoing Ethernet frame.
  .tx_accept_ready(tx_accept_ready&&!u_mac_not_exist&&!gmii_tx_en_tmp), .timeout_count(tx_timeout_count),
  .dbg_grant   (dbg_grant),
  .dbg_mac_busy(dbg_mac_busy),
  .dbg_tx_req  (dbg_tx_req)
);

//=====================================================================
// 视频分包器（M2a：内置测试图案；M2b 换成 HDMI RX 的像素流）
//=====================================================================
vid_packet #(
  .WAIT_FRESH(1),
  .JPEG_MODE(JPEG_MODE),
  .CHECK_PEER(1),
  .PACKET_PACING(1),
  .W       (JPEG_MODE ? 16'd1280 : `NET_VIDEO_W),
  .H       (JPEG_MODE ? 16'd720 : `NET_VIDEO_H),
  .FPS     (JPEG_MODE ? 8'd30 : `NET_VIDEO_FPS),
  .PKT_MAX (16'd1452),
  .PORT    (16'd5001)
) u_vid_packet
(
  .clk            (gmii_tx_clk) ,
  .rst_n          (e_rst_n)     ,
  .tx_data        (v_tx_data)   ,
  .tx_wr          (v_tx_wr)     ,
  .tx_len         (v_tx_len)    ,
  .tx_req         (v_tx_req)    ,
  .tx_port        (v_tx_port)   ,
  .tx_busy        (v_tx_busy)   ,
  .tx_ram_req     (c1_ram_req)  ,
  .mac_send_end   (mac_send_end_g) ,
  .cfg_stream_en  (u_cfg_en),
  .peer_ready     (!u_mac_not_exist),
  .cfg_packet_gap (u_cfg_video_gap),
  .cfg_test_src   (u_cfg_src)   ,
  .frame_cnt      (v_frame_cnt) ,
  .pkt_cnt        (v_pkt_cnt)   ,
  .drop_cnt       (v_drop_cnt)  ,
  .cur_w          (v_w)         ,
  .cur_h          (v_h)         ,
  // ---- 真·像素源：hdmi_capture 的帧缓存 ----
  .cap_addr       (cap_addr)    ,
  .cap_data       (cap_data)    ,
  .cap_valid      (cap_available), .cap_present(hd_frame_valid),
  .cap_rd_begin   (cap_rd_begin),
  .cap_rd_end     (cap_rd_end)  ,
  .cap_data_valid(cap_data_valid), .cap_last(cap_last), .cap_pop(cap_pop),
  .cap_error(cap_error), .cap_busy(cap_busy),
  .cap_using      (hd_cap_using)
);

//=====================================================================
// The locked DDR reader is instantiated by gesture_board_top.
assign stream_reset_n=e_rst_n;

//=====================================================================
// UDP transaction completion and independent replay capacity.
// UDP completion is after its payload and the internal MAC FCS, not PHY replay.
// Replay capacity, rather than a guessed timeout, gates the next transaction.
assign mac_send_end_g = u_mac_send_end && udp_payload_seen;

gmii_arbi arbi_inst
(
 /*I*/.clk                (gmii_tx_clk      ),
 /*I*/.rst_n              (rst_n            ),
 /*I*/.speed              (2'b01),// 【100M 专用构建】2'b01=100M
 /*I*/.link               (1'b1),//(link             ), 
 /*O*/.pack_total_len     (pack_total_len   ), 
 /*O*/.e_rst_n            (e_rst_n          ),

 /*I*/.gmii_rx_dv         (gmii_rx_dv       ),
 /*I*/.gmii_rxd           (gmii_rxd         ),

 /*I*/.gmii_tx_en         (gmii_tx_en       ),
 /*I*/.gmii_txd           (gmii_txd         ), 

 /*O*/.e_rx_dv            (e_rx_dv          ),
 /*O*/.e_rxd              (e_rxd            ),
 /*O*/.e_tx_en            (e_tx_en          ),
 /*O*/.e_txd              (e_txd            ),

 /*O*/.tx_play_busy       (tx_play_busy     ),
  .tx_accept_ready(tx_accept_ready), .tx_overflow(tx_overflow),
 /*O*/.rx_replay_busy     (rx_replay_busy   ),
 /*O*/.dbg_en100          (dbg_en100        ),
 /*O*/.dbg_txen100        (dbg_txen100      )
);

reg [3:0] align_rxd_hi;
wire [3:0] align_rxd_lo;
reg       align_rx_dv_hi;
wire      align_rx_dv_lo;
always @(posedge rxc)begin
       
       
       align_rxd_hi     <= rxd_hi_i;
       align_rx_dv_hi <= rx_dv_HI;
end
assign align_rxd_lo = rxd_lo_i;
assign align_rx_dv_lo = rx_dv_LO;
util_gmii_to_rgmii util_gmii_to_rgmii_m0
(
 /*I*/.rst_n                  (rst_n           ),     
 //interface RXD
 /*i*/.rgmii_rxc              (rxc         ),
 /*i*/.rgmii_rx_hi            (align_rxd_lo),//(rxd_hi_i        ),
 /*i*/.rgmii_rx_lo            (align_rxd_hi),//(rxd_lo_i        ),
 /*i*/.rgmii_rx_dv            (align_rx_dv_lo),//(rx_dv_HI        ),
 /*i*/.rgmii_rx_er            (align_rx_dv_hi),//(rx_dv_LO        ),
 
 //interface TXD
 /*o*/.rgmii_tx_ctrl_hi       (  tx_en_o_HI    ),
 /*o*/.rgmii_tx_ctrl_lo       (  tx_en_o_LO    ),
 /*o*/.rgmii_txd_lo           (  txd_lo_o      ),
 /*o*/.rgmii_txd_hi           (  txd_hi_o      ),

 //tx
 /*I*/.gmii_txd               (e_txd           ),
 /*I*/.gmii_tx_en             (e_tx_en         ),
 /*I*/.gmii_tx_er             (1'b0            ),
 /*o*/.gmii_tx_clk            (gmii_tx_clk     ),
//rx
 /*o*/.gmii_crs               (gmii_crs        ),
 /*o*/.gmii_col               (gmii_col        ),
 /*o*/.gmii_rxd               (gmii_rxd        ),
 /*o*/.gmii_rx_dv             (gmii_rx_dv      ),
 /*o*/.gmii_rx_er             (gmii_rx_er      ),
 /*o*/.gmii_rx_clk            (gmii_rx_clk     ),
 .duplex_mode                 (duplex_mode     )
);



//==================================================================== 
//
//====================================================================


 
endmodule
