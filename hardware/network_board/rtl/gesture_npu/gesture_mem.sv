// 行缓冲与 DMA 搬运。
//
// 设计依据：一次推理的 DDR 流量只有约 2.5 MB（1.5 ms @ 1.6 GB/s），而计算要
// 32 ms——所以激活张量全部放 DDR、片内只留行缓冲，比把 250 KiB 张量塞进
// 320 KiB 的片内 RAM 简单得多，也让引擎不必理会张量生命周期。
//
// 片内只保留「当前行/当前窗口」这一级，由这两个模块从 DDR 灌入、向 DDR 排出。

// ---------------------------------------------------------------------------
// 字节宽的简单行 RAM：1 字节/拍读写。用于输入行、DW 输出行、输出行暂存。
// 显式例化 EFX_RAM10，避免工具推断出多占块的形状。
// ---------------------------------------------------------------------------
module gesture_line_ram #(
    parameter int DEPTH     = 2048,     // 2 的幂
    parameter int INIT_FILE = ""
) (
    input  logic                       clk,
    input  logic                       write_enable,
    input  logic [$clog2(DEPTH)-1:0]   write_address,
    input  logic [7:0]                 write_data,
    input  logic                       read_enable,
    input  logic [$clog2(DEPTH)-1:0]   read_address,
    output logic [7:0]                 read_data
);
    localparam int AW = $clog2(DEPTH);

