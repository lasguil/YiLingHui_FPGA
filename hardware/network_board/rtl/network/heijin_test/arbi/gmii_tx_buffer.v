`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// gmii_tx_buffer.v —— 10/100M 发送通路 2:1 速率适配（重写版）
//
// 【为什么需要它】
//   100M 的 RGMII 是「25MHz 时钟 + 每拍 4bit（上升沿有效）」= 12.5 Mbyte/s；
//   而 mac_top 的 GMII 是 8bit/拍 @ 同一个 clk = 25 Mbyte/s。
//   必须把字节流按 2 拍 1 字节吐出去，否则发出去的东西全是错的。
//
// 【原版为什么坏】（见 net_ref/ETH_100M_FINDINGS.md）
//   ① 长度 FIFO 例化成 DATA_WIDTH(8)，长度是 16 位 → 高 8 位被截掉
//   ② 完全没接 DC_FIFO 的 DataVal（读数据有效指示）→ 采样时机不对
//   ③ 数据 FIFO 只有 32 字节深，一帧最长 1518 字节 → 必然溢出
//   ④ WrFull 悬空 → 没有反压 → 溢出就是静默丢数据
//   结果是 pack_len 无效 → 状态机永久停在 SEND → e10_100_tx_en 常高
//   → 持续发送、没有 IFG → PHY 链路被打死。
//
// 【本版做法】
//   · 数据：4096 x 8 同步 FIFO（单时钟域，手写，行为一目了然）
//   · 长度：16 x 28 独立 FIFO（长度就是 16 位，不做任何截断）
//   · 每帧先整帧收进数据 FIFO，再按「低半字节 → 高半字节」2 拍 1 字节吐出；
//     半字节在 {nib,nib} 里重复两次，PHY 无论按上升沿采样还是双沿采样都能取对
//   · 帧之间留 GAP 拍 IFG，绝不出现"连续无间隔发送"
//   · accept_ready reserves capacity for a complete unstalled MAC frame.
//     This permits preparation while an earlier frame is replaying.
//   · overflow 只在"上层没遵守流控"或缓冲被塞爆时置位，属诊断用途；
//     一旦发生就整块清空，避免脏数据混进后续帧
//////////////////////////////////////////////////////////////////////////////
module gmii_tx_buffer
(
    input               clk,                // 收发同源：rxc（千兆 125M / 百兆 25M）
    input               rst_n,
    input               eth_10_100m_en,     // 1 = 走 10/100M 通路
    input               link,               // 链路正常（e_rst_n）

    input               gmii_tx_en,         // 来自 mac_top
    input      [7:0]    gmii_txd,

    output reg          e10_100_tx_en,      // 到 gmii_arbi → util_gmii_to_rgmii
    output reg [7:0]    e10_100_txd,
    output reg          play_busy,          // 缓冲里还有东西 / 正在播
    output reg          frame_done,         // 一帧播完，1 拍脉冲
    output wire         accept_ready,       // capacity for a complete non-stallable frame
    output reg          overflow            // 缓冲溢出过（诊断）
);

    //======================================================================
    // 参数
    //======================================================================
    localparam DATA_AW = 12;                    // 4096 bytes, two full frames
    localparam DATA_N  = 1 << DATA_AW;
    localparam LEN_AW  = 4;                     // 16 条长度
    localparam LEN_N   = 1 << LEN_AW;
    localparam [5:0] GAP = 6'd24;                // 帧间 IFG（拍）

    //======================================================================
    // Data FIFO (4096 x 8, synchronous)
    //======================================================================
    reg  [7:0]       mem [0:DATA_N-1];
    reg  [DATA_AW:0] wr_ptr, rd_ptr, cnt;

    wire data_full  = (cnt >= DATA_N[DATA_AW:0]);
    wire data_empty = (cnt == 0);

    //======================================================================
    // Descriptor FIFO: 16 entries of {12-bit ring offset,16-bit length}
    //   起始偏移必须逐帧记住：写指针是环形自由跑的，不能假设每帧都从 0 开始
    //   （原版就是栽在这里：wr_ptr 不复位，读侧却永远从 0 读）
    //======================================================================
    reg  [DATA_AW+15:0] len_mem [0:LEN_N-1];
    reg  [LEN_AW:0]  len_wr, len_rd, len_cnt;

    wire len_full  = (len_cnt >= LEN_N[LEN_AW:0]);
    wire len_empty = (len_cnt == 0);
    assign accept_ready = (cnt <= DATA_N-2048) && (len_cnt < LEN_N-2) && !overflow;
    wire [DATA_AW+15:0] len_head = len_mem[len_rd[LEN_AW-1:0]];

    //======================================================================
    // 写侧状态
    //======================================================================
    reg  gmii_tx_en_d;
    reg  [15:0] wr_len;          // 当前帧已写入字节数
    reg  [DATA_AW-1:0] frame_off; // 当前帧在环形缓冲里的起始偏移
    reg  flush;                  // 溢出作废：用脉冲通知其它 always 块各自清计数器
                                 // （同一根寄存器不能在两个 always 块里赋值）
    reg         ovf_frame;       // 当前帧溢出过

    wire en_rise = gmii_tx_en & ~gmii_tx_en_d;
    wire en_fall = ~gmii_tx_en & gmii_tx_en_d;
    wire wr      = eth_10_100m_en & gmii_tx_en & ~data_full;

    //======================================================================
    // 读侧状态机
    //======================================================================
    localparam S_IDLE  = 2'd0,
               S_PRIME = 2'd1,   // 1 拍，等 RAM 把第 0 字节吐出来
               S_PLAY  = 2'd2,
               S_GAP   = 2'd3;

    reg  [1:0]         state;
    reg                phase;        // 0 = 低半字节, 1 = 高半字节
    reg  [15:0]        frame_len;
    reg  [15:0]        sent;
    reg  [7:0]         dout;         // 同步读出的当前字节
    reg  [DATA_AW-1:0] raddr;
    reg  [5:0]         gap_cnt;

    wire rd_pop = (state == S_PLAY) & phase;   // 每 2 拍消费 1 字节
    wire len_push = (state == S_IDLE) && !len_empty;   // 弹一条长度

    //======================================================================
    // 边沿检测
    //======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) gmii_tx_en_d <= 1'b0;
        else        gmii_tx_en_d <= gmii_tx_en;
    end

    //======================================================================
    // 写侧：把 mac_top 的 GMII 字节收进数据 FIFO，帧尾压长度
    //======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !link) begin
            wr_ptr    <= {(DATA_AW+1){1'b0}};
            wr_len    <= 16'd0;
            ovf_frame <= 1'b0;
            len_wr    <= {(LEN_AW+1){1'b0}};   // ← 忘了复位它，长度就会写进 len_mem[x]
            overflow  <= 1'b0;
            flush <= 1'b0;
        end else begin
            if (en_rise) begin
                wr_len    <= 16'd1;        // 这一拍 gmii_tx_en 已经拉高，第 0 字节同拍写入
                ovf_frame <= 1'b0;
                frame_off <= wr_ptr[DATA_AW-1:0];   // ★ 记住本帧起点
            end else if (wr) begin
                wr_len    <= wr_len + 16'd1;
            end

            if (wr) begin
                mem[wr_ptr[DATA_AW-1:0]] <= gmii_txd;
                wr_ptr <= wr_ptr + 1'b1;
            end

            // 缓冲满但还在写 = 溢出
            if (eth_10_100m_en && gmii_tx_en && data_full)
                ovf_frame <= 1'b1;

            // 帧尾：压长度
            flush <= 1'b0;
            if (en_fall) begin
                if (ovf_frame) begin
                    // 本帧作废：本块只清自己拥有的寄存器，其余的用 flush 通知
                    overflow <= 1'b1;
                    wr_ptr   <= {(DATA_AW+1){1'b0}};
                    len_wr   <= {(LEN_AW+1){1'b0}};
                    flush    <= 1'b1;
                end else if (eth_10_100m_en && !len_full) begin
                    len_mem[len_wr[LEN_AW-1:0]] <= {frame_off, wr_len};
                    len_wr  <= len_wr + 1'b1;
                end else begin
                    overflow <= 1'b1;       // 长度队列满：同样属"不该发生"
                end
                wr_len <= 16'd0;
            end
        end
    end

    //======================================================================
    // cnt（数据 FIFO 字节数）与指针
    //======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !link) begin
            rd_ptr <= {(DATA_AW+1){1'b0}};
            cnt    <= {(DATA_AW+1){1'b0}};
        end else if (flush) begin
            rd_ptr <= {(DATA_AW+1){1'b0}};
            cnt    <= {(DATA_AW+1){1'b0}};
        end else begin
            if (rd_pop && !data_empty) rd_ptr <= rd_ptr + 1'b1;

            case ({wr, rd_pop && !data_empty})
                2'b10:   cnt <= cnt + 1'b1;
                2'b01:   cnt <= cnt - 1'b1;
                default: cnt <= cnt;                 // 同拍读写 / 都不动
            endcase
        end
    end

    //======================================================================
    // 长度 FIFO 读指针
    //======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !link) begin
            len_rd  <= {(LEN_AW+1){1'b0}};
            len_cnt <= {(LEN_AW+1){1'b0}};
        end else if (flush) begin
            len_rd  <= {(LEN_AW+1){1'b0}};
            len_cnt <= {(LEN_AW+1){1'b0}};
        end else begin
            if (len_push) len_rd <= len_rd + 1'b1;
            case ({en_fall && !ovf_frame && !len_full, len_push})
                2'b10: len_cnt <= len_cnt + 1'b1;
                2'b01: len_cnt <= len_cnt - 1'b1;
                default: len_cnt <= len_cnt;
            endcase
        end
    end

    //======================================================================
    // 同步读数据 RAM
    //======================================================================
    always @(posedge clk) dout <= mem[raddr];

    //======================================================================
    // 读侧 FSM：整帧按 2 拍 1 字节播出
    //======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !link) begin
            state         <= S_IDLE;
            phase         <= 1'b0;
            frame_len     <= 16'd0;
            sent          <= 16'd0;
            raddr         <= {DATA_AW{1'b0}};
            gap_cnt       <= 6'd0;
            frame_done    <= 1'b0;
            e10_100_tx_en <= 1'b0;
            e10_100_txd   <= 8'd0;
            play_busy     <= 1'b0;
        end else begin
            frame_done <= 1'b0;

            if (!eth_10_100m_en) begin
                // 千兆模式：走直通，本模块输出全 0
                state         <= S_IDLE;
                phase         <= 1'b0;
                e10_100_tx_en <= 1'b0;
                e10_100_txd   <= 8'd0;
            end else begin
                case (state)
                //----------------------------------------------------------
                S_IDLE: begin
                    e10_100_tx_en <= 1'b0;
                    if (!len_empty) begin
                        frame_len <= len_head[15:0];
                        sent      <= 16'd0;
                        raddr     <= len_head[DATA_AW+15:16];   // ★ 从本帧记录的起点读
                        if (len_head[15:0] == 16'd0) begin
                            // 长度为 0 = 该帧被作废，直接跳过一个 gap
                            frame_done <= 1'b1;
                            gap_cnt    <= 6'd0;
                            state      <= S_GAP;
                        end else begin
                            state <= S_PRIME;
                        end
                    end
                end
                //----------------------------------------------------------
                S_PRIME: begin
                    // dout 此刻已经等于 mem[0]（raddr 在 IDLE 拍写 0 后的下一拍出数据）
                    state <= S_PLAY;
                    phase <= 1'b0;
                end
                //----------------------------------------------------------
                S_PLAY: begin
                    e10_100_tx_en <= 1'b1;
                    if (!phase) begin
                        // 低半字节（重复两次），与 util_gmii_to_rgmii 的
                        // rgmii_txd_hi <= gmii_txd[3:0] 呼应：低半字节先出
                        e10_100_txd <= {dout[3:0], dout[3:0]};
                        phase       <= 1'b1;
                        // ★ 同步 RAM 的读数据比地址晚一拍，所以必须在这里就把
                        //   地址推到下一个字节；放到 phase==1 会让每个字节重发一次
                        raddr       <= raddr + 1'b1;
                    end else begin
                        // 高半字节（重复两次）
                        e10_100_txd <= {dout[7:4], dout[7:4]};
                        phase       <= 1'b0;
                        sent        <= sent + 16'd1;
                        if (sent + 16'd1 >= frame_len) begin
                            // 本帧最后一个字节：tx_en 必须保持到这一拍结束，
                            // 由 S_GAP 再落下（否则最后一个半字节会被 PHY 丢掉）
                            gap_cnt       <= 6'd0;
                            frame_done    <= 1'b1;
                            state         <= S_GAP;
                        end
                    end
                end
                //----------------------------------------------------------
                S_GAP: begin
                    // 帧间 IFG，绝不连续发送
                    e10_100_tx_en <= 1'b0;
                    if (gap_cnt == GAP - 6'd1) state <= S_IDLE;
                    else                       gap_cnt <= gap_cnt + 6'd1;
                end
                endcase
            end

            // play_busy：缓冲里还有帧 或 不在空闲态 —— 上层据此延后 mac_send_end
            play_busy <= (len_cnt != 0) | (state != S_IDLE) | (cnt != 0);
        end
    end

endmodule
