// 手势关键点 NPU 的执行引擎：逐层执行，每个中间张量都落在 DDR。
//
// 为什么不做算子融合：融合省带宽，但要滚动行窗口和逐算子记账。实测一次推理
// 的 DDR 流量约 6 MB（即使把每个中间张量都物化也只有这个量级），在 1.6 GB/s
// 下不到 4 ms，而计算是 30 ms 量级。这里用带宽换掉了那部分复杂度。
//
// 每层循环嵌套：
//   for y in 输出行:
//     for ky in 0..k-1: 取第 (y*stride + ky - pad_t) 行 -> 行缓冲槽 ky
//     for cb in 0..out_c_pad/32-1:
//       载入权重块 [cb][step][32] 与参数块
//       for x in 0..out_w-1:
//         for (ci,)ky,kx: 32 lane 各做一次 MAC  —— 1 拍/步
//         重量化 32 个累加值 -> 写输出行缓冲
//     排出输出行
//
// 激活张量按通道补齐到 32 的倍数存放（描述表里的 in_c_pad/out_c_pad）：
// 深度卷积一组 lane 要读 32 个连续通道字节，补齐后这个窗口天然 32 字节对齐，
// 一次字读取满，引擎里不需要任何重排步骤。
import gesture_desc_pkg::*;