`ifdef FAST_SIM
    logic [7:0] storage [0:DEPTH-1];
    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, storage);
    end
    always_ff @(posedge clk) begin
        if (write_enable) storage[write_address] <= write_data;
        if (read_enable)  read_data <= storage[read_address];
    end
`else
    // 1024×10 形状：8 位数据 + 2 位余量，每块 1024 字。
    for (genvar b = 0; b < DEPTH / 1024; b++) begin : g_blk
        logic [9:0] rd;
        EFX_RAM10 #(
            .READ_WIDTH(10), .WRITE_WIDTH(10), .OUTPUT_REG(1'b0), .WRITE_MODE("READ_FIRST")
        ) u_ram (
            .WCLK(clk), .WE(2'b01), .WCLKE(write_enable), .WADDREN(1'b1),
            .WDATA({2'b0, write_data}), .WADDR(write_address[9:0]),
            .RCLK(clk), .RE(read_enable), .RST(1'b0), .RADDREN(1'b1),
            .RDATA(rd), .RADDR(read_address[9:0])
        );
        if (b == 0) assign read_data = rd[7:0];
    end
`endif
endmodule


// ---------------------------------------------------------------------------
// 32 字节宽的块 RAM：每拍读出 32 字节（一整组 lane 的权重 / 一整行的展开窗口）。
// ---------------------------------------------------------------------------
module gesture_word_ram #(
    parameter int WORDS     = 512,      // 字数（每字 32 字节）
    parameter int INIT_FILE = ""
) (
    input  logic                       clk,
    input  logic                       write_enable,
    input  logic [$clog2(WORDS)-1:0]   write_address,
    input  logic [255:0]               write_data,
    input  logic                       read_enable,
    input  logic [$clog2(WORDS)-1:0]   read_address,
    output logic [255:0]               read_data
);
    localparam int BANK_WORDS = 512;
    localparam int BANKS = (WORDS + BANK_WORDS - 1) / BANK_WORDS;
    localparam int PHYSICAL_WORDS = BANKS * BANK_WORDS;
    localparam int BANK_AW = (BANKS <= 1) ? 1 : $clog2(BANKS);
    logic [BANK_AW-1:0] read_bank_q;
    logic [255:0] bank_data [0:BANKS-1];
    wire [8:0] write_address_in_bank = 9'(write_address);
    wire [8:0] read_address_in_bank = 9'(read_address);

`ifdef SIM_ASSERT
    always_ff @(posedge clk) begin
        if (write_enable && write_address >= WORDS)
            $fatal(1, "gesture_word_ram write address %0d exceeds WORDS=%0d", write_address, WORDS);
        if (read_enable && read_address >= WORDS)
            $fatal(1, "gesture_word_ram read address %0d exceeds WORDS=%0d", read_address, WORDS);
    end
`endif

    always_ff @(posedge clk)
        if (read_enable) read_bank_q <= BANK_AW'(read_address >> 9);

`ifdef FAST_SIM
    logic [255:0] storage [0:PHYSICAL_WORDS-1];
    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, storage);
    end
    always_ff @(posedge clk) begin
        if (write_enable) storage[write_address] <= write_data;
        if (read_enable)  read_data <= storage[read_address];
    end
`else
    for (genvar bank = 0; bank < BANKS; bank++) begin : g_bank
        wire bank_we;
        if (BANKS == 1)
            assign bank_we = write_enable;
        else
            assign bank_we = write_enable && (BANK_AW'(write_address >> 9) == BANK_AW'(bank));

        for (genvar b = 0; b < 13; b++) begin : g_blk
            logic [19:0] rd;
            if (b < 12) begin : g_full
                EFX_RAM10 #(
                    .READ_WIDTH(20), .WRITE_WIDTH(20), .OUTPUT_REG(1'b0), .WRITE_MODE("READ_FIRST")
                ) u_ram (
                    .WCLK(clk), .WE(2'b11), .WCLKE(bank_we), .WADDREN(1'b1),
                    .WDATA(write_data[b*20 +: 20]), .WADDR(write_address_in_bank),
                    .RCLK(clk), .RE(read_enable), .RST(1'b0), .RADDREN(1'b1),
                    .RDATA(rd), .RADDR(read_address_in_bank)
                );
                assign bank_data[bank][b*20 +: 20] = rd;
            end else begin : g_tail
                EFX_RAM10 #(
                    .READ_WIDTH(20), .WRITE_WIDTH(20), .OUTPUT_REG(1'b0), .WRITE_MODE("READ_FIRST")
                ) u_ram (
                    .WCLK(clk), .WE(2'b11), .WCLKE(bank_we), .WADDREN(1'b1),
                    .WDATA({4'b0, write_data[255:240]}), .WADDR(write_address_in_bank),
                    .RCLK(clk), .RE(read_enable), .RST(1'b0), .RADDREN(1'b1),
                    .RDATA(rd), .RADDR(read_address_in_bank)
                );
                assign bank_data[bank][255:240] = rd[15:0];
            end
        end
    end
    assign read_data = bank_data[read_bank_q];
`endif
endmodule


// Each parameter DMA is exactly 8 x 256-bit words. Store the serially loaded
// words in shallow SRLs instead of reserving thirteen 512x20 RAM blocks.
module gesture_param_srl (
    input  logic         clk,
    input  logic         write_enable,
    input  logic [2:0]   write_address,
    input  logic [255:0] write_data,
    input  logic         read_enable,
    input  logic [2:0]   read_address,
    output logic [255:0] read_data
);
`ifdef FAST_SIM
    logic [255:0] storage [0:7];
    logic [2:0] read_address_q;
    always_ff @(posedge clk) begin
        if (write_enable) storage[write_address] <= write_data;
        if (read_enable) read_address_q <= read_address;
    end
    always_comb read_data = storage[read_address_q];
`else
    logic [2:0] read_address_q;
    wire [255:0] q_inv;
    always_ff @(posedge clk)
        if (read_enable) read_address_q <= read_address;
    for (genvar bit_index = 0; bit_index < 256; bit_index++) begin : g_srl
        EFX_SRL8 #(.INIT(8'h00)) u_srl (
            .D(write_data[bit_index]), .A(read_address_q), .CLK(clk),
            .CE(write_enable), .Q(q_inv[bit_index]), .Q7()
        );
    end
    always_comb read_data = ~q_inv;
`endif

`ifdef SIM_ASSERT
    logic [2:0] expected_write_address = 3'd0;
    always_ff @(posedge clk) begin
        if (write_enable) begin
            if (write_address !== expected_write_address)
                $fatal(1, "gesture_param_srl expects sequential writes: got=%0d expected=%0d",
                       write_address, expected_write_address);
            expected_write_address <= expected_write_address + 3'd1;
        end
    end
