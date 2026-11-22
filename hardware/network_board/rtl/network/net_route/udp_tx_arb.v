// Two-client UDP submission arbiter. Control has priority at packet boundaries.
// The grant and latched port/length survive the entire UDP->IP->MAC transaction,
// including concurrent unsolicited ARP/ICMP traffic. Replay FIFO capacity is an
// independent admission condition; no guessed delay is normal pacing.
`timescale 1ns / 1ps

module udp_tx_arb (
    input  wire        clk,
    input  wire        rst_n,

    // ---------------- client 0：控制面（高优先）----------------
    input  wire [7:0]  c0_data,
    input  wire        c0_wr,
    input  wire [15:0] c0_len,
    input  wire        c0_req,
    input  wire        c0_busy,
    input  wire [15:0] c0_port,
    input  wire [15:0] c0_source_port,
    output wire        c0_ram_req,

    // ---------------- client 1：视频分包 ----------------
    input  wire [7:0]  c1_data,
    input  wire        c1_wr,
    input  wire [15:0] c1_len,
    input  wire        c1_req,
    input  wire        c1_busy,
    input  wire [15:0] c1_port,
    input  wire [15:0] c1_source_port,
    output wire        c1_ram_req,

    // ---------------- 到 mac_top ----------------
    output reg  [7:0]  tx_data,
    output reg         tx_wr,
    output reg  [15:0] tx_len,
    output reg         tx_req,
    output reg  [15:0] dest_port,
    output reg  [15:0] source_port,
    input  wire        tx_ram_req,
    input  wire        tx_accept_ready,
    input  wire        mac_send_end,     // MAC 把一帧真正发完（1 拍脉冲）
    output wire [23:0] timeout_count,
    output wire        dbg_grant,        // 【诊断】是否正在授权某一路
    output wire        dbg_mac_busy,     // 【诊断】MAC 忙标志
    output wire        dbg_tx_req        // 【诊断】正在向 MAC 请求发送
);

    // ★ 声明必须在使用之前（mac_send_end_g 就是这样被综合成未驱动常量 0 的）
    reg  grant0, grant1;
    reg  mac_busy;
    reg  [23:0] fail_to;
    wire tx_req_to_mac;

assign timeout_count = fail_to;
assign dbg_grant    = grant0 | grant1;
assign dbg_mac_busy = mac_busy;
assign dbg_tx_req   = tx_req_to_mac;

    // One UDP transaction owns metadata until its qualified MAC completion.
    // A 4096-byte replay FIFO separately admits only complete-frame capacity.
    reg [15:0] held_len,held_port,held_source_port;
    reg [15:0] watchdog;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant0<=0;grant1<=0;mac_busy<=0;fail_to<=0;
            held_len<=0;held_port<=0;held_source_port<=0;watchdog<=0;
        end else begin
            if (!grant0 && !grant1) begin
                mac_busy<=0;watchdog<=0;
                if (tx_accept_ready && c0_req) begin
                    grant0<=1;held_len<=c0_len;held_port<=c0_port;
                    held_source_port<=c0_source_port;mac_busy<=1;
                end else if (tx_accept_ready && c1_req) begin
                    grant1<=1;held_len<=c1_len;held_port<=c1_port;
                    held_source_port<=c1_source_port;mac_busy<=1;
                end
            end else begin
                if (mac_send_end) begin
                    grant0<=0;grant1<=0;mac_busy<=0;watchdog<=0;
                end else if (watchdog!=16'hffff) watchdog<=watchdog+1'b1;
                // A failed MAC stays blocked until reset, never releases corrupt metadata.
                if(watchdog==16'hfffe)fail_to<=fail_to+1'b1;
            end
        end
    end

    assign tx_req_to_mac = grant0 ? c0_req : (grant1 ? c1_req : 1'b0);

    always @(*) begin
        if (grant0) begin
            tx_data   = c0_data;
            tx_wr     = c0_wr;
            tx_len    = held_len;
            tx_req    = c0_req;
            dest_port = held_port;
        source_port = held_source_port;
        end else if (grant1) begin
            tx_data   = c1_data;
            tx_wr     = c1_wr;
            tx_len    = held_len;
            tx_req    = c1_req;
            dest_port = held_port;
        source_port = held_source_port;
        end else begin
            tx_data   = 8'd0;
            tx_wr     = 1'b0;
            tx_len    = 16'd0;
            tx_req    = 1'b0;
            dest_port = held_port;      // 空闲时给控制端口
        source_port = held_source_port;
        end
    end

    // ram_req 只回给被授权的那一路（客户端靠它知道"写窗口开始了"）
    assign c0_ram_req = tx_ram_req & grant0;
    assign c1_ram_req = tx_ram_req & grant1;

endmodule