module gesture_engine #(
    parameter int WGT_WORDS  = 1024,    // 两个 512x256 银行；最大 672 步
    parameter int ROW_WORDS  = 1024,    // 最大运行时窗口偏移 840 个 32B 字
    parameter int BROW_WORDS = 256,     // ADD 第二操作数行 8 KiB
    parameter int OUT_BYTES  = 8192
) (
    output logic [31:0] debug_state, debug_position, debug_load, debug_store,
    input  logic         clk,
    input  logic         reset,
    input  logic         start,
    input  logic [7:0]   layer_id,
    output logic         busy,
    output logic         done,
    output logic         error,
    output logic         rd_valid,
    input  logic         rd_ready,
    output logic [31:0]  rd_address,
    output logic [15:0]  rd_length,
    input  logic         rd_data_valid,
    output logic         rd_data_ready,
    input  logic [127:0] rd_data,
    input  logic [15:0]  rd_keep,
    input  logic         rd_last,
    input  logic         rd_done,
    input  logic         rd_error,
    output logic         wr_valid,
    input  logic         wr_ready,
    output logic [31:0]  wr_address,
    output logic [15:0]  wr_length,
    output logic         wr_data_valid,
    input  logic         wr_data_ready,
    output logic [127:0] wr_data,
    output logic [15:0]  wr_keep,
    output logic         wr_last,
    input  logic         wr_done,
    input  logic         wr_error
);
    localparam int LANE_N   = 32;
    localparam int RQ_LANES = 4;
    localparam int RQ_WORDS = LANE_N / RQ_LANES;

    gesture_ldesc_t L;

    wire is_dw   = (L.kind == 3'd1);
    wire is_add  = (L.kind == 3'd2);
    wire is_pool = (L.kind == 3'd3);
    wire is_gap  = (L.kind == 3'd4);

    // ---------------------------------------------------------------- 缓冲
    logic         row_we;
    logic [10:0]  row_waddr, row_raddr;
    logic [255:0] row_wdata, row_rdata;
    gesture_word_ram #(.WORDS(ROW_WORDS)) u_row (
        .clk(clk), .write_enable(row_we), .write_address(row_waddr[9:0]),
        .write_data(row_wdata), .read_enable(1'b1), .read_address(row_raddr[9:0]),
        .read_data(row_rdata));

    logic         brow_we;
    logic [7:0]   brow_waddr, brow_raddr;
    logic [255:0] brow_wdata, brow_rdata;
    gesture_word_ram #(.WORDS(BROW_WORDS)) u_brow (
        .clk(clk), .write_enable(brow_we), .write_address(brow_waddr[7:0]),
        .write_data(brow_wdata), .read_enable(1'b1), .read_address(brow_raddr[7:0]),
        .read_data(brow_rdata));

    logic         wgt_we;
    logic [9:0]   wgt_waddr, wgt_raddr;
    logic [255:0] wgt_wdata, wgt_rdata;
    gesture_word_ram #(.WORDS(WGT_WORDS)) u_wgt (
        .clk(clk), .write_enable(wgt_we), .write_address(wgt_waddr[9:0]),
        .write_data(wgt_wdata), .read_enable(1'b1), .read_address(wgt_raddr[9:0]),
        .read_data(wgt_rdata));

    logic         par_we;
    logic [2:0]   par_waddr, par_raddr;
    logic [255:0] par_wdata, par_rdata;
    gesture_param_srl u_par (
        .clk(clk), .write_enable(par_we), .write_address(par_waddr),
        .write_data(par_wdata), .read_enable(1'b1), .read_address(par_raddr),
        .read_data(par_rdata));

    logic         par2_we;
    logic [2:0]   par2_waddr, par2_raddr;
    logic [255:0] par2_wdata, par2_rdata;
    gesture_param_srl u_par2 (
        .clk(clk), .write_enable(par2_we), .write_address(par2_waddr),
        .write_data(par2_wdata), .read_enable(1'b1), .read_address(par2_raddr),
        .read_data(par2_rdata));

    // 输出行：4 字节/拍写入（重量化一拍 4 个码），16 字节/拍读出（排出）
    logic         store_re;              // 由 gesture_line_store 驱动
    logic [11:0]  store_raddr;
    logic [127:0] store_rdata;
    logic        out_we;
    logic [11:0] out_waddr;              // 4 字节字地址
    logic [31:0] out_wdata;
    gesture_out_ram #(.BYTES(OUT_BYTES)) u_out (
        .clk(clk), .write_enable(out_we), .write_address(out_waddr[11:0]),
        .write_data(out_wdata), .read_enable(store_re), .read_address(store_raddr[11:0]),
        .read_data(store_rdata));

    // ------------------------------------------------------------ MAC / RQ
    logic                  acc_clear, acc_enable, mac_acc_en_q;
    logic [LANE_N*8-1:0]   act_flat, wgt_flat;
    logic [LANE_N*32-1:0]  acc_flat;
    logic                  rq_valid;
    logic [RQ_LANES*32-1:0] rq_acc;
    logic [RQ_LANES*17-1:0] rq_m18;
    logic [RQ_LANES*6-1:0]  rq_post;
    logic [RQ_LANES*32-1:0] rq_bfix;
    logic [RQ_LANES*8-1:0]  rq_zp;
    logic                   rq_out_valid;
    logic [RQ_LANES*8-1:0]  rq_out_code;
    logic signed [RQ_LANES*22-1:0] rq_out_fixed;
    logic                   rq2_valid, rq2_out_valid;
    logic [RQ_LANES*32-1:0] rq2_acc, rq2_bfix;
    logic [RQ_LANES*17-1:0] rq2_m18;
    logic [RQ_LANES*6-1:0]  rq2_post;
    logic [RQ_LANES*8-1:0]  rq2_zp, rq2_out_code;
    logic signed [RQ_LANES*22-1:0] rq2_out_fixed;

    gesture_mac_array #(.DSP_N(16)) u_mac (
        .clk(clk), .reset(reset), .acc_clear(acc_clear), .acc_enable(acc_enable),
        .act_flat(act_flat), .wgt_flat(wgt_flat), .acc_flat(acc_flat));

    gesture_rq_array #(.LANE_N(RQ_LANES), .USE_DSP(1'b1)) u_rq (
        .clk(clk), .reset(reset), .in_valid(rq_valid),
        .in_acc_flat(rq_acc), .in_m18_flat(rq_m18), .in_post_flat(rq_post),
        .in_bfix_flat(rq_bfix), .in_zp_flat(rq_zp),
        .out_valid(rq_out_valid), .out_code_flat(rq_out_code),
        .out_fixed_flat(rq_out_fixed));

    gesture_rq_array #(.LANE_N(RQ_LANES), .USE_DSP(1'b1), .ACC_WIDTH(8)) u_rq2 (
        .clk(clk), .reset(reset), .in_valid(rq2_valid),
        .in_acc_flat(rq2_acc), .in_m18_flat(rq2_m18), .in_post_flat(rq2_post),
        .in_bfix_flat(rq2_bfix), .in_zp_flat(rq2_zp),
        .out_valid(rq2_out_valid), .out_code_flat(rq2_out_code),
        .out_fixed_flat(rq2_out_fixed));

    // ---------------------------------------------------------- 载入引擎
    logic         load_start, load_busy, load_done, load_err;
    logic [31:0]  load_addr;
    logic [15:0]  load_len;
    logic         load_we;
    logic [9:0]   load_waddr;
    logic [255:0] load_wdata;
    logic [10:0]  load_wbase;
    logic [9:0]   load_waddr10;
    logic [2:0]   load_dst;              // 0=权重 1=参数A 2=行A 3=行B 4=参数B

    gesture_line_load u_load (
        .debug_state(debug_load),
        .clk(clk), .reset(reset),
        .start(load_start), .byte_address(load_addr), .byte_length(load_len),
        .busy(load_busy), .done(load_done), .error(load_err),
        .rd_valid(rd_valid), .rd_ready(rd_ready), .rd_address(rd_address),
        .rd_length(rd_length),
        .rd_data_valid(rd_data_valid), .rd_data_ready(rd_data_ready),
        .rd_data(rd_data), .rd_keep(rd_keep), .rd_last(rd_last),
        .rd_done(rd_done), .rd_error(rd_error),
        .buf_write_enable(load_we), .buf_write_address(load_waddr),
        .buf_write_data(load_wdata));

    assign wgt_we     = load_we && (load_dst == 2'd0);
    assign par_we     = load_we && (load_dst == 2'd1);
    assign row_we     = load_we && (load_dst == 2'd2);
    assign brow_we    = load_we && (load_dst == 2'd3);
    assign par2_we    = load_we && (load_dst == 3'd4);
    assign wgt_waddr  = load_waddr[9:0];
    assign par_waddr  = load_waddr[2:0];
    assign row_waddr  = load_wbase[10:0] + {1'b0, load_waddr};
    assign brow_waddr = load_wbase[7:0] + load_waddr[7:0];
    assign wgt_wdata  = load_wdata;
    assign par_wdata  = load_wdata;
    assign par2_waddr = load_waddr[2:0];
    assign par2_wdata = load_wdata;
    assign row_wdata  = load_wdata;
    assign brow_wdata = load_wdata;

`ifdef SIM_ASSERT
    always_ff @(posedge clk) begin
        if (!reset && (row_waddr[10] || row_raddr[10]))
            $fatal(1, "row buffer address exceeds 1024-word physical banking");
        if (!reset && par_we && (load_waddr >= 10'd8))
            $fatal(1, "parameter DMA exceeds eight SRL words: %0d", load_waddr);
        if (!reset && par2_we && (load_waddr >= 10'd8))
            $fatal(1, "parameter-B DMA exceeds eight SRL words: %0d", load_waddr);
    end
`endif

    // ---------------------------------------------------------- 排出引擎
    logic         store_start, store_busy, store_done, store_err;
    logic [31:0]  store_addr;
    logic [15:0]  store_len;

    gesture_line_store #(.WORDS(OUT_BYTES/16)) u_store (
        .debug_state(debug_store),
        .clk(clk), .reset(reset),
        .start(store_start), .byte_address(store_addr), .byte_length(store_len),
        .busy(store_busy), .done(store_done), .error(store_err),
        .buf_read_enable(store_re), .buf_read_address(store_raddr),
        .buf_read_data(store_rdata),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_address(wr_address),
        .wr_length(wr_length),
        .wr_data_valid(wr_data_valid), .wr_data_ready(wr_data_ready),
        .wr_data(wr_data), .wr_keep(wr_keep), .wr_last(wr_last),
        .wr_done(wr_done), .wr_error(wr_error));

    // ----------------------------------------------------------- 计数器
    logic [9:0]  y_q, ky_q, cb_q, x_q, ci_q, kx_q, st_q;
    logic [4:0]  rq_q;
    logic [3:0]  pk_q;              // 重量化输出拼字第几组（0..7）
    logic [3:0]  wr16_q;
    logic        mac_go_q;              // 数据流进入 MAC 的补拍
    logic [255:0] code_pack_q;          // 重量化输出拼字：32 个码
    logic [1023:0] rq_hold_acc_q;       // 暂存一组32路结果，供RQ并行消费
    logic          rq_bg_busy_q;
    logic [3:0]    rq_bg_issue_q, rq_bg_collect_q;
    logic [11:0]   rq_bg_base_word_q;
    logic [31:0]  add_code_word;
    logic [255:0] pool_max_q;           // maxpool 的无符号码值最大值，32 通道并行
    logic [127:0] pool_acc_q;

    typedef enum logic [4:0] {
        IDLE, SETUP,
        ROW_BEGIN, ROW_FETCH, ROW_BASE_LOW, ROW_BASE_HIGH, ROW_BASE_COMBINE, ROW_WAIT,
        ADD_ROW_FETCH, ADD_ROW_WAIT, ROW_PAD,
        CB_BEGIN, WGT_LOAD, WGT_WAIT, PAR_LOAD, PAR_WAIT, PAR2_LOAD, PAR2_WAIT,
        PX_BEGIN, MAC_ADDR, MAC_RUN, MAC_TAIL, CAPTURE, FLUSH_ADDR, FLUSH_REQ, FLUSH_WAIT, FLUSH_STORE,
        ROW_DRAIN, ROW_DRAIN_WAIT,
        LAYER_END, FAULT
    } state_t;
    state_t state_q;
    assign debug_state={4'd0,rq_bg_busy_q,store_err,load_err,y_q,cb_q,state_q};
    assign debug_position={2'd0,x_q,st_q,ci_q};

    // Keep the addressed parameter word combinationally aligned with rq_q.
    // The RAM samples this address on the FLUSH_ADDR edge; FLUSH_REQ then uses
    // the registered data on the following edge.
    assign par_raddr  = (rq_bg_busy_q && rq_bg_issue_q < 4'd7)
                      ? rq_bg_issue_q[2:0] + 3'd1 : rq_bg_busy_q
                      ? rq_bg_issue_q[2:0] : rq_q[2:0];
    assign par2_raddr = rq_q[2:0];

    // 解包字段
    logic [9:0] t_in_c, t_in_c_pad, t_out_c, t_out_c_pad, t_in_w, t_in_h, t_out_w, t_out_h;
    logic [9:0] t_steps, t_nblk, t_row_words, t_out_row_words;
    logic [2:0] t_k, t_stride, t_pad_t, t_pad_l;
    logic [31:0] t_w_off, t_p_off, t_p2_off, t_t_in, t_t_skip, t_t_out;
    logic [7:0]  t_zp_add, t_zp_in;
    logic [2:0]  t_kind;
    logic [31:0] row_bytes_q, row_cursor_q, row_y_delta_q;
    logic [10:0] row_span_q, row_addr_q, pixel_base_q;
    logic [9:0]  pixel_addr_delta_q;
    logic [31:0] weight_cursor_q, param_cursor_q, param2_cursor_q;
    logic [31:0] weight_cursor_step_q;
    logic [31:0] output_row_cursor_q, output_row_bytes_q;
    logic [31:0] add_row_cursor_q;
    logic [31:0] row_start_cursor_q;
    logic [10:0] row_base_ky_q, row_base_low_q, row_base_high_q;

    // Small bounded unsigned products are used for byte/word address math.
    // Keeping them as explicit shift/add logic prevents the mapper from
    // consuming DSP blocks that are reserved for the 16 MAC cells.
    function automatic logic [31:0] mul20x10(input logic [19:0] a,
                                              input logic [9:0] b);
        logic [31:0] acc;
        begin
            acc = '0;
            for (int bit_idx = 0; bit_idx < 10; bit_idx++)
                if (b[bit_idx]) acc = acc + ({12'd0, a} << bit_idx);
            mul20x10 = acc;
        end
    endfunction

    function automatic logic [24:0] mul20x5(input logic [19:0] a,
                                             input logic [4:0] b);
        logic [24:0] acc;
        begin
            acc = '0;
            for (int bit_idx = 0; bit_idx < 5; bit_idx++)
                if (b[bit_idx]) acc = acc + ({5'd0, a} << bit_idx);
            mul20x5 = acc;
        end
    endfunction

    // ROW_FETCH handles kernels up to 7x7. Keep row-base multiplication as
    // bounded shift/add pieces, then pipeline channel-group multiplication
    // across row setup states; all values are modulo the 11-bit row RAM size.
    function automatic logic [10:0] row_base_for_ky(input logic [2:0] ky,
                                                     input logic [9:0] width);
        logic [10:0] w;
        begin
            w = {1'b0, width};
            case (ky)
                3'd0: row_base_for_ky = 11'd0;
                3'd1: row_base_for_ky = w;
                3'd2: row_base_for_ky = w << 1;
                3'd3: row_base_for_ky = (w << 1) + w;
                3'd4: row_base_for_ky = w << 2;
                3'd5: row_base_for_ky = (w << 2) + w;
                3'd6: row_base_for_ky = (w << 2) + (w << 1);
                default: row_base_for_ky = (w << 2) + (w << 1) + w;
            endcase
        end
    endfunction

    function automatic logic [10:0] row_base_mul2(input logic [10:0] value,
                                                   input logic [1:0] factor);
        case (factor)
            2'd0: row_base_mul2 = 11'd0;
            2'd1: row_base_mul2 = value;
            2'd2: row_base_mul2 = value << 1;
            default: row_base_mul2 = (value << 1) + value;
        endcase
    endfunction

    function automatic logic [10:0] row_base_mul3(input logic [10:0] value,
                                                   input logic [2:0] factor);
        case (factor)
            3'd0: row_base_mul3 = 11'd0;
            3'd1: row_base_mul3 = value;
            3'd2: row_base_mul3 = value << 1;
            3'd3: row_base_mul3 = (value << 1) + value;
            3'd4: row_base_mul3 = value << 2;
            3'd5: row_base_mul3 = (value << 2) + value;
            3'd6: row_base_mul3 = (value << 2) + (value << 1);
            default: row_base_mul3 = (value << 2) + (value << 1) + value;
        endcase
    endfunction

    function automatic logic [10:0] row_step_delta(input logic [9:0] from_ky,
                                                    input logic [9:0] to_ky,
                                                    input logic [10:0] row_span);
        logic [2:0] diff;
        logic [10:0] magnitude;
        begin
            diff = (to_ky >= from_ky) ? 3'(to_ky - from_ky)
                                      : 3'(from_ky - to_ky);
            case (diff)
                3'd0: magnitude = 11'd0;
                3'd1: magnitude = row_span;
                3'd2: magnitude = row_span << 1;
                3'd3: magnitude = row_span + (row_span << 1);
                3'd4: magnitude = row_span << 2;
                default: magnitude = '0;
            endcase
            row_step_delta = (to_ky >= from_ky) ? magnitude : 11'(-magnitude);
        end
    endfunction

    function automatic logic [11:0] stride_product(input logic [9:0] x,
                                                     input logic [2:0] stride);
        begin
            case (stride)
                3'd0: stride_product = 12'd0;
                3'd1: stride_product = {2'd0, x};
                3'd2: stride_product = {1'd0, x, 1'b0};
                3'd3: stride_product = {2'd0, x} + {1'd0, x, 1'b0};
                default: stride_product = {2'd0, x};
            endcase
        end
    endfunction

    wire [31:0] desc_row_bytes = mul20x10({10'd0, L.in_w}, L.in_c_pad);
    wire [31:0] desc_pad_bytes = (L.pad_t == 3'd1) ? desc_row_bytes
                                : (L.pad_t == 3'd2) ? (desc_row_bytes << 1)
                                : (L.pad_t == 3'd3) ? (desc_row_bytes + (desc_row_bytes << 1))
                                : 32'd0;
    wire [24:0] desc_row_span = mul20x5({10'd0, L.in_w}, L.in_c_pad[9:5]);
    wire signed [3:0] desc_y_delta_factor = $signed({1'b0, L.stride})
                                            - $signed({1'b0, L.k}) + 4'sd1;
    logic signed [34:0] desc_y_delta_value;
    always_comb begin
        // stride and kernel dimensions are small descriptor fields. Implement
        // their {-4..+2} row-step factor with shifts/adds so DSPs remain free
        // for the much wider tap-address products below.
        case (desc_y_delta_factor)
            -4: desc_y_delta_value = -$signed({1'b0, desc_row_bytes, 2'b00});
            -3: desc_y_delta_value = -$signed(({1'b0, desc_row_bytes, 1'b0})
                                                + {1'b0, desc_row_bytes});
            -2: desc_y_delta_value = -$signed({1'b0, desc_row_bytes, 1'b0});
            -1: desc_y_delta_value = -$signed({1'b0, desc_row_bytes});
             0: desc_y_delta_value = '0;
             1: desc_y_delta_value =  $signed({1'b0, desc_row_bytes});
             2: desc_y_delta_value =  $signed({1'b0, desc_row_bytes, 1'b0});
            default: desc_y_delta_value = '0;
        endcase
    end

    // 行缓冲读出地址
    logic [10:0] row_rd_addr;
    logic [9:0]  col_idx;
    logic        row_in_range, col_in_range;
    logic [9:0]  fetch_ky, fetch_kx, fetch_ci, fetch_col;
    logic [9:0]  fetch2_ky, fetch2_kx, fetch2_ci, fetch2_col;
    logic [19:0] fetch_row_product;
    logic [10:0] fetch_row_index;
    logic [9:0]  fetch_row_scale;
    logic [29:0] fetch_scaled_row;
    logic [31:0] fetch_xpos;
    logic [11:0] x_stride_pos, y_stride_pos;
    logic [11:0] x_stride_pos_q;
    logic [9:0] next_pixel_col, pixel_col_delta;
    logic [10:0] tap_col_delta, tap_addr_delta, tap_col_delta2, tap_addr_delta2;
    logic [10:0] tap_ci_delta2;
    logic [10:0] wrap_col_mag, row_wrap_mag;
    logic [2:0] wrap_col_steps;
    logic signed [10:0] wrap_col_delta_calc, wrap_col_delta_q;
    logic signed [10:0] row_wrap_delta_calc, row_wrap_delta_q;
    logic [10:0] tap_row_delta2;
    logic [11:0] wrap_last_x;
    logic [9:0]  pixel_addr_delta;

    always_comb begin
        x_stride_pos = x_stride_pos_q;
        y_stride_pos = stride_product(y_q, t_stride);
        col_idx = (x_stride_pos + 12'(kx_q) >= 12'(t_pad_l))
                ? 10'(x_stride_pos + 12'(kx_q) - 12'(t_pad_l)) : 10'd0;
        row_in_range = ((y_stride_pos + 12'(ky_q)) >= 12'(t_pad_t))
                    && ((y_stride_pos + 12'(ky_q) - 12'(t_pad_t)) < 12'(t_in_h));
        col_in_range = (x_stride_pos + 12'(kx_q) >= 12'(t_pad_l))
                    && (x_stride_pos + 12'(kx_q) - 12'(t_pad_l) < 12'(t_in_w));

        // Prime the synchronous input/weight RAMs with the next tap while the
        // current tap is being consumed. This lets MAC_RUN issue one tap per
        // clock instead of alternating MAC_ADDR and MAC_RUN for every tap.
        fetch_ky = ky_q;
        fetch_kx = kx_q;
        fetch_ci = ci_q;
        // The RAM read after the final tap is speculative and never consumed;
        // avoid putting the wide st/t_steps terminal compare on the address path.
        if (is_dw || is_pool || is_gap) begin
            if (kx_q + 10'd1 == t_k) begin
                fetch_kx = '0;
                fetch_ky = ky_q + 10'd1;
            end else fetch_kx = kx_q + 10'd1;
        end else begin
            if (kx_q + 10'd1 == t_k) begin
                fetch_kx = '0;
                if (ky_q + 10'd1 == t_k) begin
                    fetch_ky = '0;
                    fetch_ci = ci_q + 10'd1;
                end else fetch_ky = ky_q + 10'd1;
            end else fetch_kx = kx_q + 10'd1;
        end
        fetch_xpos = 32'(x_stride_pos) + 32'(fetch_kx);
        fetch_col = (fetch_xpos >= 32'(t_pad_l)) ? 10'(fetch_xpos - 32'(t_pad_l)) : 10'd0;
        fetch_row_product = fetch_ky * t_in_w;
        fetch_row_index = fetch_row_product[10:0] + 11'(fetch_col);
        fetch_row_scale = (is_dw || is_pool || is_gap || is_add)
                        ? {5'd0, t_in_c_pad[9:5]} : t_in_c_pad;
        fetch_scaled_row = fetch_row_index * fetch_row_scale;
        fetch2_ky = fetch_ky;
        fetch2_kx = fetch_kx;
        fetch2_ci = fetch_ci;
        if (is_dw || is_pool || is_gap) begin
            if (fetch_kx + 10'd1 == t_k) begin
                fetch2_kx = '0;
                fetch2_ky = fetch_ky + 10'd1;
            end else fetch2_kx = fetch_kx + 10'd1;
        end else begin
            if (fetch_kx + 10'd1 == t_k) begin
                fetch2_kx = '0;
                if (fetch_ky + 10'd1 == t_k) begin
                    fetch2_ky = '0;
                    fetch2_ci = fetch_ci + 10'd1;
                end else fetch2_ky = fetch_ky + 10'd1;
            end else fetch2_kx = fetch_kx + 10'd1;
        end
        fetch2_col = (x_stride_pos + 12'(fetch2_kx) >= 12'(t_pad_l))
                   ? 10'(x_stride_pos + 12'(fetch2_kx) - 12'(t_pad_l)) : 10'd0;
        next_pixel_col = (x_stride_pos + 12'(t_stride) >= 12'(t_pad_l))
                       ? 10'(x_stride_pos + 12'(t_stride) - 12'(t_pad_l)) : 10'd0;
        pixel_col_delta = next_pixel_col - col_idx;
        // MAC_ADDR is entered only at the first tap of a pixel (kx/ky/ci are
        // reset there). Its first cursor step is therefore either +1 column
        // or a row/channel step; no wide multiply is needed for the column.
        tap_col_delta = ((fetch_kx > kx_q)
                         && (x_stride_pos + 12'(kx_q) >= 12'(t_pad_l)))
                      ? 11'({6'd0, t_in_c_pad[9:5]}) : 11'd0;
        tap_addr_delta = tap_col_delta
                       + row_step_delta(ky_q, fetch_ky, row_span_q)
                       + 11'((fetch_ci >> 5) - (ci_q >> 5));

        // For K<=5, adjacent taps move by 0 or 1 input columns; only the
        // kx wrap moves backwards, by at most four columns. Precompute that
        // small signed wrap once in MAC_ADDR, then use a narrow mux here.
        // This removes the serial 20x5 shift/add multiplier from the every-tap
        // row-address path without adding a MAC cycle.
        wrap_last_x = x_stride_pos + ((t_k == 0) ? 12'd0 : 12'(t_k - 10'd1));
        if (t_k <= 10'd1) wrap_col_steps = 3'd0;
        else if (x_stride_pos >= 12'(t_pad_l))
            wrap_col_steps = 3'(t_k - 10'd1);
        else if (wrap_last_x > 12'(t_pad_l))
            wrap_col_steps = 3'(wrap_last_x - 12'(t_pad_l));
        else wrap_col_steps = 3'd0;
        case (wrap_col_steps)
            3'd1: wrap_col_mag = {6'd0, t_in_c_pad[9:5]};
            3'd2: wrap_col_mag = {5'd0, t_in_c_pad[9:5], 1'b0};
            3'd3: wrap_col_mag = {6'd0, t_in_c_pad[9:5]}
                               + {5'd0, t_in_c_pad[9:5], 1'b0};
            3'd4: wrap_col_mag = {4'd0, t_in_c_pad[9:5], 2'b00};
            default: wrap_col_mag = 11'd0;
        endcase
        wrap_col_delta_calc = 11'(-$signed({1'b0, wrap_col_mag}));
        tap_col_delta2 = (fetch2_kx > fetch_kx)
                       ? ((x_stride_pos + 12'(fetch_kx) >= 12'(t_pad_l))
                          ? 11'({6'd0, t_in_c_pad[9:5]}) : 11'd0)
                       : (fetch2_kx < fetch_kx ? wrap_col_delta_q[10:0] : 11'd0);

        // The only backwards ky transition is a convolution's final-kernel
        // wrap. Its row delta is a precomputed small multiple of row_span.
        // Pool/DW/GAP's final out-of-range read is speculative and harmless.
        case (t_k)
            10'd2: row_wrap_mag = row_span_q;
            10'd3: row_wrap_mag = row_span_q << 1;
            10'd4: row_wrap_mag = row_span_q + (row_span_q << 1);
            10'd5: row_wrap_mag = row_span_q << 2;
            default: row_wrap_mag = 11'd0;
        endcase
        row_wrap_delta_calc = 11'(-$signed({1'b0, row_wrap_mag}));
        tap_row_delta2 = (fetch2_ky > fetch_ky) ? row_span_q
                       : (fetch2_ky < fetch_ky ? row_wrap_delta_q[10:0] : 11'd0);
        tap_ci_delta2 = 11'((fetch2_ci >> 5) - (fetch_ci >> 5));
        tap_addr_delta2 = tap_col_delta2 + tap_row_delta2 + tap_ci_delta2;
        pixel_addr_delta = 11'(mul20x5({10'd0, pixel_col_delta}, t_in_c_pad[9:5]));
        row_rd_addr = row_addr_q;
    end

    // RAMs are synchronous; the address must track the current tap before the
    // MAC_RUN edge. Keep the word index and byte selector derived from the same
    // (ky, x, cb) coordinates.
    assign row_raddr = row_rd_addr;
    // ADD's second operand uses the same channel-block word cursor as the
    // primary row buffer. Reusing it avoids a wide col_idx*channel multiply.
    assign brow_raddr = row_addr_q[7:0];
    assign wgt_raddr = 10'((state_q == MAC_RUN) ? st_q + 10'd1 : st_q);

    // 卷积的激活字节在字内的偏移（单独出一个中间量，表达式上不能直接做位选）
    logic [4:0]  row_byte_sel;
    assign row_byte_sel  = ci_q[4:0];

    // 激活向量
    // 越界 tap 必须送「输入 zero point 对应的有符号码」，不能送 0：
    // 偏置里折进了 (128 - zp_in) * sum(w) 这条修正，它假定越界处贡献的是
    // (zp_in - 128) * w。送 0 会让整层从第一行就开始偏。
    logic [7:0] pad_signed;
    assign pad_signed = t_zp_in - 8'd128;

    logic [255:0] act_word;
    always_comb begin
        if (is_pool || is_add)
            act_word = (row_in_range && col_in_range) ? row_rdata : {32{pad_signed}};
        else if (is_dw || is_gap)
            act_word = (row_in_range && col_in_range)
                     ? (row_rdata ^ {32{8'h80}}) : {32{pad_signed}};
        else if (row_in_range && col_in_range)
            act_word = {32{row_rdata[row_byte_sel*8 +: 8] ^ 8'h80}};
        else
            act_word = {32{pad_signed}};
    end

    assign act_flat = act_word;
    assign wgt_flat = is_gap ? {32{8'd1}} : ((is_pool || is_add) ? 256'd0 : wgt_rdata);

    function automatic logic signed [31:0] center_code(input logic [7:0] code);
        center_code = {{24{~code[7]}}, ~code[7], code[6:0]};
    endfunction

    // ADD keeps both rescaled operands in Q10 until after summation. Rounding
    // each branch to an integer first creates a one-code error on tie-near sums.
    function automatic logic [7:0] add_fixed_codes(
        input logic signed [21:0] a_q10,
        input logic signed [21:0] b_q10,
        input logic [7:0] zp);
        logic signed [22:0] total_q10, quotient, rounded, with_zp;
        logic [9:0] remainder;
        logic round_up;
        begin
            total_q10 = 23'(a_q10) + 23'(b_q10);
            quotient = total_q10 >>> 10;
            remainder = total_q10[9:0];
            round_up = (remainder > 10'd512)
                    | ((remainder == 10'd512) & quotient[0]);
            rounded = quotient + 23'(round_up);
            with_zp = rounded + 23'($signed({1'b0, zp}));
            if (with_zp < 0) add_fixed_codes = 8'd0;
            else if (with_zp > 23'sd255) add_fixed_codes = 8'd255;
            else add_fixed_codes = with_zp[7:0];
        end
    endfunction

    always_comb begin
        add_code_word = '0;
        for (int lane = 0; lane < RQ_LANES; lane++)
            add_code_word[lane*8 +: 8] = add_fixed_codes(
                rq_out_fixed[lane*22 +: 22], rq2_out_fixed[lane*22 +: 22], t_zp_add);
    end

    always_comb begin
        pool_acc_q = '0;
        for (int l = 0; l < RQ_LANES; l++)
            pool_acc_q[l*32 +: 32] = {24'd0, pool_max_q[(rq_q*RQ_LANES+l)*8 +: 8]} - 32'd128;
    end

    // ---------------------------------------------------------- 状态机
    assign acc_enable = mac_acc_en_q && !is_pool && !is_add;
    assign acc_clear = ((state_q == MAC_RUN) && (st_q == 0)
                        && (!is_gap || (x_q == 0 && y_q == 0)))
                     || ((state_q == CAPTURE) && !rq_bg_busy_q);

    // 本层需要多少输出通道块 / 每行多少字
    wire [9:0] nblk_w   = (t_out_c_pad + 10'd31) / 10'd32;
    wire [9:0] roww_w   = t_in_w * (t_in_c_pad / 10'd32);

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= IDLE;
            mac_acc_en_q <= 1'b0;
            busy <= 1'b0; done <= 1'b0; error <= 1'b0;
            rq_valid <= 1'b0; rq2_valid <= 1'b0; out_we <= 1'b0;
            load_start <= 1'b0; store_start <= 1'b0;
            rq_hold_acc_q <= '0; rq_bg_busy_q <= 1'b0;
            rq_bg_issue_q <= '0; rq_bg_collect_q <= '0;
            rq_bg_base_word_q <= '0;
            row_bytes_q <= '0; row_cursor_q <= '0; row_y_delta_q <= '0;
            weight_cursor_q <= '0; param_cursor_q <= '0; param2_cursor_q <= '0;
            weight_cursor_step_q <= '0;
            output_row_cursor_q <= '0; output_row_bytes_q <= '0;
            add_row_cursor_q <= '0;
            row_start_cursor_q <= '0;
            row_base_ky_q <= '0; row_base_low_q <= '0; row_base_high_q <= '0;
            row_span_q <= '0; row_addr_q <= '0; pixel_base_q <= '0;
            pixel_addr_delta_q <= '0;
            wrap_col_delta_q <= '0; row_wrap_delta_q <= '0;
            pool_max_q <= '0;
            y_q <= '0; ky_q <= '0; cb_q <= '0; x_q <= '0;
            x_stride_pos_q <= '0;
            ci_q <= '0; kx_q <= '0; st_q <= '0; rq_q <= '0; wr16_q <= '0;
        end else begin
            mac_acc_en_q <= (state_q == MAC_RUN);
            done <= 1'b0; error <= 1'b0; rq2_valid <= 1'b0;
            rq_valid <= 1'b0; out_we <= 1'b0;
            load_start <= 1'b0; store_start <= 1'b0;

            // Background RQ drains one four-channel group per cycle while MAC
            // computes the next tile. Parameter RAM is prefetched by par_raddr.
            if (rq_bg_busy_q && rq_bg_issue_q < 4'd8) begin
                rq_valid <= 1'b1;
                rq_acc <= rq_hold_acc_q[rq_bg_issue_q*128 +: 128];
                rq_m18 <= param_field(par_rdata, 0);
                rq_post <= param_field(par_rdata, 1);
                rq_bfix <= param_field(par_rdata, 2);
                rq_zp <= param_field(par_rdata, 3);
                rq_bg_issue_q <= rq_bg_issue_q + 4'd1;
            end
            if (rq_bg_busy_q && rq_out_valid) begin
                out_we <= 1'b1;
                out_waddr <= rq_bg_base_word_q + 12'(rq_bg_collect_q);
                out_wdata <= rq_out_code;
                if (rq_bg_collect_q == 4'd7) begin
                    rq_bg_busy_q <= 1'b0;
                    rq_bg_collect_q <= '0;
                end else rq_bg_collect_q <= rq_bg_collect_q + 4'd1;
            end

            case (state_q)
            IDLE: if (start) begin
                L <= gesture_layer(layer_id);
                busy <= 1'b1;
                state_q <= SETUP;
            end

            SETUP: begin
                t_kind <= L.kind;
                t_in_c <= L.in_c; t_in_c_pad <= L.in_c_pad;
                t_out_c <= L.out_c; t_out_c_pad <= L.out_c_pad;
                t_in_w <= L.in_w; t_in_h <= L.in_h;
                t_out_w <= L.out_w; t_out_h <= L.out_h;
                // MaxPool 没有权重表，但仍按每个窗口 tap 逐拍扫描。
                if (L.kind == 3'd3) t_steps <= 10'(mul20x10({17'd0, L.k}, {7'd0, L.k}));
                else if (L.kind == 3'd2) t_steps <= 10'd1;
                else if (L.kind == 3'd4) t_steps <= 10'd1;
                else t_steps <= L.steps;
                t_k <= L.k; t_stride <= L.stride;
                t_pad_t <= L.pad_t; t_pad_l <= L.pad_l;
                t_w_off <= L.w_off; t_p_off <= L.p_off; t_p2_off <= L.p2_off;
                weight_cursor_q <= {2'b0, DDR_WEIGHTS[29:0]} + L.w_off;
                param_cursor_q <= {2'b0, DDR_PARAMS[29:0]} + L.p_off;
                param2_cursor_q <= {2'b0, DDR_PARAMS[29:0]} + L.p2_off;
                weight_cursor_step_q <= 32'(L.steps) << 5;
                output_row_cursor_q <= L.t_out;
                output_row_bytes_q <= mul20x10({10'd0, L.out_w}, L.out_c_pad);
                add_row_cursor_q <= L.t_skip;
                t_t_in <= L.t_in; t_t_skip <= L.t_skip; t_t_out <= L.t_out;
                t_zp_add <= L.zp_add; t_zp_in <= L.zp_in;
                row_bytes_q <= desc_row_bytes;
                row_cursor_q <= L.t_in - desc_pad_bytes;
                row_start_cursor_q <= L.t_in - desc_pad_bytes;
                row_y_delta_q <= desc_y_delta_value[31:0];
                row_span_q <= 11'(desc_row_span);
                y_q <= '0; cb_q <= '0;
                state_q <= ROW_BEGIN;
            end

            // ---- 逐行取输入 ----
            ROW_BEGIN: begin
                ky_q <= '0;
                if (!is_gap) begin
                    cb_q <= '0; // GAP 按通道块处理完整空间面后再换块
                    // Normal layers restart channel blocks for every output row.
                    // Keep their DMA cursors in step with cb_q; otherwise row 1
                    // starts from the final block address of row 0.
                    weight_cursor_q <= {2'b0, DDR_WEIGHTS[29:0]} + L.w_off;
                    param_cursor_q <= {2'b0, DDR_PARAMS[29:0]} + L.p_off;
                    param2_cursor_q <= {2'b0, DDR_PARAMS[29:0]} + L.p2_off;
                end
                state_q <= ROW_FETCH;    // 否则多通道块的层会一直在第 0 块打转
            end

            ROW_FETCH: begin
                if (ky_q >= t_k || (mul20x10({10'd0, y_q}, {7'd0, t_stride}) + 32'(ky_q)) < t_pad_t
                    || (mul20x10({10'd0, y_q}, {7'd0, t_stride}) + 32'(ky_q) - t_pad_t) >= t_in_h) begin
                    state_q <= ROW_PAD;
                end else if (!load_busy && !load_done) begin
                    row_base_ky_q <= row_base_for_ky(ky_q[2:0], t_in_w);
                    state_q       <= ROW_BASE_LOW;
                end
            end

            ROW_BASE_LOW: begin
                row_base_low_q <= row_base_mul2(row_base_ky_q, t_in_c_pad[6:5]);
                state_q <= ROW_BASE_HIGH;
            end

            ROW_BASE_HIGH: begin
                row_base_high_q <= row_base_mul3(row_base_ky_q, t_in_c_pad[9:7]);
                state_q <= ROW_BASE_COMBINE;
            end

            ROW_BASE_COMBINE: begin
                if (!load_busy && !load_done) begin
                    load_addr  <= row_cursor_q;
                    load_len   <= 16'(row_bytes_q);
                    load_dst   <= 3'd2;
                    load_wbase <= row_base_low_q + {row_base_high_q[8:0], 2'b00};
                    load_start <= 1'b1;
                    state_q    <= ROW_WAIT;
`ifdef SIM_ASSERT
                    if ((row_base_low_q + {row_base_high_q[8:0], 2'b00}) !==
                        11'(mul20x10(mul20x10({10'd0, ky_q}, t_in_w),
                                      {5'd0, t_in_c_pad[9:5]})))
                        $fatal(1, "row loader base mismatch layer=%0d ky=%0d", layer_id, ky_q);
`endif
                end
            end

            ROW_WAIT: begin
                if (load_busy) state_q <= ROW_WAIT;
                else if (load_done) state_q <= is_add ? ADD_ROW_FETCH : ROW_PAD;
                if (load_err) state_q <= FAULT;
            end

            ADD_ROW_FETCH: begin
                if (!load_busy && !load_done) begin
                    load_addr  <= add_row_cursor_q;
                    load_len   <= 16'(row_bytes_q);
                    load_dst   <= 3'd3;
                    load_wbase <= '0;
                    load_start <= 1'b1;
                    state_q    <= ADD_ROW_WAIT;
                end
            end

            ADD_ROW_WAIT: begin
                if (load_err) state_q <= FAULT;
                else if (!load_busy && load_done) state_q <= ROW_PAD;
            end

            ROW_PAD: begin
                // 越界行整行写常数量（行缓冲内容对越界 tap 不参与 MAC）
                if (ky_q + 10'd1 == t_k) state_q <= CB_BEGIN;
                else begin
                    ky_q <= ky_q + 10'd1;
                    row_cursor_q <= row_cursor_q + row_bytes_q;
                    state_q <= ROW_FETCH;
                end
            end

            // ---- 逐通道块 ----
            CB_BEGIN: state_q <= WGT_LOAD;

            WGT_LOAD: begin
                if (is_pool || is_add || is_gap) begin
                    state_q <= PAR_LOAD;
                end else if (!load_busy && !load_done) begin
                    load_addr  <= weight_cursor_q;
                    load_len   <= 16'(32'(t_steps) << 5);
                    load_dst   <= 2'd0;
                    load_wbase <= '0;
                    load_start <= 1'b1;
                    state_q    <= WGT_WAIT;
                end
            end

            WGT_WAIT: begin
                if (load_err) state_q <= FAULT;
                else if (!load_busy && load_done) state_q <= PAR_LOAD;
            end

            PAR_LOAD: begin
                load_addr  <= param_cursor_q;
                load_len   <= 10'd32 * 8;
                load_dst   <= 2'd1;
                load_wbase <= '0;
                load_start <= 1'b1;
                state_q    <= PAR_WAIT;
            end

            PAR_WAIT: begin
                if (load_err) state_q <= FAULT;
                else if (!load_busy && load_done) state_q <= is_add ? PAR2_LOAD : PX_BEGIN;
            end

            PAR2_LOAD: begin
                load_addr  <= param2_cursor_q;
                load_len   <= 10'd32 * 8;
                load_dst   <= 3'd4;
                load_wbase <= '0;
                load_start <= 1'b1;
                state_q    <= PAR2_WAIT;
            end

            PAR2_WAIT: begin
                if (load_err) state_q <= FAULT;
                else if (!load_busy && load_done) state_q <= PX_BEGIN;
            end

            // ---- 逐像素：MAC ----
            PX_BEGIN: begin
                x_q <= '0;
                x_stride_pos_q <= '0;
                st_q <= '0; ky_q <= '0; kx_q <= '0; ci_q <= '0;
                pixel_base_q <= (is_dw || is_pool || is_gap || is_add) ? 11'(cb_q) : 11'd0;
                row_addr_q <= (is_dw || is_pool || is_gap || is_add) ? 11'(cb_q) : 11'd0;
                state_q <= MAC_ADDR;
            end

            // 行缓冲和权重 RAM 同步读；先给当前 tap 一个地址拍，再消费其数据。
            MAC_ADDR: begin
                // This existing first-tap address cycle also seeds the signed
                // wrap cursors for all subsequent taps of the output pixel.
                wrap_col_delta_q <= wrap_col_delta_calc;
                row_wrap_delta_q <= row_wrap_delta_calc;
                pixel_addr_delta_q <= 10'(pixel_addr_delta);
                if (!is_add) row_addr_q <= row_addr_q + tap_addr_delta;
                state_q <= MAC_RUN;
            end

            MAC_RUN: begin
                if (!is_add) row_addr_q <= row_addr_q + tap_addr_delta2;
                if (is_pool) begin
                    for (int lane = 0; lane < LANE_N; lane++) begin
                        if (st_q == '0)
                            pool_max_q[lane*8 +: 8] <= act_flat[lane*8 +: 8];
                        else if (act_flat[lane*8 +: 8] > pool_max_q[lane*8 +: 8])
                            pool_max_q[lane*8 +: 8] <= act_flat[lane*8 +: 8];
                    end
                end
                // 计数器推进
                st_q <= st_q + 10'd1;
                if (st_q + 10'd1 == t_steps) begin
                    state_q <= MAC_TAIL;             // 最后一步的乘积还要一拍进累加器
                end else if (is_dw || is_pool || is_gap) begin
                    if (kx_q + 10'd1 == t_k) begin
                        kx_q <= '0;
                        ky_q <= ky_q + 10'd1;
                    end else begin
                        kx_q <= kx_q + 10'd1;
                    end
                    state_q <= MAC_RUN;
                end else begin
                    if (kx_q + 10'd1 == t_k) begin
                        kx_q <= '0;
                        if (ky_q + 10'd1 == t_k) begin
                            ky_q <= '0;
                            ci_q <= ci_q + 10'd1;
                        end else ky_q <= ky_q + 10'd1;
                    end else kx_q <= kx_q + 10'd1;
                    state_q <= MAC_RUN;
                end
            end

            MAC_TAIL: begin
                st_q <= '0;
                pk_q <= '0;
                ky_q <= '0;
                kx_q <= '0;
                ci_q <= '0;
                rq_q <= '0;
                if (is_gap) begin
                    if (x_q + 10'd1 < t_in_w) begin
                        x_q <= x_q + 10'd1;
                        x_stride_pos_q <= stride_product(x_q + 10'd1, t_stride);
                        pixel_base_q <= pixel_base_q + {1'b0, pixel_addr_delta_q};
                        row_addr_q <= pixel_base_q + {1'b0, pixel_addr_delta_q};
                        state_q <= MAC_ADDR;
                    end else if (y_q + 10'd1 < t_in_h) begin
                        x_q <= '0;
                        x_stride_pos_q <= '0;
                        y_q <= y_q + 10'd1;
                        row_cursor_q <= row_cursor_q + row_y_delta_q;
                        pixel_base_q <= 11'(cb_q);
                        row_addr_q <= 11'(cb_q);
                        state_q <= ROW_BEGIN;
                    end else begin
                        x_q <= '0; y_q <= '0;
                        x_stride_pos_q <= '0;
                        state_q <= CAPTURE;
                    end
                end else state_q <= (is_add || is_pool) ? FLUSH_ADDR : CAPTURE;
            end

            // Snapshot the completed accumulators and immediately start the
            // next MAC tile. If the previous RQ has not drained yet, hold here.
            CAPTURE: if (!rq_bg_busy_q) begin
                rq_hold_acc_q <= acc_flat;
                rq_bg_busy_q <= 1'b1;
                rq_bg_issue_q <= '0;
                rq_bg_collect_q <= '0;
                rq_bg_base_word_q <= 12'(((is_gap ? 32'd0 : mul20x10({10'd0, x_q}, t_out_c_pad))
                                           + (32'(cb_q) << 5)) >> 2);
                if (is_gap) begin
                    x_q <= '0; y_q <= '0;
                    x_stride_pos_q <= '0;
                    if (cb_q + 10'd1 == nblk_w) state_q <= ROW_DRAIN;
                    else begin
                        cb_q <= cb_q + 10'd1;
                        row_cursor_q <= row_start_cursor_q;
                        weight_cursor_q <= weight_cursor_q + weight_cursor_step_q;
                        param_cursor_q <= param_cursor_q + 32'd256;
                        param2_cursor_q <= param2_cursor_q + 32'd256;
                        state_q <= ROW_BEGIN;
                    end
                end else if (x_q + 10'd1 == t_out_w) begin
                    x_q <= '0;
                    x_stride_pos_q <= '0;
                    state_q <= (cb_q + 10'd1 == nblk_w) ? ROW_DRAIN : CB_BEGIN;
                    if (cb_q + 10'd1 < nblk_w) begin
                        cb_q <= cb_q + 10'd1;
                        weight_cursor_q <= weight_cursor_q + weight_cursor_step_q;
                        param_cursor_q <= param_cursor_q + 32'd256;
                        param2_cursor_q <= param2_cursor_q + 32'd256;
                    end
                end else begin
                    x_q <= x_q + 10'd1;
                    x_stride_pos_q <= stride_product(x_q + 10'd1, t_stride);
                    pixel_base_q <= pixel_base_q + {1'b0, pixel_addr_delta_q};
                    row_addr_q <= pixel_base_q + {1'b0, pixel_addr_delta_q};
                    state_q <= MAC_ADDR;
                end
            end

            // ---- 重量化 ----
            // 推一拍、等一拍：8 次推入若背靠背发出去，它们的输出会在这两个状态
            // 之间流走，收不全 32 个码。
            FLUSH_REQ: begin
                rq_valid <= 1'b1;
                rq2_valid <= is_add;
                if (is_pool) rq_acc <= pool_acc_q;
                else if (is_add) begin
                    for (int lane = 0; lane < RQ_LANES; lane++) begin
                        rq_acc[lane*32 +: 32] <= center_code(row_rdata[(rq_q*RQ_LANES+lane)*8 +: 8]);
                        rq2_acc[lane*32 +: 32] <= center_code(brow_rdata[(rq_q*RQ_LANES+lane)*8 +: 8]);
                    end
                end else rq_acc <= acc_flat[(rq_q*RQ_LANES)*32 +: RQ_LANES*32];
                rq_m18   <= param_field(par_rdata, 0);
                rq_post  <= param_field(par_rdata, 1);
                rq_bfix  <= param_field(par_rdata, 2);
                rq_zp    <= param_field(par_rdata, 3);
                rq2_m18  <= param_field(par2_rdata, 0);
                rq2_post <= param_field(par2_rdata, 1);
                rq2_bfix <= param_field(par2_rdata, 2);
                rq2_zp   <= param_field(par2_rdata, 3);
                state_q  <= FLUSH_WAIT;
            end

            // 参数块是 RAM，读出晚一拍：先把地址发出去，下一拍再推入。
            FLUSH_ADDR: begin
                state_q <= FLUSH_REQ;
            end

            FLUSH_WAIT: begin
                if (rq_out_valid && (!is_add || rq2_out_valid)) begin
                    code_pack_q[pk_q * 32 +: 32] <= is_add ? add_code_word : rq_out_code;
                    if (pk_q == 4'd7) begin
                        wr16_q <= '0;
                        state_q <= FLUSH_STORE;
                    end else begin
                        pk_q <= pk_q + 4'd1;
                        rq_q <= rq_q + 5'd1;
                        state_q <= FLUSH_ADDR;
                    end
                end
            end

            FLUSH_STORE: begin
                out_we <= 1'b1;
                out_waddr <= 12'(((is_gap ? 32'd0 : mul20x10({10'd0, x_q}, t_out_c_pad))
                                  + (32'(cb_q) << 5)) >> 2) + 12'(wr16_q);
                out_wdata <= code_pack_q[wr16_q * 32 +: 32];
                if (wr16_q == 4'd7) begin
                    if (is_gap) begin
                        x_q <= '0; y_q <= '0;
                        x_stride_pos_q <= '0;
                        if (cb_q + 10'd1 == nblk_w) state_q <= ROW_DRAIN;
                        else begin
                            cb_q <= cb_q + 10'd1;
                            weight_cursor_q <= weight_cursor_q + weight_cursor_step_q;
                            param_cursor_q <= param_cursor_q + 32'd256;
                            param2_cursor_q <= param2_cursor_q + 32'd256;
                            state_q <= ROW_BEGIN;
                        end
                    end else if (x_q + 10'd1 == t_out_w) begin
                        x_q <= '0;
                        x_stride_pos_q <= '0;
                        state_q <= (cb_q + 10'd1 == nblk_w) ? ROW_DRAIN : CB_BEGIN;
                        if (cb_q + 10'd1 < nblk_w) begin
                            cb_q <= cb_q + 10'd1;
                            weight_cursor_q <= weight_cursor_q + weight_cursor_step_q;
                            param_cursor_q <= param_cursor_q + 32'd256;
                            param2_cursor_q <= param2_cursor_q + 32'd256;
                        end
                    end else begin
                        x_q <= x_q + 10'd1;
                        x_stride_pos_q <= stride_product(x_q + 10'd1, t_stride);
                        pixel_base_q <= pixel_base_q + {1'b0, pixel_addr_delta_q};
                        row_addr_q <= pixel_base_q + {1'b0, pixel_addr_delta_q};
                        state_q <= MAC_ADDR;
                    end
                end else wr16_q <= wr16_q + 4'd1;
            end

            // ---- 排出输出行 ----
            ROW_DRAIN: begin
                // GAP scans the input grid with y_q, but its output tensor has
                // exactly one row. Do not use the final input row as the store row.
                if (rq_bg_busy_q) state_q <= ROW_DRAIN;
                else begin
                store_addr <= output_row_cursor_q;
                store_len  <= 16'(mul20x10({10'd0, t_out_w}, t_out_c_pad));
                store_start <= 1'b1;
                state_q <= ROW_DRAIN_WAIT;
                end
            end

            ROW_DRAIN_WAIT: begin
                if (store_err) state_q <= FAULT;
                else if (!store_busy && store_done) begin
                    if (is_gap || y_q + 10'd1 == t_out_h) begin
                        busy <= 1'b0; done <= 1'b1;
                        state_q <= LAYER_END;
                    end else begin
                        y_q <= y_q + 10'd1;
                        output_row_cursor_q <= output_row_cursor_q + output_row_bytes_q;
                        row_cursor_q <= row_cursor_q + row_y_delta_q;
                        if (is_add) add_row_cursor_q <= add_row_cursor_q + row_bytes_q;
                        state_q <= ROW_BEGIN;
                    end
                end
            end

            LAYER_END: state_q <= IDLE;
            FAULT: begin busy <= 1'b0; error <= 1'b1; state_q <= IDLE; end
            default: state_q <= IDLE;
            endcase
        end
    end

`ifdef DEBUG_PAR
    always_ff @(posedge clk) begin
        if (par_we && layer_id == 8'd58)
            $display("PARW %0t addr=%0d data=%h", $time, par_waddr, par_wdata);
        if (state_q == FLUSH_ADDR && rq_q == 5'd0 && layer_id == 8'd58)
            $display("PARR %0t raddr=%0d rdata=%h cb=%0d", $time, par_raddr,
                     par_rdata, cb_q);
        if (state_q == PAR_LOAD && layer_id == 8'd58)
            $display("PARL %0t base=%h off=%0d len=%0d dst=%0d", $time,
                     {2'b0, DDR_PARAMS[29:0]}, t_p_off, t_steps, load_dst);
    end
`endif

`ifdef DEBUG_PAR
    always_ff @(posedge clk) begin
        if (state_q == IDLE && start && layer_id == 8'd58)
            $display("ENGSTART %0t layer=%0d", $time, layer_id);
        if (state_q == SETUP && layer_id == 8'd58)
            $display("ENGSETUP %0t layer=%0d kind=%0d in_w=%0d pad=%0d steps=%0d t_in=%08x",
                     $time, layer_id, L.kind, L.in_w, L.in_c_pad, L.steps, L.t_in);
        if (load_start && layer_id == 8'd58)
            $display("ENGLOAD %0t st=%0d addr=%08x len=%0d", $time, state_q, load_addr, load_len);
    end
`endif

    // 参数块一个 32 字节字里放着 4 个通道，每个通道 8 字节：
    // m18:u24, post:u8, bfix:i32, zp:u8 —— 按 lane 取出对应字段。
    function automatic logic [255:0] param_field(input logic [255:0] word,
                                                  input int unsigned which);
        logic [255:0] r;
        int unsigned base;
        begin
            r = '0;
            for (int l = 0; l < RQ_LANES; l++) begin
                base = l * 64;                       // 每通道 8 字节 = 64 位
                case (which)
                    0: r[l*17 +: 17] = word[base +: 17];             // m18
                    1: r[l*6  +: 6 ] = word[base + 17 +: 6];          // post
                    2: r[l*32 +: 32] = word[base + 32 +: 32];         // bfix
                    3: r[l*8  +: 8 ] = word[base + 23 +: 8];          // zp
                endcase
            end
            param_field = r;
        end
    endfunction

    // 输出行缓冲读出（排出用，由 gesture_line_store 驱动地址）

`ifdef SIM_ASSERT
    wire [10:0] legacy_tap_col_delta2 = (fetch2_col >= fetch_col)
        ? 11'(mul20x5({10'd0, fetch2_col - fetch_col}, t_in_c_pad[9:5]))
        : 11'(-mul20x5({10'd0, fetch_col - fetch2_col}, t_in_c_pad[9:5]));
    wire [10:0] legacy_tap_addr_delta2 = legacy_tap_col_delta2
        + row_step_delta(fetch_ky, fetch2_ky, row_span_q)
        + 11'((fetch2_ci >> 5) - (fetch_ci >> 5));
    wire [10:0] legacy_tap_col_delta = (fetch_col >= col_idx)
        ? 11'(mul20x5({10'd0, fetch_col - col_idx}, t_in_c_pad[9:5]))
        : 11'(-mul20x5({10'd0, col_idx - fetch_col}, t_in_c_pad[9:5]));
    wire [10:0] legacy_tap_addr_delta = legacy_tap_col_delta
        + row_step_delta(ky_q, fetch_ky, row_span_q)
        + 11'((fetch_ci >> 5) - (ci_q >> 5));

    wire pixel_advance_gap = (state_q == MAC_TAIL) && is_gap
                           && (x_q + 10'd1 < t_in_w);
    wire pixel_advance_capture = (state_q == CAPTURE) && !rq_bg_busy_q && !is_gap
                               && (x_q + 10'd1 != t_out_w);
    wire pixel_advance_store = (state_q == FLUSH_STORE) && (wr16_q == 4'd7)
                             && !is_gap && (x_q + 10'd1 != t_out_w);

    always_ff @(posedge clk) begin
        if (!reset && state_q == SETUP && L.kind == 3'd0 && L.steps > 672)
            $fatal(1, "engine: unsupported step count %0d", L.steps);
        if (!reset && state_q == SETUP && L.k > 10'd5)
            $fatal(1, "engine: incremental tap cursor supports K<=5, got %0d", L.k);
        if (!reset && state_q == MAC_ADDR && !is_add
            && tap_addr_delta !== legacy_tap_addr_delta)
            $fatal(1, "MAC_ADDR tap delta mismatch layer=%0d k=(%0d,%0d)",
                   layer_id, ky_q, kx_q);
        if (!reset && state_q == MAC_RUN && !is_add
            && tap_addr_delta2 !== legacy_tap_addr_delta2)
            $fatal(1, "MAC_RUN tap delta mismatch layer=%0d k=(%0d,%0d) fetch=(%0d,%0d) next=(%0d,%0d): got=%0d expected=%0d",
                   layer_id, ky_q, kx_q, fetch_ky, fetch_kx, fetch2_ky,
                   fetch2_kx, tap_addr_delta2, legacy_tap_addr_delta2);
        if (!reset && state_q == MAC_RUN && is_add
            && row_addr_q !== 11'((mul20x10({10'd0, col_idx}, t_in_c_pad) >> 5)
                                  + 32'(cb_q)))
            $fatal(1, "ADD row cursor mismatch: layer=%0d x=%0d got=%0d",
                   layer_id, x_q, row_addr_q);
        if (!reset && (pixel_advance_gap || pixel_advance_capture || pixel_advance_store)
            && ($isunknown(pixel_addr_delta_q) || $isunknown(pixel_addr_delta)
                || pixel_addr_delta_q !== pixel_addr_delta[9:0]
                || kx_q != 0 || ky_q != 0 || ci_q != 0))
            $fatal(1, "pixel address delta register mismatch layer=%0d state=%0d x=%0d k=(%0d,%0d,%0d) q=%0d comb=%0d",
                   layer_id, state_q, x_q, kx_q, ky_q, ci_q,
                   pixel_addr_delta_q, pixel_addr_delta);
    end
`endif
endmodule