`endif
endmodule


// ---------------------------------------------------------------------------
// DDR 读引擎：把 [base, base+length) 连续灌进一个行缓冲。
//
// 用 gesture_axi_master 的字节区间命令；128 位一拍，两拍拼成一个 32 字节字
// 写进 gesture_word_ram。命令地址 16 字节对齐由调用方保证。
// ---------------------------------------------------------------------------
module gesture_line_load (
    output logic [31:0] debug_state,
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [31:0] byte_address,
    input  logic [15:0] byte_length,     // 1..65535
    output logic        busy,
    output logic        done,
    output logic        error,
    // 向 AXI 主机的读命令
    output logic        rd_valid,
    input  logic        rd_ready,
    output logic [31:0] rd_address,
    output logic [15:0] rd_length,
    input  logic        rd_data_valid,
    output logic        rd_data_ready,
    input  logic [127:0] rd_data,
    input  logic [15:0]  rd_keep,
    input  logic         rd_last,
    input  logic         rd_done,
    input  logic         rd_error,
    // 目标缓冲的写口
    output logic        buf_write_enable,
    output logic [9:0]  buf_write_address,
    output logic [255:0] buf_write_data
);
    typedef enum logic [2:0] {IDLE, CMD, FILL, FINISH, ERR} state_t;
    state_t state_q;

    logic [9:0]  word_q;          // 已写出的 32 字节字数
    logic [127:0] half_q;         // 低 16 字节暂存，等第二拍拼成一个字
    logic        half_valid_q;
    assign debug_state={2'd0,byte_length,half_valid_q,word_q,state_q};

    assign busy = (state_q != IDLE);

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= IDLE;
            word_q  <= '0;
            half_valid_q <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            buf_write_enable <= 1'b0;
        end else begin
            done <= 1'b0;
            error <= 1'b0;
            buf_write_enable <= 1'b0;

            case (state_q)
                IDLE: begin
                    word_q <= '0;
                    half_valid_q <= 1'b0;
                    if (start) state_q <= CMD;
                end

                CMD: begin
                    // 命令由 gesture_axi_master 的 read_valid/ready 握手发出
                    if (rd_valid && rd_ready) state_q <= FILL;
                end

                FILL: begin
                    if (rd_data_valid) begin
                        if (!half_valid_q) begin
                            half_q <= rd_data;
                            half_valid_q <= 1'b1;
                        end else begin
                            buf_write_enable  <= 1'b1;
                            buf_write_address <= word_q;
                            buf_write_data    <= {rd_data, half_q};
                            half_valid_q      <= 1'b0;
                            word_q            <= word_q + 9'd1;
                        end
                    end
                    if (rd_error) state_q <= ERR;
                    else if (rd_done) state_q <= FINISH;
                end

                FINISH: begin
                    // 长度为奇数拍时把尾部半字补零写出，保持缓冲内容确定
                    if (half_valid_q) begin
                        buf_write_enable  <= 1'b1;
                        buf_write_address <= word_q;
                        buf_write_data    <= {128'd0, half_q};
                        half_valid_q      <= 1'b0;
                        word_q            <= word_q + 9'd1;
                    end else begin
                        done   <= 1'b1;
                        state_q <= IDLE;
                    end
                end

                ERR: begin
                    error   <= 1'b1;
                    done    <= 1'b1;
                    state_q <= IDLE;
                end

                default: state_q <= IDLE;
            endcase
        end
    end

`ifdef DEBUG_PAR
    always_ff @(posedge clk)
        if (state_q == IDLE && start && (byte_address[3:0] != 0 || byte_length == 0))
            $display("BADLOAD %0t addr=%08x len=%0d", $time, byte_address, byte_length);
