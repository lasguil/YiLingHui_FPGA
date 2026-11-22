`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// gmii_rx_buffer.v —— 10/100M 接收通路 1:2 速率适配（重写版）
//
// 【为什么需要它】
//   100M 的 RGMII 每拍只给 4bit（上升沿有效）= 12.5 Mbyte/s；
//   而 mac_top 的 GMII 要求「rx_dv 拉高期间每拍一个字节」= 25 Mbyte/s。
//   直接把 12.5 的流喂给 mac_top，帧内就会出现空拍，mac_top 会当成帧结束。
//
// 【本版做法 —— 和发送侧对称】
//   ① 收：每拍取一个半字节（gmii_rxd[3:0]，上升沿捕获的那个），
//          两个半字节拼成一个字节写进环形缓冲（低半字节先到）
//   ② 帧尾（rx_dv 落下）把 {起始偏移, 长度} 压进长度 FIFO
//   ③ 放：轮到这一帧时，用 25 Mbyte/s（每拍一字节、rx_dv 全程拉高）
//          整帧快速喂给 mac_top —— 对 mac_top 来说这就是一个正常的 GMII 帧
//
//   代价是"整帧收完才开始回放"，多了一帧的延迟。对本项目（不是实时转发）
//   完全无所谓，换来的是 mac_top 那边完全不用改。
//
// 【原版的问题】和发送侧同源：长度 FIFO 位宽 8（长度 16 位）、
//   没接 DC_FIFO 的 DataVal、FIFO 只有 32 字节深、写指针不复位。
//////////////////////////////////////////////////////////////////////////////
module gmii_rx_buffer
(
    input               clk,
    input               rst_n,
    input               eth_10_100m_en,
    input               link,

    input               gmii_rx_dv,         // 来自 PHY（经 util_gmii_to_rgmii）
    input      [7:0]    gmii_rxd,           // 只有低 4 位有效

    output reg          e10_100_rx_dv,      // 到 mac_top
    output reg [7:0]    e10_100_rxd,
    output reg          rx_busy,            // 正在往 mac_top 回放
    output reg          overflow
);

    localparam DATA_AW = 11;
    localparam DATA_N  = 1 << DATA_AW;
    localparam LEN_AW  = 4;
    localparam LEN_N   = 1 << LEN_AW;
    localparam [5:0] GAP = 6'd4;

    //----------------------------------------------------------------------
    // 数据环形缓冲
    //----------------------------------------------------------------------
    reg  [7:0]       mem [0:DATA_N-1];
    reg  [DATA_AW:0] wr_ptr, rd_ptr, cnt;

    wire data_full  = (cnt >= DATA_N[DATA_AW:0]);
    wire data_empty = (cnt == 0);

    //----------------------------------------------------------------------
    // 长度 FIFO：{起始偏移[10:0], 长度[15:0]}
    //----------------------------------------------------------------------
    reg  [26:0]      len_mem [0:LEN_N-1];
    reg  [LEN_AW:0]  len_wr, len_rd, len_cnt;
    wire len_full  = (len_cnt >= LEN_N[LEN_AW:0]);
    wire len_empty = (len_cnt == 0);
    wire [26:0] len_head = len_mem[len_rd[LEN_AW-1:0]];

    //----------------------------------------------------------------------
    // 收侧状态
    //----------------------------------------------------------------------
    reg         rx_dv_d;
    reg         half;                  // 0 = 等低半字节, 1 = 等高半字节
    reg  [3:0]  nib_low;
    reg  [15:0] rx_len;                // 已收到的字节数
    reg  [DATA_AW-1:0] frame_off;
    reg         ovf_frame;
    reg         flush;

    wire rx_rise = gmii_rx_dv & ~rx_dv_d;
    wire rx_fall = ~gmii_rx_dv & rx_dv_d;
    wire nib_v   = eth_10_100m_en & gmii_rx_dv & ~data_full;   // 本拍有一个有效半字节
    wire wr      = nib_v & half;                               // 凑满一个字节
    wire rd_pop  = (e10_100_rx_dv);                            // 回放中每拍消耗一字节

    //----------------------------------------------------------------------
    // 回放 FSM
    //----------------------------------------------------------------------
    localparam S_IDLE  = 2'd0,
               S_PRIME = 2'd1,
               S_PLAY  = 2'd2,
               S_GAP   = 2'd3;

    reg  [1:0]         state;
    reg  [15:0]        frame_len;
    reg  [15:0]        sent;
    reg  [DATA_AW-1:0] raddr;
    reg  [7:0]         dout;
    reg  [5:0]         gap_cnt;

    wire len_push = (state == S_IDLE) && !len_empty;

    always @(posedge clk) dout <= mem[raddr];

    //======================================================================
    // 收侧
    //======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !link) begin
            rx_dv_d   <= 1'b0;
            half      <= 1'b0;
            nib_low   <= 4'd0;
            rx_len    <= 16'd0;
            frame_off <= {DATA_AW{1'b0}};
            ovf_frame <= 1'b0;
            len_wr    <= {(LEN_AW+1){1'b0}};   // ← 忘了复位它，长度就写进 len_mem[x]
            overflow  <= 1'b0;
        end else begin
            rx_dv_d <= gmii_rx_dv;

            // 新的一帧开始
            if (rx_rise) begin
                frame_off <= wr_ptr[DATA_AW-1:0];
                rx_len    <= 16'd0;
                half      <= 1'b0;
                ovf_frame <= 1'b0;
            end

            if (nib_v) begin
                if (!half) begin
                    nib_low <= gmii_rxd[3:0];      // 先到的是低半字节
                    half    <= 1'b1;
                end else begin
                    half   <= 1'b0;
                    rx_len <= rx_len + 16'd1;
                end
            end

            if (eth_10_100m_en && gmii_rx_dv && data_full) ovf_frame <= 1'b1;

            flush <= 1'b0;
            // 帧尾：压 {偏移, 长度}
            if (rx_fall) begin
                if (ovf_frame) begin
                    overflow <= 1'b1;
                    len_wr   <= {(LEN_AW+1){1'b0}};
                    flush    <= 1'b1;
                end else if (eth_10_100m_en && !len_full && rx_len != 16'd0) begin
                    len_mem[len_wr[LEN_AW-1:0]] <= {frame_off, rx_len};
                    len_wr <= len_wr + 1'b1;
                end
                half <= 1'b0;
            end
        end
    end

    // 写数据（半字节拼接）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !link) begin
            wr_ptr <= {(DATA_AW+1){1'b0}};
        end else if (flush) begin
            wr_ptr <= {(DATA_AW+1){1'b0}};
        end else if (wr) begin
            mem[wr_ptr[DATA_AW-1:0]] <= {gmii_rxd[3:0], nib_low};
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // 占用计数
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !link) begin
            cnt    <= {(DATA_AW+1){1'b0}};
            rd_ptr <= {(DATA_AW+1){1'b0}};
        end else if (flush) begin
            cnt    <= {(DATA_AW+1){1'b0}};
            rd_ptr <= {(DATA_AW+1){1'b0}};
        end else begin
            if (rd_pop && !data_empty) rd_ptr <= rd_ptr + 1'b1;
            case ({wr, rd_pop && !data_empty})
                2'b10:   cnt <= cnt + 1'b1;
                2'b01:   cnt <= cnt - 1'b1;
                default: cnt <= cnt;
            endcase
        end
    end

    // 长度 FIFO 读指针
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !link) begin
            len_rd  <= {(LEN_AW+1){1'b0}};
            len_cnt <= {(LEN_AW+1){1'b0}};
        end else if (flush) begin
            len_rd  <= {(LEN_AW+1){1'b0}};
            len_cnt <= {(LEN_AW+1){1'b0}};
        end else begin
            if (len_push) begin
                len_rd  <= len_rd + 1'b1;
                len_cnt <= len_cnt - 1'b1;
            end else if (rx_fall && eth_10_100m_en && !ovf_frame && !len_full && rx_len != 16'd0) begin
                len_cnt <= len_cnt + 1'b1;
            end
        end
    end

    //======================================================================
    // 回放：整帧以每拍一字节喂给 mac_top
    //======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !link) begin
            state         <= S_IDLE;
            frame_len     <= 16'd0;
            sent          <= 16'd0;
            raddr         <= {DATA_AW{1'b0}};
            gap_cnt       <= 6'd0;
            e10_100_rx_dv <= 1'b0;
            e10_100_rxd   <= 8'd0;
            rx_busy       <= 1'b0;
        end else begin
            if (!eth_10_100m_en) begin
                state         <= S_IDLE;
                e10_100_rx_dv <= 1'b0;
                e10_100_rxd   <= 8'd0;
            end else begin
                case (state)
                S_IDLE: begin
                    e10_100_rx_dv <= 1'b0;
                    if (!len_empty) begin
                        frame_len <= len_head[15:0];
                        sent      <= 16'd0;
                        raddr     <= len_head[26:16];
                        if (len_head[15:0] == 16'd0) begin
                            gap_cnt <= 6'd0;
                            state   <= S_GAP;
                        end else begin
                            state <= S_PRIME;
                        end
                    end
                end
                S_PRIME: begin
                    // dout 此刻等于 mem[起点]；地址同时往前推一格，
                    // 这样 S_PLAY 第一拍就能把下一个字节预取进来
                    // （同步 RAM 读数据比地址晚一拍，不提前推会每个字节重发一次）
                    raddr <= raddr + 1'b1;
                    state <= S_PLAY;
                end
                S_PLAY: begin
                    e10_100_rx_dv <= 1'b1;
                    e10_100_rxd   <= dout;
                    sent          <= sent + 16'd1;
                    raddr         <= raddr + 1'b1;   // 同步 RAM 提前一拍取
                    if (sent + 16'd1 >= frame_len) begin
                        gap_cnt <= 6'd0;
                        state   <= S_GAP;
                    end
                end
                S_GAP: begin
                    e10_100_rx_dv <= 1'b0;
                    if (gap_cnt == GAP - 6'd1) state <= S_IDLE;
                    else                       gap_cnt <= gap_cnt + 6'd1;
                end
                endcase
            end
            rx_busy <= (len_cnt != 0) | (state != S_IDLE);
        end
    end

endmodule
