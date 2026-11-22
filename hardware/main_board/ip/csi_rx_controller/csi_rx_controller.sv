// ---------------------------------------------------------------------------
// csi2_rx_min - purpose-built replacement for the encrypted efx_csi2_rx
//
// Scope is fixed by how the board actually wires the original (rtl/ti60f225_oob_top.v:506).
// Only four signals are consumed downstream - pixel_data[63:0], pixel_data_valid,
// hsync_vc0, vsync_vc0 - and only VC0 is used: the AXI register file is tied off
// at the instantiation (axi_clk = 1'b0), every vc1..vc15 sync is unconnected,
// DLY_* is unconnected and Rx_HS_D_4..7 are unconnected.  The port list keeps the
// original names so this is a drop-in replacement.
//
// The hard MIPI PHY already deserialises: Rx_HS_D_0..3 arrive as one byte per lane
// per clk_byte_HS, each lane behind its own FIFO whose read side is handed to us as
// fifo_rd_enable / fifo_rd_empty.  No analog work belongs in this module.
//
// Rate arithmetic that drives the structure: four lanes deliver four bytes per
// clk_byte_HS, so
//   * a 4-byte CSI-2 packet header is exactly one clock wide,
//   * a RAW10 payload is a byte stream in which every five bytes are four pixels.
// The five-byte grouping does not align to the four-byte clock, so the payload
// alone goes through a 4-in / 5-out gearbox; each popped group becomes one
// four-pixel word.
//
// RAW10 grouping is the MIPI one: B0..B3 carry bits [9:2] of p0..p3 and B4 carries
// the four [1:0] pairs.  pixel_data is packed as
//   [9:0]=p0 [19:10]=p1 [29:20]=p2 [39:30]=p3
// which is what rtl/csi4_to_pix1.v expects ("Efinix RAW10 table 19").
//
// 2026-10-14: direct protocol regression covers ECC basis, nonzero short data,
// per-lane SoT skew, transparent RAW10 payload and masked CRC footer drains.
    // Scope: VC0 RAW10 with WC a multiple of 20 and a SoT per HS burst (LP gaps
    // are optional). Each burst may begin at a different recovered-byte phase.
    // CRC bytes are consumed, not validated. Hardware FIFO capacity, receiver
    // termination timing and camera output remain to be checked on board.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module csi_rx_controller #(
    parameter logic [7:0]  SYNC_BYTE = 8'hB8,
    parameter logic [5:0]  DT_RAW10  = 6'h2B,
    parameter logic [5:0]  DT_FS     = 6'h00,
    parameter logic [5:0]  DT_FE     = 6'h01,
    parameter logic [5:0]  DT_LS     = 6'h02,
    parameter logic [5:0]  DT_LE     = 6'h03,
    parameter int unsigned LP_SETTLE = 4,
    // Board pixel clock is 100 MHz, byte clock is 78.75 MHz. Faster average
    // drain alone does not prove capacity: both Gray pointers need two CDC
    // stages, and control tokens also consume entries. Depth 4 drops tokens
    // at these board clocks; depth 8 passes the phase-swept protocol regression.
    parameter int unsigned OUT_AW    = 3,
    parameter bit          LP_GATED_HS = 1'b1
) (
    input  logic        reset_n,
    input  logic        clk,
    input  logic        reset_byte_HS_n,
    input  logic        clk_byte_HS,
    input  logic        reset_pixel_n,
    input  logic        clk_pixel,
    input  logic        Rx_LP_CLK_P,
    input  logic        Rx_LP_CLK_N,
    output logic        Rx_HS_enable_C,
    output logic        LVDS_termen_C,
    input  logic [3:0]  Rx_LP_D_P,
    input  logic [3:0]  Rx_LP_D_N,
    input  logic [7:0]  Rx_HS_D_0,
    input  logic [7:0]  Rx_HS_D_1,
    input  logic [7:0]  Rx_HS_D_2,
    input  logic [7:0]  Rx_HS_D_3,
    input  logic [7:0]  Rx_HS_D_4,
    input  logic [7:0]  Rx_HS_D_5,
    input  logic [7:0]  Rx_HS_D_6,
    input  logic [7:0]  Rx_HS_D_7,
    output logic [3:0]  Rx_HS_enable_D,
    output logic [3:0]  LVDS_termen_D,
    output logic [3:0]  fifo_rd_enable,
    input  logic [3:0]  fifo_rd_empty,
    output logic [3:0]  DLY_enable_D,
    output logic [3:0]  DLY_inc_D,
    input  logic [3:0]  u_dly_enable_D,
    output logic        vsync_vc0,
    output logic        hsync_vc0,
    output logic        irq,
    output logic        pixel_data_valid,
    output logic [63:0] pixel_data,
    output logic [3:0]  pixel_per_clk,
    output logic [5:0]  datatype,
    output logic [15:0] shortpkt_data_field,
    output logic [15:0] word_count,
    output logic [1:0]  vcx,
    output logic [1:0]  vc,
    output logic        vsync_vc1,
    output logic        vsync_vc2,
    output logic        vsync_vc3,
    output logic        vsync_vc4,
    output logic        vsync_vc5,
    output logic        vsync_vc6,
    output logic        vsync_vc7,
    output logic        vsync_vc8,
    output logic        vsync_vc9,
    output logic        vsync_vc10,
    output logic        vsync_vc11,
    output logic        vsync_vc12,
    output logic        vsync_vc13,
    output logic        vsync_vc14,
    output logic        vsync_vc15,
    output logic        hsync_vc1,
    output logic        hsync_vc2,
    output logic        hsync_vc3,
    output logic        hsync_vc4,
    output logic        hsync_vc5,
    output logic        hsync_vc6,
    output logic        hsync_vc7,
    output logic        hsync_vc8,
    output logic        hsync_vc9,
    output logic        hsync_vc10,
    output logic        hsync_vc11,
    output logic        hsync_vc12,
    output logic        hsync_vc13,
    output logic        hsync_vc14,
    output logic        hsync_vc15,
    input  logic [3:0]  u_dly_inc_D,
    input  logic        axi_clk,
    input  logic        axi_reset_n,
    input  logic        axi_awvalid,
    input  logic [5:0]  axi_awaddr,
    output logic        axi_awready,
    input  logic        axi_wvalid,
    input  logic [31:0] axi_wdata,
    output logic        axi_wready,
    output logic        axi_bvalid,
    input  logic        axi_bready,
    input  logic        axi_arvalid,
    input  logic [5:0]  axi_araddr,
    output logic        axi_arready,
    output logic        axi_rvalid,
    output logic [31:0] axi_rdata,
    input  logic        axi_rready,

    // Bring-up taps.  Not in the original IP's port list; the board top wires
    // them into a spare CSR slot so the receiver can be observed over JTAG.
    output logic [3:0]  dbg_hs_active,
    output logic [3:0]  dbg_lane_synced,
    output logic [1:0]  dbg_state,
    output logic        dbg_lanes_aligned,
    output logic        dbg_fifo_wfull,
    output logic        dbg_fifo_rempty,
    output logic        dbg_vs_level,
    output logic        dbg_hs_level,
    // Free-running count of clk_byte_HS edges.  Two APB reads a second apart
    // that differ prove the PHY's recovered byte clock is actually running.  A
    // count that never moves means every byte-domain flop below is frozen,
    // which is otherwise indistinguishable from "clock running, no traffic".
    output logic [15:0] dbg_bclk_tick,
    // Per-lane skew from the most recent burst: 4 bits per lane, in
    // clk_byte_HS units, counted from the first lane to report its sync byte to
    // that lane's own sync byte.  All zero means the lanes are aligned.
    output logic [31:0] dbg_hdr_last,
    output logic [31:0] dbg_hdr_cnt,
    // {payloads completed, gate closed while a payload was still unfinished}
    output logic [31:0] dbg_stuck_cnt,
    // how often the payload watchdog had to force a re-hunt
    output logic [15:0] dbg_wdog_cnt,
    // Stream snapshot (bring-up): the framed words from the sync word through
    // the second payload word, plus the parsed word count, frozen after capture
    output logic [31:0] dbg_cap0,
    output logic [31:0] dbg_cap1,
    output logic [31:0] dbg_cap2,
    output logic [31:0] dbg_cap3,
    output logic [31:0] dbg_cap_stat,
    // live receiver state for the hsync investigation
    output logic [31:0] dbg_obs2,
    output logic [31:0] dbg_rate_ctr
);

    // =======================================================================
    // 0. outputs this build does not drive
    // =======================================================================
    logic [3:0] hs_active;
    logic       hs_active_any;

    // Rx_HS_enable_C / LVDS_termen_C are driven with the data-lane enables in
    // section 1, so that the PHY enable is not gated by the LP decode.
    assign DLY_enable_D        = 4'h0;
    assign DLY_inc_D           = 4'h0;
    assign irq                 = 1'b0;
    assign pixel_per_clk       = 4'd4;
    assign datatype            = 6'h0;
    assign shortpkt_data_field = 16'h0;
    assign word_count          = 16'h0;
    assign vcx                 = 2'h0;
    assign vc                  = 2'h0;
    assign vsync_vc1  = 1'b0;
    assign vsync_vc2  = 1'b0;
    assign vsync_vc3  = 1'b0;
    assign vsync_vc4  = 1'b0;
    assign vsync_vc5  = 1'b0;
    assign vsync_vc6  = 1'b0;
    assign vsync_vc7  = 1'b0;
    assign vsync_vc8  = 1'b0;
    assign vsync_vc9  = 1'b0;
    assign vsync_vc10 = 1'b0;
    assign vsync_vc11 = 1'b0;
    assign vsync_vc12 = 1'b0;
    assign vsync_vc13 = 1'b0;
    assign vsync_vc14 = 1'b0;
    assign vsync_vc15 = 1'b0;
    assign hsync_vc1  = 1'b0;
    assign hsync_vc2  = 1'b0;
    assign hsync_vc3  = 1'b0;
    assign hsync_vc4  = 1'b0;
    assign hsync_vc5  = 1'b0;
    assign hsync_vc6  = 1'b0;
    assign hsync_vc7  = 1'b0;
    assign hsync_vc8  = 1'b0;
    assign hsync_vc9  = 1'b0;
    assign hsync_vc10 = 1'b0;
    assign hsync_vc11 = 1'b0;
    assign hsync_vc12 = 1'b0;
    assign hsync_vc13 = 1'b0;
    assign hsync_vc14 = 1'b0;
    assign hsync_vc15 = 1'b0;
    assign axi_awready = 1'b0;
    assign axi_wready  = 1'b0;
    assign axi_bvalid  = 1'b0;
    assign axi_arready = 1'b0;
    assign axi_rvalid  = 1'b0;
    assign axi_rdata   = 32'h0;

    // =======================================================================
    // 1. per-lane LP decode (clk_byte_HS)
    //    LP-11 idle, LP-01 HS request, LP-00 HS zero, LP-10 escape.  A window of
    //    LP_SETTLE identical samples is required, so one noisy sample cannot
    //    switch the receiver.
    // =======================================================================
    logic [3:0] lp_p_s1, lp_p_s2, lp_n_s1, lp_n_s2;
    logic [3:0] lp_p, lp_n, lp_11, lp_01, lp_00;

    always_ff @(posedge clk_byte_HS or negedge reset_byte_HS_n) begin
        if (!reset_byte_HS_n) begin
            lp_p_s1 <= 4'h0; lp_p_s2 <= 4'h0;
            lp_n_s1 <= 4'h0; lp_n_s2 <= 4'h0;
        end else begin
            lp_p_s1 <= Rx_LP_D_P; lp_p_s2 <= lp_p_s1;
            lp_n_s1 <= Rx_LP_D_N; lp_n_s2 <= lp_n_s1;
        end
    end
    assign lp_p  = lp_p_s2;
    assign lp_n  = lp_n_s2;
    assign lp_11 =  lp_p &  lp_n;
    assign lp_01 = ~lp_p &  lp_n;
    assign lp_00 = ~lp_p & ~lp_n;

    generate
        for (genvar gl = 0; gl < 4; gl++) begin : g_lp
            logic [LP_SETTLE-1:0] win_01, win_00, win_11;
            logic req_q, zero_q;
            always_ff @(posedge clk_byte_HS or negedge reset_byte_HS_n) begin
                if (!reset_byte_HS_n) begin
                    win_01 <= '0; win_00 <= '0; win_11 <= '0;
                    req_q <= 1'b0; zero_q <= 1'b0;
                end else begin
                    win_01 <= {win_01[LP_SETTLE-2:0], lp_01[gl]};
                    win_00 <= {win_00[LP_SETTLE-2:0], lp_00[gl]};
                    win_11 <= {win_11[LP_SETTLE-2:0], lp_11[gl]};
                    if (&win_01) req_q  <= 1'b1;
                    if (&win_00) zero_q <= 1'b1;
                    if (&win_11) begin req_q <= 1'b0; zero_q <= 1'b0; end
                end
            end
            assign hs_active[gl] = LP_GATED_HS ? (req_q | zero_q) : 1'b1;
        end
    endgenerate

    assign hs_active_any  = |hs_active;

    // The PHY receive enable must NOT be gated by the LP decode.  The decode is
    // clocked by clk_byte_HS, which the PHY produces, so gating the enable on it
    // deadlocks at power-up - measured on the board: hs_active stuck at 0, no
    // bytes ever captured, with the byte clock never observed running.  Keep the
    // enable unconditionally asserted so the PHY comes up and the byte clock
    // runs, and let hs_active gate only the byte capture below, where the LP
    // decode is doing its real job of discarding inter-packet bytes.
    assign Rx_HS_enable_D = 4'hf;
    assign Rx_HS_enable_C = 1'b1;

    // The board DPHY_CLOCK_MODE is Continuous: the clock lane remains terminated
    // across HS and LP11. Data-lane termination still follows their LP state.
    assign LVDS_termen_D  = hs_active;
    assign LVDS_termen_C  = 1'b1;

    // clk_byte_HS liveness.  Deliberately clocked by clk_byte_HS itself: the
    // packer forbids using a PLL output clock as *data*, but using it as a
    // clock is exactly what this domain already does.
    logic [15:0] bclk_tick;
    always_ff @(posedge clk_byte_HS or negedge reset_byte_HS_n) begin
        if (!reset_byte_HS_n) bclk_tick <= 16'd0;
        else                  bclk_tick <= bclk_tick + 16'd1;
    end
    // Prescaled rate counters: /65536 so a pair of reads five seconds apart
    // gives the byte-clock frequency and the number of words actually consumed
    // without wrapping.  Their ratio says whether the receiver is limited by the
    // clock or starved by something else.
    wire take4;
    logic [15:0] bclk_pres, bclk_slow, take4_pres, take4_slow;
    always_ff @(posedge clk_byte_HS or negedge reset_byte_HS_n) begin
        if (!reset_byte_HS_n) begin
            bclk_pres <= 16'd0; bclk_slow <= 16'd0;
            take4_pres <= 16'd0; take4_slow <= 16'd0;
        end else begin
            if (bclk_pres == 16'hffff) begin bclk_pres <= 16'd0; bclk_slow <= bclk_slow + 16'd1; end
            else bclk_pres <= bclk_pres + 16'd1;
            if (take4) begin
                if (take4_pres == 16'hffff) begin take4_pres <= 16'd0; take4_slow <= take4_slow + 16'd1; end
                else take4_pres <= take4_pres + 16'd1;
            end
        end
    end
    assign dbg_rate_ctr = {take4_slow, bclk_slow};
    assign dbg_bclk_tick = bclk_tick;

    // =======================================================================
    // 2. per-lane byte capture
    // =======================================================================
    logic [7:0] lane_byte [4];
    logic [3:0] lane_rd;
    assign lane_byte[0] = Rx_HS_D_0;
    assign lane_byte[1] = Rx_HS_D_1;
    assign lane_byte[2] = Rx_HS_D_2;
    assign lane_byte[3] = Rx_HS_D_3;
    // -----------------------------------------------------------------------
    // 2. continuous PHY FIFO drain and bounded per-lane bit-phase alignment
    // -----------------------------------------------------------------------
    typedef enum logic [1:0] {ST_SEEK, ST_HEADER, ST_PAYLOAD, ST_FOOTER} state_e;
    state_e st_q;
    logic [3:0] lane_synced_q;
    logic [2:0] footer_bytes_q;
    logic emit_raw_q;
    logic [15:0] pay_left_q;
    logic [63:0] buf_q,ins,buf_add;
    logic [2:0] cnt_q;
    logic [39:0] grp_q;
    logic grp_push,vs_level_q,hs_level_q;
    logic control_push_q,control_vs_q,control_hs_q;
    wire wfull;
    wire in_payload=st_q==ST_PAYLOAD;
    wire all_have=~|fifo_rd_empty;
    wire lanes_aligned=&lane_synced_q;
    logic [7:0] raw_prev_q[0:3];
    logic [3:0] raw_prev_valid_q;
    logic [7:0] pair_hist_valid[0:3];
    logic [2:0] phase_q[0:3];
    logic [3:0] delay_q[0:3];
    logic [3:0] delay_select[0:3];
    logic [2:0] history_addr[0:3];
    wire [7:0] byte_tap[0:3];
    logic [7:0] live_aligned[0:3];
    logic [3:0] age_q[0:3];
    logic [15:0] skew_q;
    logic [3:0] phase_match,found_next;
    logic [2:0] phase_hit[0:3];
    logic [3:0] delay_hit[0:3];
    logic [7:0] search_byte[0:3],aligned_byte[0:3];
    logic [15:0] align_pair_select[0:3];
    logic [2:0] align_phase_select[0:3];
    logic align_locked_q;
    logic [3:0] align_wait_q;
    logic [15:0] align_timeout_cnt;
    logic [4:0] age_now[0:3], min_age_now;
    logic [3:0] fresh_now, history_ok;
    logic history_break;
    logic [4:0] pay_wdog;
    logic watchdog_expire;
    wire lock_now;
    function automatic logic [7:0] align_bits(input logic [7:0] prev,
                                               input logic [7:0] curr,
                                               input logic [2:0] phase);
        logic [15:0] joined;
        logic [15:0] shifted;
        begin
            joined = {curr,prev};
            shifted = joined >> phase;
            if (phase==0) align_bits=curr;
            else align_bits=shifted[7:0];
        end
    endfunction
    wire [7:0] b0=aligned_byte[0],b1=aligned_byte[1],b2=aligned_byte[2],b3=aligned_byte[3];
    wire [23:0] framed_hdr;
    wire framed_ecc_ok,vc0,hdr_short;
    wire cap_word_sync_w={b3,b2,b1,b0}==32'hb8b8b8b8;
    wire sync_word_present=lock_now;
    wire [3:0] payload_mask=pay_left_q>=4 ? 4'hf : (4'hf>>(4-pay_left_q[1:0]));
    assign take4=align_locked_q&&all_have&&(&history_ok)&&
                 (st_q==ST_HEADER||st_q==ST_PAYLOAD||st_q==ST_FOOTER);
    // The hard-PHY lane FIFOs are a continuous byte stream. Parser state must
    // never throttle or independently advance those four read pointers.
    assign fifo_rd_enable=reset_byte_HS_n ? 4'hf : 4'h0;
    assign lane_rd=4'h0;
    for(genvar gl=0;gl<4;gl++)begin:g_lane_history
        assign history_addr[gl]=3'(4'd8-delay_select[gl]);
        for(genvar gb=0;gb<8;gb++)begin:g_history_bit
            // Correct each lane's phase before history storage. EFX_SRL8 Q
            // selects ~A and is inverted, so complementing D preserves tap polarity.
            EFX_SRL8 u_aligned_history(.D(~live_aligned[gl][gb]),.A(history_addr[gl]),
                                       .CLK(clk_byte_HS),.CE(1'b1),.Q(byte_tap[gl][gb]),.Q7());
        end
    end
    always_comb begin
        phase_match=4'h0;
        found_next=lane_synced_q;
        min_age_now=5'h1f;

        fresh_now=4'h0;
        history_ok=4'h0;
        for(integer l=0;l<4;l++) begin
            phase_hit[l]=phase_q[l];
            search_byte[l]=lane_byte[l];
            found_next[l]=lane_synced_q[l]&&!fifo_rd_empty[l];
            age_now[l]=found_next[l] ? {1'b0,age_q[l]}+5'd1 : 5'd0;
            if(st_q==ST_SEEK&&!align_locked_q&&!lane_synced_q[l]&&
               !fifo_rd_empty[l]) begin
                for(integer p=0;p<8;p++) begin
                    if(!phase_match[l]&&((p==0)||raw_prev_valid_q[l])&&
                       align_bits(raw_prev_q[l],lane_byte[l],3'(p))==SYNC_BYTE) begin
                        phase_match[l]=1'b1;
                        phase_hit[l]=3'(p);
                    end
                end
            end
            if(phase_match[l]) begin
                found_next[l]=1'b1;
                age_now[l]=0;
            end
        end
        for(integer l=0;l<4;l++) begin
            // Under lock_now, at least one phase_match lane is fresh with age 0,
            // so min_age_now is necessarily zero. Preserve full 5-bit age for
            // freshness; age 15+1=16 must fail rather than wrap in delay_hit.
            delay_hit[l]=4'(age_now[l]);
            fresh_now[l]=found_next[l]&&(age_now[l]<=5'd8);
        end
        for(integer l=0;l<4;l++) begin
            delay_select[l]=align_locked_q?delay_q[l]:delay_hit[l];
            if(delay_select[l]==0)
                history_ok[l]=!fifo_rd_empty[l]&&
                    ((phase_match[l]?phase_hit[l]:phase_q[l])==0||raw_prev_valid_q[l]);
            else
                history_ok[l]=pair_hist_valid[l][delay_select[l][2:0]-3'd1];
        end
    end
    assign lock_now=st_q==ST_SEEK&&!align_locked_q&&(&found_next)&&
                    (&fresh_now)&&(&history_ok)&&(|phase_match);
    assign history_break=align_locked_q&&
                    (st_q==ST_HEADER||st_q==ST_PAYLOAD||st_q==ST_FOOTER)&&!all_have;
    assign watchdog_expire=pay_wdog==5'd15;
    always_comb begin
        for(integer l=0;l<4;l++) begin
            align_phase_select[l] = phase_match[l] ? phase_hit[l] : phase_q[l];
            live_aligned[l] = align_bits(raw_prev_q[l],lane_byte[l],align_phase_select[l]);
            aligned_byte[l] = search_byte[l];
            if(align_locked_q || lock_now)
                aligned_byte[l] = delay_select[l]==0 ? live_aligned[l] : byte_tap[l];
        end
    end
    always_ff @(posedge clk_byte_HS or negedge reset_byte_HS_n) begin
        if(!reset_byte_HS_n) begin
            align_locked_q<=0;lane_synced_q<=0;raw_prev_valid_q<=0;align_wait_q<=0;
            align_timeout_cnt<=0;skew_q<=0;
            for(integer l=0;l<4;l++)begin
                raw_prev_q[l]<=0;phase_q[l]<=0;delay_q[l]<=0;age_q[l]<=0;
                pair_hist_valid[l]<=0;
            end
        end else begin
            for(integer l=0;l<4;l++)begin
                pair_hist_valid[l]<={pair_hist_valid[l][6:0],raw_prev_valid_q[l]&&!fifo_rd_empty[l]};
                if(!fifo_rd_empty[l])begin raw_prev_q[l]<=lane_byte[l];raw_prev_valid_q[l]<=1'b1;end
                else raw_prev_valid_q[l]<=1'b0;
            end
            if(st_q==ST_SEEK&&!align_locked_q) begin
                lane_synced_q<=found_next;
                for(integer l=0;l<4;l++)begin
                    if(phase_match[l])begin phase_q[l]<=phase_hit[l];age_q[l]<=0;end
                    else if(fifo_rd_empty[l])begin lane_synced_q[l]<=1'b0;age_q[l]<=0;end
                    else if(lane_synced_q[l]&&age_q[l]!=15)age_q[l]<=age_q[l]+1'b1;
                end
                if(lock_now)begin
                    align_locked_q<=1'b1;align_wait_q<=0;
                    for(integer l=0;l<4;l++)begin
                        delay_q[l]<=delay_hit[l];
                        skew_q[l*4+:4]<=delay_hit[l];
                    end
                end else if(|found_next)begin
                    if(align_wait_q>=8)begin
                        lane_synced_q<=0;align_locked_q<=0;align_wait_q<=0;
                        raw_prev_valid_q<=0;
                        for(integer l=0;l<4;l++)begin age_q[l]<=0;phase_q[l]<=0;end
                        for(integer l=0;l<4;l++)pair_hist_valid[l]<=0;
                        if(align_timeout_cnt!=16'hffff)align_timeout_cnt<=align_timeout_cnt+1'b1;
                    end else align_wait_q<=align_wait_q+1'b1;
                end else align_wait_q<=0;
            end
            if((st_q==ST_HEADER&&take4&&(!framed_ecc_ok||hdr_short))||
               (st_q==ST_FOOTER&&take4&&footer_bytes_q<=4)||
               (st_q==ST_PAYLOAD&&take4&&pay_left_q<=4&&
                ((pay_left_q[1:0]==1)||(pay_left_q[1:0]==2)))) begin
                align_locked_q<=0;lane_synced_q<=0;align_wait_q<=0;
            end
            if(history_break||watchdog_expire)begin
                align_locked_q<=0;lane_synced_q<=0;align_wait_q<=0;
                raw_prev_valid_q<=0;
                for(integer l=0;l<4;l++)begin age_q[l]<=0;phase_q[l]<=0;end
                for(integer l=0;l<4;l++)pair_hist_valid[l]<=0;
            end
        end
    end
`ifdef SIM_ASSERT
    always @(posedge clk_byte_HS) if (reset_byte_HS_n) begin
        if(lock_now) begin
            for(integer a=0;a<4;a++)
                if(!fresh_now[a]||!history_ok[a]||delay_hit[a]>8)
                    $fatal(1,"ALIGN_WINDOW_INVALID lane=%0d age=%0d delay=%0d",a,age_now[a],delay_hit[a]);
        end
        if(align_locked_q) begin
            for(integer a=0;a<4;a++)
                if(delay_q[a]>8) $fatal(1,"ALIGN_LOCK_DELAY_OUT_OF_RANGE lane=%0d delay=%0d",a,delay_q[a]);
        end
        if(history_break)
            $display("PHY_GAP_RESEEK t=%0t state=%0d empty=%x",$time,st_q,fifo_rd_empty);
    end
`endif
    // LP is not a parser boundary. Draining/search continues without an LP gap.
    function automatic logic [7:0] csi_ecc(input logic [23:0] hdr);
        logic [23:0] h;
        logic [7:0]  e;
        begin
            h = hdr;
            e[0] = h[0]^h[1]^h[2]^h[4]^h[5]^h[7]^h[10]^h[11]^h[13]^h[16]^h[20]^h[21]^h[22]^h[23];
            e[1] = h[0]^h[1]^h[3]^h[4]^h[6]^h[8]^h[10]^h[12]^h[14]^h[17]^h[20]^h[21]^h[22]^h[23];
            e[2] = h[0]^h[2]^h[3]^h[5]^h[6]^h[9]^h[11]^h[12]^h[15]^h[18]^h[20]^h[21]^h[22];
            e[3] = h[1]^h[2]^h[3]^h[7]^h[8]^h[9]^h[13]^h[14]^h[15]^h[19]^h[20]^h[21]^h[23];
            e[4] = h[4]^h[5]^h[6]^h[7]^h[8]^h[9]^h[16]^h[17]^h[18]^h[19]^h[20]^h[22]^h[23];
            e[5] = h[10]^h[11]^h[12]^h[13]^h[14]^h[15]^h[16]^h[17]^h[18]^h[19]^h[21]^h[22]^h[23];
            e[6] = 1'b0; // VC0: ECC has six parity bits, not seven.
            e[7] = 1'b0;
            csi_ecc = e;
        end
    endfunction

    assign framed_hdr={b2,b1,b0};
    assign framed_ecc_ok=csi_ecc(framed_hdr)==b3;
    assign vc0=b0[7:6]==0&&b3[7:6]==0;
    wire [15:0] hdr_wc={b2,b1};
    assign hdr_short=b0[5:0]<6'h10;
    wire raw_header=take4&&st_q==ST_HEADER&&framed_ecc_ok&&vc0&&
                    b0[5:0]==DT_RAW10&&hdr_wc!=0&&hdr_wc[1:0]==0&&
                    (hdr_wc[15:2]%14'd5)==0;

    // Actual events, not FIFO availability masquerading as lane alignment.
    logic [15:0] cap_sync_cnt,raw10_hdr_cnt,hdr_fwd_cnt,hdr_rev_cnt;
    logic [15:0] pay_exit_cnt,stuck_cnt,last_wc_q,wdog_cnt;
    assign dbg_hdr_last={16'h0,skew_q};
    assign dbg_hdr_cnt={hdr_fwd_cnt,hdr_rev_cnt};
    assign dbg_stuck_cnt={pay_exit_cnt,stuck_cnt};
    assign dbg_wdog_cnt=wdog_cnt;
    logic [31:0] cap0_q,cap1_q,cap2_q,cap3_q;
    logic [2:0] capn_q;
    logic cap_frozen_q;
    wire [31:0] cap_word={b3,b2,b1,b0};
    // Snapshot only a validated RAW10 packet; cap0 is its reconstructed SoT,
    // cap1 its header, cap2/3 its first two payload words. Never unrelated junk.
    always_ff @(posedge clk_byte_HS or negedge reset_byte_HS_n)begin
        if(!reset_byte_HS_n)begin
            cap0_q<=0;cap1_q<=0;cap2_q<=0;cap3_q<=0;capn_q<=0;cap_frozen_q<=0;
        end else if(!cap_frozen_q)begin
            if(raw_header&&capn_q==0)begin
                cap0_q<=32'hb8b8b8b8;cap1_q<=cap_word;capn_q<=2;
            end else if(take4&&in_payload&&capn_q==2)begin cap2_q<=cap_word;capn_q<=3;end
            else if(take4&&in_payload&&capn_q==3)begin cap3_q<=cap_word;cap_frozen_q<=1;end
        end
    end
    assign dbg_cap0=cap0_q;assign dbg_cap1=cap1_q;
    assign dbg_cap2=cap2_q;assign dbg_cap3=cap3_q;
    assign dbg_cap_stat={raw10_hdr_cnt,cap_sync_cnt};
    assign dbg_obs2={28'h0,hs_level_q,vs_level_q,in_payload,cap_frozen_q};
    always_comb begin
        ins=0;
        case(cnt_q)
            0:ins[31:0]=cap_word;
            1:ins[39:8]=cap_word;
            2:ins[47:16]=cap_word;
            3:ins[55:24]=cap_word;
            default:ins[63:32]=cap_word;
        endcase
    end
    assign buf_add=buf_q|ins;
    wire pop5=cnt_q!=0;

    // RAW10: B0..B3 hold bits [9:2] of p0..p3, B4 holds the four [1:0] pairs
    logic [9:0]  px0, px1, px2, px3;
    logic [39:0] word_raw;
    assign px0 = {grp_q[7:0],   grp_q[33:32]};
    assign px1 = {grp_q[15:8],  grp_q[35:34]};
    assign px2 = {grp_q[23:16], grp_q[37:36]};
    assign px3 = {grp_q[31:24], grp_q[39:38]};
    assign word_raw = {px3, px2, px1, px0};

    logic        push_word;
    logic [39:0] push_word_raw;

    always_ff @(posedge clk_byte_HS or negedge reset_byte_HS_n)begin
        if(!reset_byte_HS_n)begin
            st_q<=ST_SEEK;footer_bytes_q<=0;emit_raw_q<=0;
            pay_left_q<=0;buf_q<=0;cnt_q<=0;grp_q<=0;grp_push<=0;
            vs_level_q<=0;hs_level_q<=0;control_push_q<=0;control_vs_q<=0;control_hs_q<=0;
            cap_sync_cnt<=0;raw10_hdr_cnt<=0;hdr_fwd_cnt<=0;hdr_rev_cnt<=0;
            pay_exit_cnt<=0;stuck_cnt<=0;last_wc_q<=0;pay_wdog<=0;wdog_cnt<=0;
        end else begin
            grp_push<=0;control_push_q<=0;
            // Count both pixel and control tokens discarded by a full output FIFO.
            if((push_word||control_push_q)&&wfull&&stuck_cnt!=16'hffff)
                stuck_cnt<=stuck_cnt+1'b1;
            case(st_q)
                ST_SEEK:if(lock_now)begin
                    st_q<=ST_HEADER;
                    if(cap_sync_cnt!=16'hffff)cap_sync_cnt<=cap_sync_cnt+1'b1;
                end
                ST_HEADER:if(take4)begin
                    // A redundant SoT can occur here; it is never tested in payload.
                    if(cap_word_sync_w)begin end
                    else begin
                        buf_q<=0;cnt_q<=0;
                        if(framed_ecc_ok)begin
                            if(vc0&&hdr_fwd_cnt!=16'hffff)hdr_fwd_cnt<=hdr_fwd_cnt+1'b1;
                            if(hdr_short)begin
                                control_push_q<=vc0;control_hs_q<=0;
                                control_vs_q<=b0[5:0]==DT_FS ? 1'b1 : b0[5:0]==DT_FE ? 1'b0 : vs_level_q;
                                if(vc0&&b0[5:0]==DT_FS)vs_level_q<=1;
                                if(vc0&&b0[5:0]==DT_FE)vs_level_q<=0;
                                hs_level_q<=0;st_q<=ST_SEEK;
                            end else begin
                                // Unsupported long packets still own their WC bytes.
                                // The continuous PHY drain means byte slots beyond WC
                                // cannot be parked in a per-lane FIFO; count the CRC
                                // bytes after the final payload beat instead.
                                emit_raw_q<=raw_header;
                                hs_level_q<=raw_header;
                                pay_left_q<=hdr_wc;last_wc_q<=hdr_wc;
                                footer_bytes_q<=3'd2;
                                st_q<=hdr_wc==0 ? ST_FOOTER : ST_PAYLOAD;
                                if(raw_header&&raw10_hdr_cnt!=16'hffff)
                                    raw10_hdr_cnt<=raw10_hdr_cnt+1'b1;
                            end
                        end else begin
                            st_q<=ST_SEEK;
                            if(hdr_rev_cnt!=16'hffff)hdr_rev_cnt<=hdr_rev_cnt+1'b1;
                        end
                    end
                end
                ST_PAYLOAD:if(take4)begin
                    if(emit_raw_q&&pop5)begin
                        grp_q<=buf_add[39:0];grp_push<=1;
                        buf_q<={24'd0,buf_add[63:40]};cnt_q<=cnt_q-1'b1;
                    end else if(emit_raw_q)begin buf_q<=buf_add;cnt_q<=cnt_q+4;end
                    pay_left_q<=pay_left_q>=4 ? pay_left_q-4 : 0;
                    if(pay_left_q<=4)begin
                        if(pay_left_q[1:0]==0)footer_bytes_q<=2;
                        else if(pay_left_q[1:0]==3)footer_bytes_q<=1;
                        else footer_bytes_q<=0;
                        if(pay_left_q[1:0]==1||pay_left_q[1:0]==2)begin
                            st_q<=ST_SEEK;hs_level_q<=0;
                            control_push_q<=emit_raw_q;control_vs_q<=vs_level_q;control_hs_q<=0;
                        end else st_q<=ST_FOOTER;
                        if(pay_exit_cnt!=16'hffff)pay_exit_cnt<=pay_exit_cnt+1'b1;
                    end
                end
                ST_FOOTER:if(take4)begin
                    if(footer_bytes_q<=4)begin
                        footer_bytes_q<=0;st_q<=ST_SEEK;hs_level_q<=0;
                        control_push_q<=emit_raw_q;control_vs_q<=vs_level_q;control_hs_q<=0;
                    end
                end
            endcase
            // A malformed/truncated packet or partial SoT cannot lock a lane forever.
            if(st_q==ST_SEEK||take4)pay_wdog<=0;
            else if(pay_wdog!=5'd15)pay_wdog<=pay_wdog+1'b1;
            if(watchdog_expire||history_break)begin
                st_q<=ST_SEEK;hs_level_q<=0;cnt_q<=0;buf_q<=0;
                pay_left_q<=0;footer_bytes_q<=0;emit_raw_q<=0;grp_push<=0;
                control_push_q<=1;control_vs_q<=vs_level_q;control_hs_q<=0;
                if(wdog_cnt!=16'hffff)wdog_cnt<=wdog_cnt+1'b1;
                pay_wdog<=0;
            end
        end
    end
    assign push_word=grp_push;
    assign push_word_raw=word_raw;

    // =======================================================================
    // 5. output crossing into clk_pixel (gray-coded async FIFO)
    // =======================================================================
    localparam int OUT_DEPTH = 1 << OUT_AW;

    logic [OUT_AW:0] wbin_q, rbin_q, wgray_q, rgray_q;
    logic [OUT_AW:0] rgray_s1, rgray_s2, wgray_s1, wgray_s2;
    logic [42:0]     omem [OUT_DEPTH];
    logic            rempty;

    always_ff @(posedge clk_byte_HS or negedge reset_byte_HS_n) begin
        if (!reset_byte_HS_n) begin
            wbin_q  <= '0;
            wgray_q <= '0;
        end else if ((push_word || control_push_q) && !wfull) begin
            omem[wbin_q[OUT_AW-1:0]] <= push_word ? {1'b1,vs_level_q,1'b1,push_word_raw} :
                                                                {1'b0,control_vs_q,control_hs_q,40'd0};
            wbin_q  <= wbin_q + 1'b1;
            wgray_q <= (wbin_q + 1'b1) ^ ((wbin_q + 1'b1) >> 1);
        end
    end

    always_ff @(posedge clk_pixel or negedge reset_pixel_n) begin
        if (!reset_pixel_n) begin
            rbin_q <= '0; rgray_q <= '0;
            rgray_s1 <= '0; rgray_s2 <= '0;
        end else begin
            rgray_s1 <= wgray_q; rgray_s2 <= rgray_s1;
            if (!rempty) begin
                rbin_q  <= rbin_q + 1'b1;
                rgray_q <= (rbin_q + 1'b1) ^ ((rbin_q + 1'b1) >> 1);
            end
        end
    end

    always_ff @(posedge clk_byte_HS or negedge reset_byte_HS_n) begin
        if (!reset_byte_HS_n) begin wgray_s1 <= '0; wgray_s2 <= '0; end
        else begin wgray_s1 <= rgray_q; wgray_s2 <= wgray_s1; end
    end

    assign wfull  = (wgray_q == {~wgray_s2[OUT_AW:OUT_AW-1], wgray_s2[OUT_AW-2:0]});
    assign rempty = (rgray_q == rgray_s2);

    logic [42:0] rd_word;
    assign rd_word = omem[rbin_q[OUT_AW-1:0]];

    // Ordered control tokens share the pixel FIFO. VS/HS hold their last
    // consumed level during gaps, so occupancy never masquerades as a sync edge.
    always_ff @(posedge clk_pixel or negedge reset_pixel_n)begin
        if(!reset_pixel_n)begin pixel_data_valid<=0;pixel_data<=0;vsync_vc0<=0;hsync_vc0<=0;end
        else begin
            pixel_data_valid<=!rempty&&rd_word[42];
            if(!rempty)begin
                pixel_data<={24'd0,rd_word[39:0]};
                vsync_vc0<=rd_word[41];hsync_vc0<=rd_word[40];
            end
        end
    end
`ifdef SIM_ASSERT
    always @(posedge clk_byte_HS)if(reset_byte_HS_n)begin
        if((push_word||control_push_q)&&wfull)$fatal(1,"CSI output FIFO overflow");
        if(push_word&&control_push_q)$fatal(1,"CSI simultaneous control/pixel token");
        if(raw_header&&hdr_wc%20!=0)$fatal(1,"RAW10 lane grouping requires WC multiple of 20");
    end
`endif

    // =======================================================================
    // 7. bring-up taps
    // =======================================================================
    assign dbg_hs_active     = hs_active;
    assign dbg_lane_synced   = lane_synced_q;
    assign dbg_state         = st_q;
    assign dbg_lanes_aligned = lanes_aligned;
    assign dbg_fifo_wfull    = wfull;
    assign dbg_fifo_rempty   = rempty;
    assign dbg_vs_level      = vs_level_q;
    assign dbg_hs_level      = hs_level_q;

endmodule
