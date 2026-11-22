// 协议契约：实际有效权重每槽39项；参数两槽各20项；单批层的第二参数槽不消费，允许读取紧邻数据。
// 严格顺序：最多前两槽权重、两槽参数、剩余权重；valid/ready接受；RAM输出及块选择回压期间保持。
// reset丢弃未完成返回和装载进度；上层同步复位常驻槽，禁止半槽commit；完成事件在最后一项接受沿。
module ngm_weight_ram #(  // 参数表结束
    parameter int unsigned WORD_BITS    = 40,     // 一项 40 位 = 常驻槽的两个 20 位字（每拍给两个字）
    parameter int unsigned ADDR_W       = 12,     // 表内地址位宽（2560 项 → 12 位）
    parameter int unsigned TABLE_WORDS  = 2560,   // 表深：2560 项 = 10 个 RAM10（每个 256×40）
    parameter int unsigned GROUP_WORDS  = 39,     // 一个槽组在**流里**几项（1536 位 ÷ 40 = 38.4 → 39）
    parameter int unsigned WEIGHT_GROUPS= 6,      // 权重槽数上限；实际装载由layer_count给定
    parameter int unsigned PARAM_GROUPS = 2,      // 参数固定两组，逻辑槽0/1对应两批
    parameter int unsigned PARAM_KEEP   = 20,     // 参数每组在表里实际只占几项（786 位 ÷ 40 = 20）
    parameter int unsigned BLOCK_WORDS  = 512      // 每路每块装几字（READ_WIDTH=20 → 512×20）
) (  // 端口表开始
    input  logic                 clk,             // 时钟
    input  logic                 reset,           // 同步复位（只清控制状态，表内容不清）

    // ---- 层边界装载请求（来自调度端；基址来自描述符，权重/参数各一个）----
    input  logic                 layer_load_start,  // 一拍请求：装载本层 context
    output logic                 layer_load_ready,  // 可以接请求（定序器空闲且不在重载）
    input  logic [ADDR_W-1:0]    layer_weight_base, // 本层权重组在表里的首字地址
    input  logic [ADDR_W-1:0]    layer_param_base,  // 本层参数组在表里的首字地址
    output logic                 layer_load_done,   // 最后一项被ready接受时的完成事件

    // ---- 到常驻槽的 context 流（valid/ready + data + 槽、组、参数标记）----
    input logic [2:0] layer_count, // 有效权重槽数1/2/3/4/6，由描述符计算。
    input logic stream_ready, // 接收端容量和参数尾部回压。
    output logic [2:0] stream_slot, // 返回项的逻辑槽号。
    output logic [5:0] stream_pair, // 返回项的40位组号。
    output logic stream_param, // 参数与权重标记。
    output logic                 stream_valid,       // 本拍有一个字
    output logic [WORD_BITS-1:0] stream_data,        // 这个字

    // ---- 整表重载（来自主机/AXI 侧；只在层边界发起，线性写满整表）----
    input  logic                 reload_valid,       // 本拍要写一个字
    output logic                 reload_ready,       // 能收（不在层装载中）
    input  logic [ADDR_W-1:0]    reload_addr,        // 写到哪个字
    input  logic [WORD_BITS-1:0] reload_data,        // 写什么
    output logic                 reload_active       // 正在重载（上层据此推迟下一次层装载）
);  // 上电镜像结束
    // --------------------------- 推导常量 ---------------------------

    // --------------------------- 表本体：显式例化的 10 个 RAM10 ---------------------------
    // 用显式例化而不是推断，是为了钉住块型：20 位宽对 RAM10 就是 512×20（10,240 位），
    // 5120 个字 / 512 = 10 块。若交给工具推断，它会自己挑块型（实测挑成 1024×10，
    // 同样容量要 20 块）—— 白白多占 9 块。
    // 初值：原语没有 $readmemh 路径，只有 INIT_* 参数；而本表的内容本来就靠重载口装
    // （风格切换走同一条路），所以这里不写初值（默认全 0），开机由主机灌一种风格。
    // 一项 40 位**不能用一块 RAM10 装**：本机 Efinity 2026.1 的 EFX_RAM10 只支持
    // READ_WIDTH/WRITE_WIDTH ∈ {1,2,4,5,8,10,16,20}（40 位不在表内，精化会报错）。
    // 所以把每项拆成两路 20 位：每路 5 块 × (512 字 × 20 位)，两路共 10 块 —— 与原来同样多的 RAM10，
    // 而且是合法的原语配置。两路共用同一个项地址，读出后拼成 40 位、写入时各取自己那 20 位。
    localparam int unsigned HALF_W     = 20;                                  // 单块 RAM10 的最大宽度（原语上限）
    localparam int unsigned HALVES     = WORD_BITS / HALF_W;                  // 一项拆成几路（40/20 = 2）
    localparam int unsigned BLOCKS_PER = (TABLE_WORDS + BLOCK_WORDS - 1) / BLOCK_WORDS; // 每路几块（2560/512 = 5）
    localparam int unsigned BLOCK_COUNT= HALVES * BLOCKS_PER;                 // 总块数（10）
    localparam int unsigned BLK_AW     = $clog2(BLOCK_WORDS);                 // 块内地址位宽（512 → 9 位）
    localparam int unsigned BLK_SEL_W  = $clog2(BLOCKS_PER);                  // 块号位宽（5 块 → 3 位）

    wire launch; // 同步读使能先声明供块号流水使用。
    logic [WORD_BITS-1:0] table_rd_q;                    // 同步读的数据（两路拼起来，t+1 拍有效）
    logic [ADDR_W-1:0]    table_rd_addr;                 // 本拍送给表的项地址
    logic [BLK_AW-1:0]    rd_blk_addr;                   // 块内读地址（两路所有块共用一个）
    logic [BLK_SEL_W-1:0] rd_blk_sel;                    // 本拍要读第几块（两路相同）
    logic [BLK_SEL_W-1:0] rd_blk_sel_q;                  // 块号打一拍：读出一拍，块号跟着一起延迟
    logic [HALF_W-1:0]    rd_half [0:HALVES-1][0:BLOCKS_PER-1]; // [路][块] 的读出数据

    assign rd_blk_addr  = table_rd_addr[BLK_AW-1:0];     // 低 9 位：块内地址
    assign rd_blk_sel   = table_rd_addr[ADDR_W-1:BLK_AW];// 高 3 位：块号（2560 项只用到 0..4）
    always_ff @(posedge clk) begin                       // 读块号延迟（一级）
        if (reset) rd_blk_sel_q <= '0;                   // 复位清零
        else if (launch) rd_blk_sel_q <= rd_blk_sel;           // 跟着读地址走，晚一拍取数据
    end                                                  // 读块号延迟结束

    // 读出：每个半字路从自己那 5 块里按块号取，再拼成一项
    for (genvar h = 0; h < HALVES; h = h + 1) begin : g_rdhalf // 逐路
        assign table_rd_q[h*HALF_W +: HALF_W] = rd_half[h][rd_blk_sel_q]; // 取本路被选中的块
    end                                                  // 逐路结束

    for (genvar h = 0; h < HALVES; h = h + 1) begin : g_half   // 逐半字路
        for (genvar b = 0; b < BLOCKS_PER; b = b + 1) begin : g_blk // 每路逐块
            wire wr_hit = (reload_valid && reload_ready)   // 本拍要写
                       && (reload_addr[ADDR_W-1:BLK_AW] == BLK_SEL_W'(b)); // 而且写的是本块
            EFX_RAM10 #(                                   // 10K 简单双口 BRAM（一读一写）
                .READ_WIDTH  (HALF_W),                     // 读口 20 位 → 512×20（原语合法值）
                .WRITE_WIDTH (HALF_W),                     // 写口 20 位
                .OUTPUT_REG  (1'b0),                       // 读出只走 BRAM 自带那一级 = 一拍读出
                .WRITE_MODE  ("READ_FIRST")                // 写优先读出旧值（本设计读写不同址）
            ) u_bram (                                     // 本块例化开始
                .WCLK    (clk),                            // 写时钟
                .WE      (2'b11),                          // 写字节使能（20 位宽配两位）
                .WCLKE   (wr_hit),                         // 写到本块才使能
                .WADDREN (1'b1),                           // 写地址使能
                .WDATA   (reload_data[h*HALF_W +: HALF_W]), // 本路的那 20 位
                .WADDR   (reload_addr[BLK_AW-1:0]),        // 块内写地址
                .RCLK    (clk),                            // 读时钟
                .RE      (launch),                           // 发新地址才更新RAM读出，回压时保持。
                .RST     (1'b0),                           // 读出寄存器不复位
                .RADDREN (1'b1),                           // 读地址使能
                .RDATA   (rd_half[h][b]),                  // 本块读出数据
                .RADDR   (rd_blk_addr)                     // 块内读地址
            );                                             // 一块结束
        end                                                // 逐块结束
    end                                                    // 逐路结束

    // --------------------------- 重载的进行/结束 ---------------------------
    logic reload_active_q;                               // 重载进行中
    wire  reload_hit = reload_valid && reload_ready;     // 这一拍真的写进去了
    // 完成判据直接看地址：写满整表的**最后一个字**那一拍结束。这要求写方线性写满
    // （从 0 到 TABLE_WORDS−1，最后写最后一个地址），写方是主机侧，这条契约写在文件头。
    wire  reload_last = reload_hit && (reload_addr == ADDR_W'(TABLE_WORDS) - 1'b1); // 写的是最后一个字

    always_ff @(posedge clk) begin                       // 重载进行标志
        if (reset) reload_active_q <= 1'b0;              // 复位：不在重载
        else if (reload_last) reload_active_q <= 1'b0;   // 写满整表：重载结束
        else if (reload_hit)  reload_active_q <= 1'b1;   // 正在写：重载进行中
    end                                                  // 重载进行标志结束

    logic load_busy_q,pending_q,issued_last_q; // 单套加载协议。
    logic [2:0] count_q,slot_q; // 单套加载协议。
    logic [5:0] pair_q; // 单套加载协议。
    logic [1:0] phase_q; // 单套加载协议。
    logic [ADDR_W-1:0] address_q,w_resume_q,p_base_q; // 单套加载协议。
    logic last_q; // 单套加载协议。
    assign launch=load_busy_q && !issued_last_q && (!pending_q || stream_ready); // 单套加载协议。
    wire take=stream_valid && stream_ready; // 单套加载协议。
    wire terminal=phase_q==2 ? slot_q==count_q-1'b1 && pair_q==38 : phase_q==1 && slot_q==1 && pair_q==19 && count_q<=2; // 单套加载协议。
    assign layer_load_ready=!load_busy_q && !reload_active_q; // 单套加载协议。
    assign reload_ready=!load_busy_q; // 单套加载协议。
    assign reload_active=reload_active_q; // 单套加载协议。
    assign stream_valid=pending_q; // 单套加载协议。
    assign stream_data=table_rd_q; // 单套加载协议。
    assign layer_load_done=take && last_q; // 单套加载协议。
    assign table_rd_addr=address_q; // 单套加载协议。
    always_ff @(posedge clk)begin // 单套加载协议。
      if(reset)begin // 单套加载协议。
        load_busy_q<=0;pending_q<=0;issued_last_q<=0;count_q<=0;slot_q<=0;pair_q<=0;phase_q<=0;address_q<=0;w_resume_q<=0;p_base_q<=0;last_q<=0;stream_slot<=0;stream_pair<=0;stream_param<=0; // 单套加载协议。
      end else begin // 单套加载协议。
        if(layer_load_start && layer_load_ready)begin // 单套加载协议。
          load_busy_q<=1;issued_last_q<=0;count_q<=layer_count;slot_q<=0;pair_q<=0;phase_q<=0;address_q<=layer_weight_base;p_base_q<=layer_param_base; // 单套加载协议。
        end // 单套加载协议。
        if(take)begin pending_q<=0;if(last_q)load_busy_q<=0;end // 单套加载协议。
        if(launch)begin // 单套加载协议。
          pending_q<=1;stream_slot<=slot_q;stream_pair<=pair_q;stream_param<=phase_q==1;last_q<=terminal; // 单套加载协议。
          if(terminal)issued_last_q<=1; // 单套加载协议。
          else if(phase_q==0 && pair_q==38 && (slot_q==1 || slot_q==count_q-1'b1))begin // 单套加载协议。
            w_resume_q<=address_q+1'b1;address_q<=p_base_q;phase_q<=1;slot_q<=0;pair_q<=0; // 单套加载协议。
          end else if(phase_q==1 && slot_q==1 && pair_q==19)begin // 单套加载协议。
            address_q<=w_resume_q;phase_q<=2;slot_q<=2;pair_q<=0; // 单套加载协议。
          end else begin // 单套加载协议。
            address_q<=address_q+1'b1; // 单套加载协议。
            if(pair_q==(phase_q==1 ? 19 : 38))begin pair_q<=0;slot_q<=slot_q+1'b1;end // 单套加载协议。
            else pair_q<=pair_q+1'b1; // 单套加载协议。
          end // 单套加载协议。
        end // 单套加载协议。
      end // 单套加载协议。
    end // 单套加载协议。
`ifdef SIM_ASSERT // 单套加载协议。
    always @(posedge clk)if(!reset && layer_load_start && layer_load_ready && (layer_count<1 || layer_count>6))$fatal(1,"LOADER bad count"); // 单套加载协议。
`endif // 单套加载协议。
endmodule // 单套加载协议。
