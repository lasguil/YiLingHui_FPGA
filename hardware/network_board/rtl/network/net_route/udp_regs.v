///////////////////////////////////////////////////////////////////////////////////
// udp_regs.v —— 网络板的控制面（我们自己的协议，替换厂家的 mac_test）
//
// 协议定义在 docs/network_control_protocol.md（改这里必须同步改文档）：
//   控制包（大端/网络序，12 字节）：
//     0  magic  u16 = 0x4354 ('CT')      6  reg    u16
//     2  ver    u8  = 1                  8  value  u32
//     3  op     u8  0=read 1=write 2=ack 3=nack 5=event
//     4  seq    u16
//   板子收到 read/write 后回 ack（同 seq、带回寄存器当前值）；另每 ~1s 主动发 event。
//
// ★ ARP 必须自己做：mac_top 不会自动发 ARP 请求，必须由用户侧拉 arp_request_req，
//   并且在 arp_found && !mac_not_exist 之前**发出去的包到不了 PC**（目的 MAC 无效）。
//   所以本模块有一个后台 ARP 状态机，TX 前会等 arp_ok。
//
// 与 mac_top 的用户口（厂家 heijin 栈给的是裸口，没有现成 FIFO/AXI-S）：
//   发送：设 udp_send_data_length → 拉 udp_tx_req → 等 udp_ram_data_req 脉冲
//         → 之后连续 tx_len 拍每拍 tx_wr=1 送一个字节
//         ⚠ **必须连续写**：写窗口与 udp_tx 的校验和状态机锁步，中途拉低会复位写地址
//   接收：udp_rec_data_valid 脉冲 → udp_rec_data_length（含 8 字节 UDP 头，payload = 减 8）
//         → 用 udp_rec_ram_read_addr 递增读 udp_rec_ram_rdata
//         ⚠ dpram 读地址有 1 拍延迟，所以按"发地址 → 下一拍取数"两拍一个字节做
//
// 时钟：整个设计都跑在 rxc（PHY 来的 125MHz）域，本模块用 gmii_tx_clk（=rxc）。
///////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module udp_regs #(
    parameter [31:0] ID_VALUE = 32'h4E42_3031,      // 'NB01'
    parameter [15:0] DEF_W    = 16'd640,
    parameter FIXED_VIDEO = 0,
    parameter [7:0] DEF_FPS = 8'd30,
    parameter [15:0] DEF_H    = 16'd480,
    parameter [15:0] CTRL_PORT= 16'd5000,           // 控制包目的端口（视频另用 5001）
    // ★ 百兆构建：clk = rxc = 25MHz（千兆时才是 125MHz），否则 1 秒 tick 变成 5 秒
    parameter [26:0] TICK_1S  = 27'd25_000_000,     // 25MHz 下 1 秒
    parameter PERSIST_DEST = 0                    // preserve peer across PHY/session reset
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cfg_reset_n, // board reset; used only with PERSIST_DEST=1

    // ---------------- 与 mac_top 的用户口 ----------------
    output reg  [7:0]  tx_data,
    output reg         tx_wr,
    output reg  [15:0] tx_len,
    output reg         tx_req,
    output reg         arp_req,
    output wire [15:0] dest_port,
    output wire        tx_busy,      // 整个发送过程(含写字节)为高，仲裁器靠它保持授权
    input  wire        tx_ram_req,          // udp_ram_data_req
    input  wire        arp_send_end,
    input  wire        mac_send_end,
    input  wire        arp_found,
    input  wire        mac_not_exist,

    input  wire [7:0]  rx_data,
    output reg  [10:0] rx_addr,
    input  wire [15:0] rx_len,
    input  wire        rx_valid,

    // ---------------- 板级状态（填进 LINK 寄存器）----------------
    input  wire [1:0]  link_speed,          // 0=10M 1=100M 2=1000M
    input  wire        link_up,
    input  wire        src5v,               // 处理板 A 的 +5V（HDMI 线里那一位）
    input  wire        pll_lock,
    input  wire        rxc_alive,
    input wire ddr_ready,
    input wire [5:0] board_status,
    input wire [31:0] default_dest_ip_addr,

    // ---------------- 配置输出（给视频模块用）----------------
    output reg  [15:0] cfg_w,
    output reg  [15:0] cfg_h,
    output reg  [7:0]  cfg_fps,
    output reg         cfg_stream_en,
    output reg  [15:0] cfg_pkt_size,
    output reg  [15:0] cfg_video_packet_gap,
    output reg  [1:0]  cfg_test_src,
    output reg  [31:0] cfg_dest_ip,
    output reg  [31:0] cfg_a_effect,
    output reg  [31:0] cfg_a_strength,
    output reg  [31:0] cfg_a_style,
    output reg  [31:0] cfg_a_freeze,
    output reg         a_cmd_valid,
    input  wire        a_cmd_ready,
    output reg  [31:0] a_cmd_token,
    output reg  [7:0]  a_cmd_type,
    output reg  [7:0]  a_cmd_length,
    output reg  [431:0] a_cmd_payload,
    input  wire        a_status_valid,
    input  wire [63:0] a_status_data,
    // ---------------- HDMI 抓帧状态（网页可读）----------------
    input  wire        hd_frame_valid,      // 抓到过完整帧且在 0.5s 内刷新过
    input  wire        hd_cap_using,        // 本帧正在用 HDMI 实拍像素
    input  wire        hd_cap_on,           // 写侧本帧在抓
    input  wire [11:0] hd_src_w,            // 实测源宽（1920 等）
    input  wire [11:0] hd_src_h,            // 实测源高（1080 等）
    input  wire [31:0] hd_frame_cnt,        // 已捕获帧数

    // 视频侧回填的统计
    input  wire [31:0] stat_frame_cnt,
    input  wire [31:0] stat_pkt_cnt,
    input  wire [31:0] stat_tx_err,

    // ---------------- 调试 ----------------
    output reg  [31:0] dbg_rx_pkts,         // 收到多少个控制包
    output reg  [31:0] dbg_tx_pkts,         // 回了多少个包
    output wire        dbg_arp_ok
);

    localparam [15:0] MAGIC_CTRL = 16'h4354;   // 'CT'
    localparam [7:0]  VER = 8'd1;
    localparam [7:0]  OP_READ=0, OP_WRITE=1, OP_ACK=2, OP_NACK=3, OP_EVENT=5;

    // ---- 状态机声明（★ 必须在下面的 assign 之前：本项目踩过"先用后声明"
    //      被综合成未驱动隐式网络的坑，mac_send_end_g 就是这样丢了 37Mbps 吞吐）----
    localparam A_IDLE=0, A_REQ=1, A_SEND=2, A_WAIT=3;
    localparam S_IDLE=0, S_RX_ADDR=1, S_RX_WAIT=2, S_RX_CAP=3, S_PARSE=4,
               S_TX_LEN=5, S_TX_WAIT=6, S_TX_WR=7, S_TX_DRAIN=8;
    reg [1:0]  ast;            // ARP 后台状态机
    reg [3:0]  st;             // 控制包状态机
    reg [95:0] hdr, resp;      // 收到的 12 字节头 / 要回的 12 字节
    reg [4:0]  cnt, rd, need;
    reg [7:0]  plen;

    localparam [15:0] R_DBG=16'h0030;   // 只读：内部状态打包，靠 event 上报
    localparam [15:0] R_DBG2=16'h0034;  // 只读：实际读到的包头前 4 字节
    localparam [15:0] R_ID=16'h0000, R_MODE=16'h0004, R_FPS=16'h0008, R_STREAM_EN=16'h000C,
                      R_PKT_SIZE=16'h0010, R_DEST_IP=16'h0014, R_DEST_PORT=16'h0018,
                      R_TEST_SRC=16'h001C,
                      R_FRAME_CNT=16'h0020, R_PKT_CNT=16'h0024, R_TX_ERR=16'h0028,
                      R_LINK=16'h002C,
                      R_HD_STATUS=16'h0038, R_HD_FRAME=16'h003C;

    reg [15:0] cfg_dest_port_r;
    reg [31:0] a_cmd_meta;
    reg [447:0] a_cmd_staging;
    reg [31:0] a_bridge_state;
    reg [31:0] a_status_detail, a_status_applied, a_status_tx_count;
    reg [31:0] a_status_errors, a_status_generation;
    reg [15:0] a_status_uart_seq;
    // ---- 调试用 ----
    reg        arp_seen;          // 锁存的 arp_found（它是脉冲，直接看永远是 0）
    reg [15:0] dbg_rx_len;        // 最近一次 rx_len
    reg [4:0]  dbg_need;          // 最近一次要读的字节数
    wire [31:0] hdr_hi = hdr[95:64];
    wire [31:0] dbg_val = {dbg_rx_pkts[7:0], dbg_rx_len,
                           mac_not_exist, arp_seen, rx_valid, st, ast};

    assign dest_port  = cfg_dest_port_r;
    // 同样要保持到 MAC 把帧发完（MAC 的头是在写完之后才发的）
    assign tx_busy    = (st == S_TX_LEN) || (st == S_TX_WAIT) || (st == S_TX_WR) || (st == S_TX_DRAIN);
    // ★★ 关键：能不能发 UDP 只看 mac_not_exist（它是电平）。
    //    arp_found 是匹配目标 peer 的合法 ARP request/reply 学习事件脉冲，
    //    与它相与会让 arp_ok 几乎永远为 0 -> 发送状态机永久卡死（踩过，很隐蔽）。
    //    厂家 mac_test 的判据同样只是 `if (mac_not_exist)`。
    assign dbg_arp_ok = ~mac_not_exist;

    wire [31:0] id_val   = ID_VALUE;
    wire [31:0] mode_val = {cfg_h, cfg_w};
    wire [31:0] link_val = {25'd0, ddr_ready, link_speed, link_up, src5v, pll_lock, rxc_alive};

    function [31:0] reg_read;
        input [15:0] r;
        begin
            case (r)
                R_ID        : reg_read = id_val;
                R_MODE      : reg_read = mode_val;
                R_FPS       : reg_read = {24'd0, cfg_fps};
                R_STREAM_EN : reg_read = {31'd0, cfg_stream_en};
                R_PKT_SIZE  : reg_read = {16'd0, cfg_pkt_size};
                R_DEST_IP   : reg_read = cfg_dest_ip;
                R_DEST_PORT : reg_read = {16'd0, cfg_dest_port_r};
                R_TEST_SRC  : reg_read = {30'd0, cfg_test_src};
                R_FRAME_CNT : reg_read = stat_frame_cnt;
                R_PKT_CNT   : reg_read = stat_pkt_cnt;
                R_TX_ERR    : reg_read = stat_tx_err;
                R_LINK      : reg_read = link_val;
                // 抓帧状态：[31]=有帧 [30]=正在用实拍 [29]=在抓
                //           [27:16]=源宽 [11:0]=源高
                R_HD_STATUS : reg_read = {hd_frame_valid, hd_cap_using, hd_cap_on,
                                          1'b0, hd_src_w, 4'd0, hd_src_h};
                16'h0040: reg_read={26'd0,board_status};
                16'h0044: reg_read={16'd0,cfg_video_packet_gap};
                R_HD_FRAME  : reg_read = hd_frame_cnt;
                R_DBG       : reg_read = dbg_val;
                R_DBG2      : reg_read = hdr_hi;
                16'h0100    : reg_read = cfg_a_effect;
                16'h0104    : reg_read = cfg_a_strength;
                16'h0108    : reg_read = cfg_a_style;
                16'h010C    : reg_read = cfg_a_freeze;
                16'h0120    : reg_read = 32'h4A374331; // J7C1 bridge present
                16'h0124    : reg_read = 32'h00000007; // TX, RX, and ACK available
                16'h0128    : reg_read = a_cmd_token;
                16'h012C    : reg_read = a_bridge_state;
                16'h0130    : reg_read = a_status_detail;
                16'h0134    : reg_read = a_status_applied;
                16'h0138    : reg_read = a_status_tx_count;
                16'h013C    : reg_read = a_status_errors;
                16'h0140    : reg_read = {16'd0,a_cmd_type,8'd0};
                16'h0144    : reg_read = a_status_uart_seq;
                16'h0148    : reg_read = (a_status_generation != 0) ? 32'd1 : 32'd0;
                16'h0150    : reg_read = a_status_generation;
                16'h0180    : reg_read = a_cmd_meta;
                16'h0184,16'h0188,16'h018C,16'h0190,16'h0194,16'h0198,
                16'h019C,16'h01A0,16'h01A4,16'h01A8,16'h01AC,16'h01B0,
                16'h01B4,16'h01B8: reg_read = a_cmd_staging[(r-16'h0184)*8 +: 32];
                default     : reg_read = 32'hDEAD_BEEF;
            endcase
        end
    endfunction

    task reg_write;
        input [15:0] r;
        input [31:0] v;
        begin
            case (r)
                R_MODE      : if (!FIXED_VIDEO) begin cfg_w <= v[15:0]; cfg_h <= v[31:16]; end
                R_FPS       : if (!FIXED_VIDEO) cfg_fps <= (v > 32'd120) ? 8'd120 : v[7:0];
                R_STREAM_EN : cfg_stream_en <= v[0];
                16'h0044: cfg_video_packet_gap <= v > 32'd65535 ? 16'hffff : v[15:0];
                R_PKT_SIZE  : if (!FIXED_VIDEO) cfg_pkt_size <= (v > 32'd1472) ? 16'd1472 : v[15:0];
                R_TEST_SRC  : cfg_test_src <= v[1:0];
                16'h0100    : cfg_a_effect <= v;
                16'h0104    : cfg_a_strength <= v;
                16'h0108    : cfg_a_style <= v;
                16'h010C    : cfg_a_freeze <= v;
                16'h0180    : a_cmd_meta <= v;
                16'h0184,16'h0188,16'h018C,16'h0190,16'h0194,16'h0198,
                16'h019C,16'h01A0,16'h01A4,16'h01A8,16'h01AC,16'h01B0,
                16'h01B4,16'h01B8: a_cmd_staging[(r-16'h0184)*8 +: 32] <= v;
                16'h01BC: begin
                    if (a_cmd_ready && a_cmd_meta[7:0] <= 8'd54) begin
                        a_cmd_valid <= 1'b1;
                        a_cmd_token <= v;
                        a_cmd_type <= a_cmd_meta[15:8];
                        a_cmd_length <= a_cmd_meta[7:0];
                        a_cmd_payload <= a_cmd_staging[431:0];
                        a_bridge_state <= 32'd1;
                    end else a_bridge_state <= 32'd8;
                end
                default     : ;
            endcase
        end
    endtask

    // Peer configuration belongs to the board session, not a PHY transaction.
    // The packet validation below exactly matches the write acceptance in S_PARSE.
    wire dest_reset_n = PERSIST_DEST ? cfg_reset_n : rst_n;
    always @(posedge clk or negedge dest_reset_n) begin
        if(!dest_reset_n) begin
            cfg_dest_ip <= default_dest_ip_addr;
            cfg_dest_port_r <= CTRL_PORT;
        end else if(rst_n && st==S_PARSE && need>=5'd12 &&
                    hdr[95:80]==MAGIC_CTRL && hdr[79:72]==VER && hdr[71:64]==OP_WRITE) begin
            if(hdr[47:32]==R_DEST_IP) cfg_dest_ip<=hdr[31:0];
            if(hdr[47:32]==R_DEST_PORT) cfg_dest_port_r<=hdr[15:0];
        end
    end

    // ============================ 1 秒 tick ============================
    reg [26:0] tick;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)      tick <= 27'd0;
        else if (tick == TICK_1S - 27'd1) tick <= 27'd0;
        else             tick <= tick + 27'd1;
    wire tick_1s = (tick == TICK_1S - 27'd1);

    // ============================ ARP 后台状态机 ============================
    reg [26:0] arp_wait;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ast      <= A_IDLE;
            arp_req  <= 1'b0;
            arp_wait <= 27'd0;
        end else case (ast)
            A_IDLE: begin
                arp_req <= 1'b0;
                if (!dbg_arp_ok && tick_1s) ast <= A_REQ;    // 没解析出来就每秒问一次（arp_ok 是电平）
            end
            A_REQ: begin
                // ★ 必须是 1 拍脉冲（厂家 mac_test 里是 (state==ARP_REQ)，只持续 1 拍）。
                //   之前写成"一直保持到 mac_send_end"，结果 ARP 请求把 MAC 发送通路占住，
                //   udp_ram_data_req 永不出现 -> 发送状态机死等（踩过）
                arp_req  <= 1'b1;
                arp_wait <= 27'd0;
                ast      <= A_SEND;
            end
            A_SEND: begin
                arp_req <= 1'b0;
                if (arp_send_end || arp_wait >= TICK_1S) begin   // 等这一帧发完（带超时）
                    arp_wait <= 27'd0;
                    ast      <= A_WAIT;
                end else
                    arp_wait <= arp_wait + 27'd1;
            end
            A_WAIT: begin
                if (dbg_arp_ok) begin
                    ast <= A_IDLE;                            // 解析到了
                end else if (arp_wait >= TICK_1S) begin
                    arp_wait <= 27'd0;
                    ast      <= A_IDLE;                       // 超时，回 IDLE 再试
                end else
                    arp_wait <= arp_wait + 27'd1;
            end
            default: ast <= A_IDLE;
        endcase
    end

    // ---- rx_valid 上升沿检测 --------------------------------------------
    // ★★ udp_rec_data_valid 不是脉冲，而是**电平**：在 REC_END 置 1 后一直保持，
    //    直到下一个包的 REC_END_WAIT 才清 0（udp_rx.v:369-382 只在两处赋值）。
    //    如果直接用电平做触发，S_IDLE 会反复处理同一个包 -> 全速洪泛（实测 70 万包/秒，踩过）。
    reg rx_valid_d;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rx_valid_d <= 1'b0;
        else        rx_valid_d <= rx_valid;
    wire rx_valid_rise = rx_valid & ~rx_valid_d;

    // ============================ 控制包状态机 ============================
    reg [23:0] tx_to;                       // S_TX_WAIT 超时（~134ms @125MHz）
    reg        ev_pending;
    reg [2:0]  ev_which;
    reg [15:0] ev_reg;
    reg [31:0] ev_val;

    // 需要收多少字节：min(payload, 12)
    wire [7:0] plen_w = (rx_len >= 16'd8) ? (rx_len[7:0] - 8'd8) : 8'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= S_IDLE;
            cnt           <= 5'd0;
            rd            <= 5'd0;
            need          <= 5'd0;
            plen          <= 8'd0;
            rx_addr       <= 11'd0;
            tx_data       <= 8'd0;
            tx_wr         <= 1'b0;
            tx_len        <= 16'd0;
            tx_req        <= 1'b0;
            hdr           <= 96'd0;
            resp          <= 96'd0;
            cfg_w         <= DEF_W;
            cfg_h         <= DEF_H;
            cfg_fps       <= DEF_FPS;
            cfg_stream_en <= 1'b1;      // 默认出流
            cfg_video_packet_gap <= 16'd0; // diagnostic spacing disabled by default
            cfg_pkt_size  <= 16'd1472;
            cfg_test_src  <= 2'd0;   // 0=HDMI 实拍(自动回退) 1=强制内置图案
            cfg_a_effect  <= 32'd1;
            cfg_a_strength<= 32'd60;
            cfg_a_style   <= 32'd0;
            cfg_a_freeze  <= 32'd0;
            a_cmd_valid <= 1'b0;
            a_cmd_token <= 32'd0;
            a_cmd_type <= 8'd0;
            a_cmd_length <= 8'd0;
            a_cmd_payload <= 432'd0;
            a_cmd_meta <= 32'd0;
            a_cmd_staging <= 448'd0;
            a_bridge_state <= 32'd0;
            a_status_detail <= 32'd0;
            a_status_applied <= 32'd0;
            a_status_tx_count <= 32'd0;
            a_status_errors <= 32'd0;
            a_status_generation <= 32'd0;
            a_status_uart_seq <= 16'd0;
            dbg_rx_pkts   <= 32'd0;
            dbg_tx_pkts   <= 32'd0;
            ev_pending    <= 1'b0;
            ev_which      <= 3'd0;
            tx_to         <= 24'd0;
        end else begin
            tx_wr <= 1'b0;
            a_cmd_valid <= 1'b0;
            if (a_status_valid) begin
                a_cmd_token <= a_status_data[31:0];
                a_bridge_state <= {24'd0,a_status_data[39:32]};
                a_status_detail <= {24'd0,a_status_data[47:40]};
                a_status_uart_seq <= a_status_data[63:48];
                a_status_generation <= a_status_generation + 32'd1;
                if (a_status_data[39:32] == 8'd4)
                    a_status_tx_count <= a_status_tx_count + 32'd1;
                if (a_status_data[39:32] == 8'd9 || a_status_data[39:32] == 8'd11)
                    a_status_errors <= a_status_errors + 32'd1;
                if (a_status_data[39:32] == 8'd6)
                    a_status_applied <= a_status_data[31:0];
            end

            if (arp_found) arp_seen <= 1'b1;
            if (tick_1s) begin
                ev_pending <= 1'b1;
                ev_which   <= ev_which + 3'd1;      // 0..3 轮流上报
                case (ev_which)
                    3'd0: begin ev_reg <= R_FRAME_CNT; ev_val <= stat_frame_cnt; end
                    3'd1: begin ev_reg <= R_LINK;      ev_val <= link_val;       end
                    3'd2: begin ev_reg <= R_DBG;       ev_val <= dbg_val;       end
                    default: begin ev_reg <= R_DBG2;   ev_val <= hdr_hi;        end
                endcase
            end

            case (st)
            S_IDLE: begin
                tx_req <= 1'b0;
                if (rx_valid_rise) begin          // ★ 只能认上升沿
                    dbg_rx_len <= rx_len;
                    plen    <= plen_w;
                    need    <= (plen_w < 8'd12) ? plen_w[4:0] : 5'd12;
                    dbg_need <= (plen_w < 8'd12) ? plen_w[4:0] : 5'd12;
                    rd      <= 5'd0;
                    st      <= S_RX_ADDR;
                    dbg_rx_pkts <= dbg_rx_pkts + 32'd1;
                end else if (ev_pending) begin
                    ev_pending <= 1'b0;
                    resp <= {MAGIC_CTRL, VER, OP_EVENT, 16'd0,
                             ev_reg,
                             ev_val};
                    cnt  <= 5'd0;
                    st   <= S_TX_LEN;
                end
            end

            // ★ dpram 是 raddr_reg <= rdaddress; q = ram[raddr_reg]，
            //   所以 q(T+1)=ram[addr(T)]：设了地址后要**等 2 拍**数据才有效。
            //   之前只等 1 拍 -> 读到的永远是上一个地址的字节，包头整体错位（踩过）
            S_RX_ADDR: begin
                rx_addr <= {6'd0, rd};
                st      <= S_RX_WAIT;
            end
            S_RX_WAIT: begin
                st      <= S_RX_CAP;
            end
            S_RX_CAP: begin
                // ★ 字节序：hdr 里 **byte0(最先到) 放在最高位 [95:88]**，
                //   这样 hdr[95:80]=magic、[79:72]=ver、[71:64]=op…与提取代码一致。
                //   （曾经写成 hdr[8*rd] 导致整包反序、板子回 NACK）
                if (rd < 5'd12) hdr[8*(5'd11 - rd) +: 8] <= rx_data;
                if (rd + 5'd1 >= need) st <= S_PARSE;
                else begin
                    rd <= rd + 5'd1;
                    st <= S_RX_ADDR;
                end
            end

            S_PARSE: begin
                if (need >= 5'd12 && hdr[95:80] == MAGIC_CTRL && hdr[79:72] == VER) begin
                    if (hdr[71:64] == OP_WRITE) begin
                        if (hdr[47:32] == 16'h01BC && !a_cmd_ready) begin
                            resp <= {MAGIC_CTRL, VER, OP_NACK, hdr[63:48], hdr[47:32], 32'd8};
                        end else begin
                            reg_write(hdr[47:32], hdr[31:0]);
                            // ACK confirms B accepted the register write/commit.
                            resp <= {MAGIC_CTRL, VER, OP_ACK, hdr[63:48], hdr[47:32], hdr[31:0]};
                        end
                    end else
                        resp <= {MAGIC_CTRL, VER, OP_ACK, hdr[63:48], hdr[47:32],
                                 reg_read(hdr[47:32])};
                end else
                    resp <= {MAGIC_CTRL, VER, OP_NACK, 16'd0, 16'd0, 32'd0};
                cnt <= 5'd0;
                st  <= S_TX_LEN;
            end

            S_TX_LEN: begin
                tx_to <= tx_to + 24'd1;
                // A periodic event can wait here while ARP is unresolved. Do not
                // lose a one-shot control RX pulse during that wait: receive and
                // apply the new destination register before retrying the ACK.
                if (rx_valid_rise) begin
                    dbg_rx_len <= rx_len;
                    plen    <= plen_w;
                    need    <= (plen_w < 8'd12) ? plen_w[4:0] : 5'd12;
                    dbg_need <= (plen_w < 8'd12) ? plen_w[4:0] : 5'd12;
                    rd      <= 5'd0;
                    st      <= S_RX_ADDR;
                    tx_req  <= 1'b0;
                    tx_to   <= 24'd0;
                    dbg_rx_pkts <= dbg_rx_pkts + 32'd1;
                end else if (dbg_arp_ok) begin    // ★ 等 ARP 解析好再发，否则包到不了
                    tx_len <= 16'd12;
                    tx_req <= 1'b1;
                    tx_to  <= 24'd0;
                    st     <= S_TX_WAIT;
                end else if (tx_to == 24'hFFFFFF) begin
                    st <= S_IDLE;                // ~134ms 还没解析出来就放弃这一包（PC 会重试）
                end
            end

            S_TX_WAIT: begin
                tx_to <= tx_to + 24'd1;
                if (tx_ram_req) begin
                    tx_req <= 1'b0;
                    cnt    <= 5'd0;
                    st     <= S_TX_WR;
                end else if (tx_to == 24'hFFFFFF) begin
                    // 超时兜底：宁可丢这一包，也不能永久卡死（否则连 event 都不发了）
                    tx_req <= 1'b0;
                    st     <= S_IDLE;
                end
            end

            // ★ 12 拍必须连续写，中间不能停。同样按 byte0 在最高位的约定取字节。
            S_TX_WR: begin
                tx_data <= resp[8*(5'd11 - cnt) +: 8];
                tx_wr   <= 1'b1;
                if (cnt == 5'd11) begin
                    cnt         <= 5'd0;
                    st          <= S_TX_DRAIN;       // ★ 等 MAC 发完再回 IDLE
                    dbg_tx_pkts <= dbg_tx_pkts + 32'd1;
                end else
                    cnt <= cnt + 5'd1;
            end

            S_TX_DRAIN: begin
                if (mac_send_end) st <= S_IDLE;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