`endif

    assign rd_valid    = (state_q == CMD);
    assign rd_address  = byte_address;
    assign rd_length   = byte_length;
    assign rd_data_ready = 1'b1;

`ifdef SIM_ASSERT
    always_ff @(posedge clk) begin
        if (!reset && state_q == CMD && rd_valid && !rd_ready)
            ; // 正常等待
        if (!reset && buf_write_enable && buf_write_address > 10'd1023)
            $fatal(1, "line_load: row buffer overflow");
    end
`endif
endmodule


// ---------------------------------------------------------------------------
// DDR 写引擎：把一块行缓冲按字节区间排出去。
//
// 缓冲读出是 128 位（= 恰好一拍 AXI），所以一个字发一拍；长度不是 16 倍数时
// 末拍用 wr_keep 精确裁掉多余字节（gesture_axi_master 的契约）。
// ---------------------------------------------------------------------------
module gesture_line_store #(
    parameter int WORDS = 512                 // 缓冲深度（16 字节字）
) (
    output logic [31:0] debug_state,
    input  logic         clk,
    input  logic         reset,
    input  logic         start,
    input  logic [31:0]  byte_address,
    input  logic [15:0]  byte_length,         // 1..65535
    output logic         busy,
    output logic         done,
    output logic         error,
    output logic         buf_read_enable,
    output logic [11:0]  buf_read_address,
    input  logic [127:0] buf_read_data,
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
    typedef enum logic [2:0] {IDLE, CMD, FETCH, READ_WAIT, SEND, FINISH, ERR} state_t;
    state_t state_q;

    logic [11:0] word_q;                     // 当前 16 字节字
    logic [11:0] words_q;                    // 总字数
    logic [15:0] remain_q;                   // 还剩多少字节
    logic [127:0] data_q;
    logic        have_q;
    assign debug_state={1'd0,remain_q,word_q,state_q};

    assign busy = (state_q != IDLE);
    // 本字有效的字节数
    wire [15:0] want = (remain_q >= 16'd16) ? 16'd16 : remain_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= IDLE; word_q <= '0; done <= 1'b0; error <= 1'b0;
            have_q <= 1'b0; buf_read_enable <= 1'b0;
        end else begin
            done <= 1'b0; error <= 1'b0; buf_read_enable <= 1'b0;

            case (state_q)
            IDLE: begin
                word_q <= '0; have_q <= 1'b0;
                if (start) begin
                    words_q <= (byte_length + 16'd15) >> 4;
                    remain_q <= byte_length;
                    state_q <= CMD;
                end
            end

            CMD: if (wr_valid && wr_ready) state_q <= FETCH;

            FETCH: begin
                buf_read_enable  <= 1'b1;
                buf_read_address <= word_q;
                state_q <= READ_WAIT;
            end

            READ_WAIT: state_q <= SEND;

            SEND: begin
                if (!have_q) begin
                    data_q <= buf_read_data;      // RAM 返回晚一拍
                    have_q <= 1'b1;
                end else if (wr_data_valid && wr_data_ready) begin
                    have_q <= 1'b0;
                    remain_q <= remain_q - 16'd16;
                    if (remain_q <= 16'd16) state_q <= FINISH;
                    else begin
                        word_q <= word_q + 12'd1;
                        state_q <= FETCH;
                    end
                end
            end

            FINISH: begin done <= 1'b1; state_q <= IDLE; end
            ERR:    begin error <= 1'b1; done <= 1'b1; state_q <= IDLE; end
            default: state_q <= IDLE;
            endcase
        end
    end

    assign wr_valid      = (state_q == CMD);
    assign wr_address    = byte_address;
    assign wr_length     = byte_length;
    assign wr_data_valid = (state_q == SEND) && have_q;
    assign wr_data       = data_q;
    assign wr_keep       = (want >= 16'd16) ? 16'hFFFF : ((16'h0001 << want) - 16'h1);
    assign wr_last       = (state_q == SEND) && have_q && (remain_q <= 16'd16);

`ifdef SIM_ASSERT
    always_ff @(posedge clk) begin
        if (!reset && state_q == SEND && have_q && wr_data_valid
            && (word_q >= words_q))
            $fatal(1, "line_store: wrote past the requested length");
    end
`endif
endmodule


// ---------------------------------------------------------------------------
// 输出行缓冲：4 个字节体并行，每拍写 4 个码（正好是重量化一拍的输出数），
// 每拍读 16 字节（排出一拍）。
// ---------------------------------------------------------------------------
module gesture_out_ram #(
    parameter int BYTES = 8192
) (
    input  logic         clk,
    input  logic         write_enable,
    input  logic [11:0]  write_address,      // 4 字节字地址
    input  logic [31:0]  write_data,
    input  logic         read_enable,
    input  logic [11:0]  read_address,       // 16 字节字地址
    output logic [127:0] read_data
);
    // 16 byte banks form the 128-bit DMA read port. The engine writes four
    // bytes per cycle, so each write selects one of four groups of four banks.
    logic [7:0] rd [0:15];
    for (genvar b = 0; b < 16; b++) begin : g_lane
        localparam int GROUP = b / 4;
        localparam int BYTE  = b % 4;
        logic lane_we;
        assign lane_we = write_enable && (write_address[1:0] == 2'(GROUP));
        gesture_line_ram #(.DEPTH(1024)) u_lane (
            .clk(clk),
            .write_enable(lane_we),
            .write_address(write_address[11:2]),
            .write_data(write_data[BYTE*8 +: 8]),
            .read_enable(read_enable),
            .read_address(read_address[9:0]),
            .read_data(rd[b]));
        assign read_data[b*8 +: 8] = rd[b];
    end
endmodule
