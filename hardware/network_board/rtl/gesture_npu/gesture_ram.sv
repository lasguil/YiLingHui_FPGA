// 片内块 RAM 包装（一个实例 = 一个 512×SLICE 的 RAM10 块组，深度固定 512 字）。
//
// 为什么显式例化而不是让工具推断：主工程实测，交给工具推断它会自己挑块型，
// 同样容量被挑成 1024×10、白白多占块。
//
// 为什么深度不做进这个模块：把「选块」留在调用方（gesture_weight_ram）里，
// 用实例数组 + 地址译码 + 返回多路器表达，读返回的跨块对齐就更直观。
//
// 约定：
//   * OUTPUT_REG = 0 ⇒ 读返回晚一拍；
//   * RST 恒接 0    ⇒ RAM 内容与读返回都不复位，复位只清控制状态；
//   * 暂停读取靠拉低 read_enable 让原语保持地址与返回，不要门控时钟。
module gesture_ram #(
    parameter int WIDTH     = 32,
    parameter int DEPTH     = 512,
    parameter int SLICE     = 20,       // 每块每拍的读位宽，RAM10 最宽是 20
    parameter     INIT_FILE = ""        // 非空则 $readmemh 预载（仅 FAST_SIM）
) (
    input  logic                       clk,
    input  logic                       read_enable,
    input  logic                       write_enable,
    input  logic [$clog2(DEPTH)-1:0]   address,
    input  logic [WIDTH-1:0]           write_data,
    output logic [WIDTH-1:0]           read_data
);
    localparam int BLOCKS = (WIDTH + SLICE - 1) / SLICE;
    localparam int PAD_W  = BLOCKS * SLICE;

    logic [PAD_W-1:0] padded_write;
    logic [PAD_W-1:0] padded_read;

    assign padded_write = {{(PAD_W-WIDTH){1'b0}}, write_data};
    assign read_data    = padded_read[WIDTH-1:0];

`ifdef FAST_SIM
    logic [WIDTH-1:0] storage [0:DEPTH-1];
    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, storage);
    end
    always_ff @(posedge clk) begin
        if (write_enable) storage[address] <= write_data;
        if (read_enable)  padded_read <= {{(PAD_W-WIDTH){1'b0}}, storage[address]};
    end
`else
    for (genvar b = 0; b < BLOCKS; b++) begin : g_blk
        EFX_RAM10 #(
            .READ_WIDTH (SLICE),
            .WRITE_WIDTH(SLICE),
            .OUTPUT_REG (1'b0),
            .WRITE_MODE ("READ_FIRST")
        ) u_ram (
            .WCLK   (clk),
            .WE     ({SLICE{1'b1}}),
            .WCLKE  (write_enable),
            .WADDREN(1'b1),
            .WDATA  (padded_write[b*SLICE +: (b + 1 == BLOCKS && PAD_W > WIDTH)
                                 ? (PAD_W - b*SLICE) : SLICE]),
            .WADDR  (address),
            .RCLK   (clk),
            .RE     (read_enable),
            .RST    (1'b0),
            .RADDREN(1'b1),
            .RDATA  (padded_read[b*SLICE +: ((b + 1) * SLICE <= PAD_W) ? SLICE : 1]),
            .RADDR  (address)
        );
    end
`endif
endmodule
