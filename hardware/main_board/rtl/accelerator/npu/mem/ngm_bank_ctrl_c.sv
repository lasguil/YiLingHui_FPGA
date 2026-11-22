/* OPTIMIZATION_NOTE_20261005
 * 无损压缩约束（2026-10-05）：特征通道只存7位，必须为0..127；残差需先完成clamp。
 * 当前两组512x224共24块RAM10。逻辑总线仍256位，片外checkpoint格式不压缩。
 * RGB队列属于独立原字路径：低43个定义位逐位保留，禁止套用特征压缩/符号补零。
 * io_rgb_mode须与写请求及实际接受的读请求匹配；rgb_return_q随RAM读接受锁存并保持到消费。
 * 禁止返回时直接用当前层号选择解包，否则换层/背压会解释错数据；切层前仍须排空。
 * SIM_ASSERT不构成板上保护；改模型码域、RGB字布局或队列生命周期须协同重验上下游。
 * 详见 docs/OPTIMIZATION_CONSTRAINTS.md。
 */
// 协议契约：同址待读请求先于写提交，读暂时不可接受时仍保留读优先权；读客户必须依约提供已提交源行。
// 重放期间既有wr_ready/fw_ready均为零；模型/IO读未同址时保持并行写；不增加读或写延迟。
// 协议契约：重放命令首拍译码中心物理地址，后续仅递增地址；1016左边缘后转中心、中心末字后转1017右边缘。
// 重放坐标和行标签仍保留以检查归属和返回真实列，不增加RAM、读口或issue周期。
// 协议契约：主体真实行0..269用9位标签、前端行0..539用10位标签；比较时自然零扩展到外部接口，旧行拒绝语义不变。
// 协议契约：每个Body的中心范围在整个strip内固定，由上游行配置持有。
// 协议契约：范围一致性只在SIM_ASSERT检查；硬件保留真实行标签、提交位、X3覆盖检查及物理地址检查。
// C 片独占一份 1024×256 RAM：前端 C16 两行、主体四个 residual 双行环及跨 Body 重放。
// 主体中心区占 0..1015；1016/1017 是共享左右边缘字；空闲地址仅按下述IO队列契约使用。
// 主体与前端写口都接收结果整理器已配好的 256 位字。
// 同步 RAM 的读结果带真实行列标签；重放输出允许回压，未接收时数据保持稳定。
// 前端偶行用低半区 0..479，奇行用高半区 512..991；请求返回整字及列号，由下游选半字。
// 每个新 strip 先单独拉高 strip_start 一个时钟沿，所有读写客户在该沿保持静止。
// IO队列复用前端480..511/992..1023、或已被Reduce完整消费的X4行槽前64字；不得覆盖活跃行。
// IO写共用既有fw_data/wr_data整字总线，不增加独立宽选择；调度保证与计算写互斥。
// IO与模型共用单逻辑读口及原生RAM输出保持；模型读优先，切换残差阶段前IO必须排空。
module ngm_bank_ctrl_c #(                                   // C 片控制器
    parameter int unsigned ROW_W = 11,                       // 行号位宽
    parameter int unsigned COL_W = 11                        // 列号位宽
) (                                                         // 接口开始
    input logic io_rgb_mode, // RGB queue words retain all43 defined bits; capture the read type.
    input logic clk,                                          // 时钟
    input logic reset,                                        // 同步复位
    input logic cfg_front,                                    // 1 为前端相位
    input logic strip_start,                                  // 新 strip 开始，清主体所有行标签
    input logic io_wr_valid,output logic io_wr_ready, // 已分配空闲字的队列写，数据使用fw_data或wr_data。
    input logic [9:0] io_wr_addr, // 队列物理写地址，合法生命周期由顶层负责。
    input logic io_rd_valid,output logic io_rd_ready, // 队列原字读，共用既有逻辑读口。
    input logic [9:0] io_rd_addr, // 队列物理读地址。
    output logic io_rsp_valid,input logic io_rsp_ready, // 队列返回保持到实际消费。
    output logic [255:0] io_rsp_word, // 直接引出原生RAM返回，不另存整字。
    input logic wr_valid,                                     // 主体整字写请求
    output logic wr_ready,                                    // 主体整字写可收
    input logic [1:0] wr_body,                                // 写入 X0/X1/X2/X3 槽
    input logic [ROW_W-1:0] wr_row,                            // 主体真实行号
    input logic [COL_W-1:0] wr_x,                              // 主体真实列号
    input logic [COL_W-1:0] wr_center_lo,                      // 中心半开区间起点
    input logic [COL_W-1:0] wr_center_hi,                      // 中心半开区间终点
    input logic [255:0] wr_data,                               // 已整理好的 C32 字
    input logic wr_begin,                                     // 主体行第一个字
    input logic wr_complete,                                  // 主体行最后一个字
    input logic wr_preserve,                                  // V3 原位覆盖 X3 为 X4
    input logic fw_valid,                                     // 前端 C16 偶奇像素整字写请求。
    output logic fw_ready,                                    // 前端整字写可收。
    input logic [ROW_W-1:0] fw_row,                            // 前端真实行号
    input logic [COL_W-1:0] fw_col,                            // 前端真实列号
    input logic [255:0] fw_data,                               // 前端偶列低半与奇列高半的整字。
    input logic fw_begin,                                     // 前端行首整字。
    input logic fw_complete,                                  // 前端行末整字。
    input logic rd_valid,                                     // 单字读请求
    output logic rd_ready,                                    // 单字读可收
    input logic [1:0] rd_kind,                                // 0 residual、1 Tail、2 前端
    input logic [1:0] rd_body,                                // residual 的 Xb 编号
    input logic [ROW_W-1:0] rd_row,                            // 读请求真实行号
    input logic [COL_W-1:0] rd_x,                              // 读请求真实列号
    input logic [COL_W-1:0] rd_center_lo,                      // 读请求中心起点
    input logic [COL_W-1:0] rd_center_hi,                      // 读请求中心终点
    output logic rsp_valid,                                   // 返回数据有效
    input logic rsp_ready,                                    // 返回数据被接收
    output logic [1:0] rsp_kind,                              // 返回类型；3 为重放
    output logic [ROW_W-1:0] rsp_row,                          // 返回真实行号
    output logic [COL_W-1:0] rsp_x,                            // 返回真实列号
    output logic [255:0] rsp_word,                             // 返回整字；前端按列奇偶选半
    input logic replay_start,                                 // 启动下一 Body 的 H 行重放
    output logic replay_start_ready,                          // 重放命令可收
    input logic [1:0] replay_body,                             // 目标 X1/X2/X3
    input logic [ROW_W-1:0] replay_row,                         // 重放真实行号
    input logic [COL_W-1:0] replay_center_lo,                  // 中心区起点
    input logic [COL_W-1:0] replay_center_hi,                  // 中心区终点
    input logic [COL_W-1:0] replay_x_lo,                       // 实际读取首列
    input logic [COL_W-1:0] replay_x_hi,                       // 实际读取尾界
    output logic replay_busy,                                 // 重放进行中
    output logic replay_done,                                 // 最后一个字被接收
    output logic protocol_error                               // 错误锁存至复位
);                                                          // 接口结束
    function automatic logic [9:0] base(input logic [1:0] b, input logic p); // 主体区域基址
        case (b)                                              // 四个主体区域
            2'd0: base = p ? 10'd508 : 10'd0;                 // X0 区域
            2'd1: base = p ? 10'd638 : 10'd130;               // X1 区域
            2'd2: base = p ? 10'd766 : 10'd258;               // X2 区域
            default: base = p ? 10'd892 : 10'd384;            // X3 与原位 X4 区域
        endcase                                               // 区域选择结束
    endfunction                                               // 基址函数结束
    function automatic logic [8:0] width(input logic [1:0] b); // 主体最大中心宽度
        case (b)                                              // 固定 T=120 的宽度
            2'd0: width = 9'd130;                             // X0 宽度
            2'd1: width = 9'd128;                             // X1 宽度
            2'd2: width = 9'd126;                             // X2 宽度
            default: width = 9'd124;                          // X3/X4 宽度
        endcase                                               // 宽度选择结束
    endfunction                                               // 宽度函数结束
    function automatic logic [9:0] center_addr(              // 真实坐标至中心地址
        input logic [1:0] b, input logic [ROW_W-1:0] r, // 地址函数的输入参数
        input logic [COL_W-1:0] lo, input logic [COL_W-1:0] x // 地址函数的输入参数
    );                                                        // 参数结束
        logic [9:0] region_base, column, neg_origin;
        logic [9:0] carry_bits;
        region_base = base(b, r[0]);
        column = 10'(x);
        neg_origin = ~10'(lo);
        // Carry-save forms base + x - lo modulo 1024 with one carry chain.
        carry_bits = (region_base & column) | (region_base & neg_origin) |
                     (column & neg_origin);
        center_addr = (region_base ^ column ^ neg_origin) + {carry_bits[8:0],1'b1};
    endfunction                                               // 中心地址函数结束
    function automatic logic [9:0] front_addr(               // 前端两行按奇偶分半区
        input logic [ROW_W-1:0] r, input logic [COL_W-1:0] x // 地址函数的输入参数
    );                                                        // 参数结束
        front_addr = (r[0] ? 10'd512 : 10'd0) + 10'(x >> 1);  // 每行至多 480 字
    endfunction                                               // 前端地址函数结束

    logic [1:0] ram_rd_valid, ram_wr_valid;                    // 两半区读写使能
    logic [8:0] ram_rd_idx [2], ram_wr_idx [2];                // 两半区局部地址
    logic [255:0] ram_rd_data [2], ram_wr_data [2];            // 两半区整字数据
    logic [255:0] ram_wr_word;                                 // 前端与主体共用一条整字写数据总线
    wire [223:0] compact_read[2], compact_write[2];
    wire [223:0] compact_feature;
    wire [223:0] compact_write_legacy;
    logic rgb_return_q;
    ngm_act_ram #(.WORD_W(224),.BLK_N(12)) u_act_ram (                                   // 唯一的 C 片 RAM
        .clk(clk), .reset(reset),                             // 时钟复位
        .rd_valid(ram_rd_valid), .rd_idx(ram_rd_idx), .rd_data(compact_read), // RAM 读口
        .wr_valid(ram_wr_valid), .wr_idx(ram_wr_idx), .wr_data(compact_write)  // RAM 写口
    );                                                        // RAM 例化结束

    logic row_valid_q [4][2], tail_valid_q [2];               // 主体行与 X4 提交标记
    logic [8:0] row_tag_q [4][2];                        // 主体真实行号标签
`ifdef SIM_ASSERT // 只供范围契约检查，不占硬件存储。
    logic [COL_W-1:0] lo_tag_q [4], hi_tag_q [4];               // 每个 Body 在同一 strip 内共用中心范围
`endif // 范围影子状态结束。
`ifdef SIM_ASSERT // 只供范围契约检查，不占硬件存储。
    logic range_valid_q [4];                                  // 各 Body 的 strip 范围已锁定
`endif // 范围影子状态结束。
    logic front_valid_q [2];                                  // 前端已提交行标记
    logic [9:0] front_row_q [2];                         // 前端真实行号标签
    logic edge_valid_q, edge_left_q, edge_right_q;            // 共享边缘归属和有效位
    logic [1:0] edge_body_q;                                  // 共享边缘 Xb 标签
    logic [8:0] edge_row_q;                              // 共享边缘真实行号
`ifdef SIM_ASSERT // 只供范围契约检查，不占硬件存储。
    logic [COL_W-1:0] edge_lo_q, edge_hi_q;                    // 共享边缘中心范围
`endif // 范围影子状态结束。
    logic wr_active_q, wr_preserve_q;                          // 主体写行状态
    logic [1:0] wr_body_q;                                    // 主体写行 Xb
    logic [8:0] wr_row_q;                                // 主体写行真实行号
    logic [COL_W-1:0] wr_next_q;             // 主体写行范围与下一列
    logic fw_active_q, cfg_front_q;                            // 前端写行与相位状态。
    logic [9:0] fw_row_q;                                // 当前前端写行号
    logic replay_busy_q;                                      // 重放状态
    logic [1:0] replay_body_q, replay_gap_q;                  // 重放目标及四拍节奏
    logic [8:0] replay_row_q;                            // 重放真实行号
    logic [COL_W-1:0] replay_lo_q, replay_hi_q;                // 重放中心范围
    logic [COL_W-1:0] replay_x_q, replay_end_q;                // 重放下一列与尾界
    logic rsp_valid_q;                                        // 返回有效寄存器
    logic [1:0] rsp_kind_q;                                   // 返回类型寄存器
    logic [ROW_W-1:0] rsp_row_q;                               // 返回行号寄存器
    logic [COL_W-1:0] rsp_x_q;                                 // 返回列号寄存器
    logic [9:0] replay_phys_q; // 重放物理字计数器，与坐标计数器同行推进。
    logic [9:0] held_rd_addr_q;                               // RAM 读口保持地址
    logic front_enter;                                        // 前端相位切入指示。
    logic wr_is_center, wr_is_left, wr_is_right, wr_map_ok;   // 主体写坐标类别
    logic [9:0] wr_addr, fw_addr, rd_addr, replay_addr;       // 各客户候选地址
    logic wr_context_ok, wr_sequence_ok, wr_tag_ok, wr_last_ok, wr_range_ok; // 主体写协议检查
    logic rd_tag_ok, rd_map_ok, front_tag_ok;                  // 单字读协议检查
    logic body3_skip_live;                                    // X3 residual 尚未被 X4 覆盖
    logic replay_tag_ok, replay_start_ok, replay_x_ok;       // 重放协议检查
    logic rd_fire, replay_fire, ram_read_fire;                // 三种读握手
    logic [9:0] chosen_rd_addr;                               // 送往 RAM 的读地址
`ifdef SIM_ASSERT
    logic [9:0] old_chosen_rd_addr;                           // 旧译码式仿真影子，仅核对真实读事务。
`endif
    logic [1:0] chosen_kind;                                  // 读返回的类型标签
    logic [ROW_W-1:0] chosen_row;                              // 读返回的行标签
    logic [COL_W-1:0] chosen_x;                                // 读返回的列标签
    logic write_collision, body_write, front_write;           // 同址冲突及真正写使能

`ifdef SIM_ASSERT // 默认回归保留原范围校验语义。
    logic [COL_W-1:0] wr_lo_q,wr_hi_q; // 当前计算写行的仿真范围。
    wire geom_context = wr_center_lo == wr_lo_q && wr_center_hi == wr_hi_q; // 上游范围契约的影子比较。
    wire geom_range = !range_valid_q[wr_body] || (lo_tag_q[wr_body] == wr_center_lo && hi_tag_q[wr_body] == wr_center_hi); // 上游范围契约的影子比较。
    wire geom_preserve = lo_tag_q[3] == wr_center_lo && hi_tag_q[3] == wr_center_hi; // 上游范围契约的影子比较。
    wire geom_cover = wr_lo_q == rd_center_lo && wr_hi_q == rd_center_hi; // 上游范围契约的影子比较。
    wire geom_read = lo_tag_q[rd_body] == rd_center_lo && hi_tag_q[rd_body] == rd_center_hi; // 上游范围契约的影子比较。
    wire geom_replay = lo_tag_q[replay_body] == replay_center_lo && hi_tag_q[replay_body] == replay_center_hi; // 上游范围契约的影子比较。
    wire geom_edge = edge_lo_q == replay_center_lo && edge_hi_q == replay_center_hi; // 上游范围契约的影子比较。
`else // 合法固定调度不需要重复范围比较。
    wire geom_context = 1'b1; // 范围由上游行配置唯一持有。
    wire geom_range = 1'b1; // 范围由上游行配置唯一持有。
    wire geom_preserve = 1'b1; // 范围由上游行配置唯一持有。
    wire geom_cover = 1'b1; // 范围由上游行配置唯一持有。
    wire geom_read = 1'b1; // 范围由上游行配置唯一持有。
    wire geom_replay = 1'b1; // 范围由上游行配置唯一持有。
    wire geom_edge = 1'b1; // 范围由上游行配置唯一持有。
`endif // 范围校验选择结束。
    assign front_enter = cfg_front && !cfg_front_q;           // 刚进入前端相位
    assign fw_addr = front_addr(fw_row, fw_col);               // 配好整字后随附的奇列坐标是整字地址。
    assign wr_is_center = wr_x >= wr_center_lo && wr_x < wr_center_hi; // 中心区
    assign wr_is_left = wr_center_lo != 0 && wr_x == wr_center_lo - 1'b1; // 真实左边缘
    assign wr_is_right = wr_x == wr_center_hi;                 // 真实右边缘
    // Strip geometry is generated by the fixed clip_lo/clip_hi tables:
    // T=120, halos 5/4/3/2 give maximum center spans 130/128/126/124.
    // Check that immutable descriptor contract in simulation, rather than
    // subtracting both selected limits again on every read/write/replay.
    // Keep the per-transaction coordinate check and all ownership checks.
    assign wr_map_ok = wr_is_center || (wr_body != 0 && !wr_preserve &&
                                        (wr_is_left || wr_is_right));
    assign wr_addr = wr_is_left ? 10'd1016 :                   // 左边缘固定字
                     wr_is_right ? 10'd1017 :                  // 右边缘固定字
                     center_addr(wr_body, wr_row, wr_center_lo, wr_x); // 中心字
    // ================= 镜像写（body0）与计算写（body1..3）共用同一个写口 =================
    // 背景（后来人必读，别改回去）：C 片只有一个写口。X0 checkpoint 的镜像 DMA 要往 body0
    // （X0 区）写整行；Body 各层的 V 行要往 body1..3（X1..X3）写结果。旧实现用"整行独占"
    // 串起两者：镜像行持有 wr_active_q/wr_body_q/wr_row_q/wr_next_q，wrapper 再用 c_input_hold
    // 暂停计算结果。小图（X0 行只几个字）能过；720p 的 X0 行有 125 个中心字、要几百拍，
    // 必然横跨到下一个 V 行 ⇒ 结果被暂停 ⇒ 违反"结果无回压"契约（ROWSEQ result backpressure），
    // 并且镜像与整行重放互相等待成死锁。
    // 本改法把镜像写移出**计算写行上下文**，依据三条不变量（缺一不可）：
    //   1) 镜像行的**开始**必须等计算 C 写行结束——由 wrapper 的 c_dma_slot 保留 !c_row_compute：
    //      body0 的旧行标签在 wr_begin 会被置无效，若此刻 Body0.V 还在读 body0 残差，
    //      那些读会被 rd_tag_ok 拒掉，该行永远完不成。
    //   2) 镜像写**不占用** wr_active_q/wr_body_q/wr_row_q/wr_lo_q/wr_hi_q/wr_next_q——否则
    //      重放启动条件 !wr_active_q 会被镜像行长期按住；而重放目标只可能是 body1..3
    //      （见 ngm_addr_map 的 c_replay_body），与 body0 物理地址不相交，本可并行。
    //   3) body0 与 body1..3 的物理地址不相交（base() 各自独立），且镜像只写中心字、
    //      永不写共享边缘字 1016/1017（wr_map_ok 对 body0 只放中心）⇒ 两者不会同址覆盖。
    // 镜像自己的行首/行末语义（范围标签、行有效位、真实行号）仍在本模块内更新，见下面时序段。
    wire wr_dma_row = wr_body == 2'd0;                         // 本拍写的是镜像 X0 区（body0）
    assign wr_context_ok = wr_dma_row ||                       // 镜像写不要求计算写行上下文（不变量 2）
                           (wr_begin ? !wr_active_q :          // 首字不能嵌套写行
                           (wr_active_q && wr_body == wr_body_q && wr_row == wr_row_q && // 主体写入条件的续行
                            geom_context && // 主体写入条件的续行
                             wr_preserve == wr_preserve_q));   // 后续字上下文不变
    assign wr_range_ok = geom_range; // 后续行必须保持同一中心终点
    assign wr_sequence_ok = wr_dma_row ||                      // 镜像列序由 x0_dma 自己的计数器保证：
                                                               // wr_x = lo_q + dma_word，每接受一个高拍才 +1，
                                                               // 且 halo 字不发 C 写（c_dma_center 已过滤），
                                                               // 所以镜像行中心字天然严格连续，不需要占用
                                                               // 共享的 wr_next_q（那正是旧实现被搅乱的地方）。
                                                               // SIM_ASSERT 段另有一条影子检查替它证伪。
                             (wr_begin ?                   // 首列可为真实左边缘
                             (wr_x == ((wr_body != 0 && !wr_preserve && wr_center_lo != 0) ? // 主体写入条件的续行
                                       wr_center_lo - 1'b1 : wr_center_lo)) : // 主体写入条件的续行
                             (wr_x == wr_next_q));             // 其余列必须严格连续
    assign wr_tag_ok = !wr_preserve ||                         // X4 原位覆盖前 X3 必须已提交
                       (wr_body == 2'd3 && row_valid_q[3][wr_row[0]] && // 主体写入条件的续行
                        row_tag_q[3][wr_row[0]] == wr_row && // 主体写入条件的续行
                         geom_preserve); // X3 标签检查
    assign wr_last_ok = !wr_complete || // 主体写入条件的续行
                        (wr_x == wr_center_hi - 1'b1 || // 主体写入条件的续行
                         (wr_body != 0 && !wr_preserve && wr_is_right)); // 行尾只在中心末字或右边缘
    assign rd_addr = center_addr(rd_body, rd_row, rd_center_lo, rd_x); // 主体中心读地址
    assign rd_map_ok = rd_x >= rd_center_lo && rd_x < rd_center_hi; // 主体读不能取边缘
    assign body3_skip_live = (rd_kind != 2'd0 || rd_body != 2'd3) || // 非 X3 residual 不受此门控
                             (!tail_valid_q[rd_row[0]] && // X4 完整提交后整行 X3 都失效
                              !(wr_active_q && wr_preserve_q && wr_body_q == 2'd3 && // X4 正在原位覆盖
                                wr_row_q == rd_row && geom_cover && rd_x < wr_next_q)); // 已覆盖的 X3 列不得再读
    assign rd_tag_ok = row_valid_q[rd_body][rd_row[0]] && // 主体或前端读取条件的续行
                       row_tag_q[rd_body][rd_row[0]] == rd_row && // 主体或前端读取条件的续行
                        geom_read && // 主体或前端读取条件的续行
                       (rd_kind != 2'd1 || (rd_body == 2'd3 && tail_valid_q[rd_row[0]])) && // Tail 要完整 X4
                       body3_skip_live;                      // 读行归属及 X3 生命周期
    assign front_tag_ok = front_valid_q[rd_row[0]] && // 主体或前端读取条件的续行
                          front_row_q[rd_row[0]] == rd_row && rd_x < COL_W'(960); // 前端行归属
    assign replay_tag_ok = row_valid_q[replay_body][replay_row[0]] && // 重放行与边缘归属校验的续行
                           row_tag_q[replay_body][replay_row[0]] == replay_row && // 重放行与边缘归属校验的续行
                            geom_replay && // 重放行与边缘归属校验的续行
                           (replay_x_lo >= replay_center_lo && replay_x_hi <= replay_center_hi || // 重放行与边缘归属校验的续行
                            (edge_valid_q && edge_body_q == replay_body && // 重放行与边缘归属校验的续行
                             edge_row_q == replay_row && geom_edge && // 重放行与边缘归属校验的续行
                             (replay_x_lo >= replay_center_lo || edge_left_q) && // 重放行与边缘归属校验的续行
                             (replay_x_hi <= replay_center_hi || edge_right_q))); // 中心及所需边缘
    assign replay_start_ok = replay_body != 0 && // 重放范围及地址选择的续行
                             replay_x_hi > replay_x_lo && // 重放范围及地址选择的续行
                             replay_x_lo >= ((replay_center_lo == 0) ? replay_center_lo : replay_center_lo - 1'b1) && // 重放范围及地址选择的续行
                             replay_x_hi <= replay_center_hi + 1'b1 && replay_tag_ok; // 命令整体合法
    assign replay_x_ok = (replay_x_q >= replay_lo_q && replay_x_q < replay_hi_q) || // 重放范围及地址选择的续行
                         (replay_lo_q != 0 && replay_x_q == replay_lo_q - 1'b1) || // 重放范围及地址选择的续行
                         replay_x_q == replay_hi_q;         // 当前向量在合法区间
    assign replay_addr=replay_phys_q; // 读拍不再重复做真实列减基址再加区域地址。

    always_ff @(posedge clk)begin // 地址表在命令接收拍计算一次，稳态只用递增器。
        if(reset || strip_start)replay_phys_q<=0; // 无活动重放。
        else if(replay_start && replay_start_ready && replay_start_ok)begin // 与正式重放坐标装载同一授权。
            replay_phys_q<=replay_x_lo<replay_center_lo ? 10'd1016 : replay_x_lo==replay_center_hi ? 10'd1017 : center_addr(replay_body,replay_row,replay_center_lo,replay_x_lo); // 首字可能在左边缘。
        end else if(replay_fire)begin // 只有真实读发生才推进，不受回压影响。
            if(replay_x_q<replay_lo_q)replay_phys_q<=base(replay_body_q,replay_row_q[0]); // 左边缘后回到中心首字。
            else if(replay_x_q==replay_hi_q-1'b1)replay_phys_q<=10'd1017; // 中心最后字之后才读右边缘。
            else replay_phys_q<=replay_phys_q+1'b1; // 中心内地址连续。
        end // 命令和读计数更新结束。
    end // 重放物理计数结束。
    logic rsp_io_q; // 当前原生返回归属IO还是模型，仅一位标签。
    wire return_ready=rsp_io_q ? io_rsp_ready : rsp_ready; // 原生输出只属于一个读客户。
    wire io_read=io_rd_valid && io_rd_ready; // 队列读实际发起。
    wire io_write=io_wr_valid && io_wr_ready; // 队列写实际发起。
    assign io_rsp_valid=rsp_valid_q && rsp_io_q; // 不把队列字冒充激活读返回。
    for (genvar channel=0; channel<32; channel++) begin : g_a7_feature
        assign compact_feature[channel*7+:7] = ram_wr_word[channel*8+:7];
`ifdef SIM_ASSERT
        always @(posedge clk) if (!reset && (|ram_wr_valid) && !(io_write && io_rgb_mode) && ram_wr_word[channel*8+7])
            $fatal(1,"C compact storage received a negative feature");
`endif
    end
`ifdef SIM_ASSERT
    always @(posedge clk) if(!reset && (|ram_wr_valid) && io_rgb_mode && !io_write)
        $fatal(1,"C RGB RAM write must be an accepted output-queue IO write");
`endif
    assign compact_write_legacy = io_write && io_rgb_mode ? ram_wr_word[223:0] : compact_feature;
`ifdef SIM_ASSERT
    integer c_rgb_defined_bits_compared=0,c_feature_bits_compared=0;
    always @(posedge clk) if(!reset && (|ram_wr_valid)) begin
        if(io_rgb_mode) c_rgb_defined_bits_compared=c_rgb_defined_bits_compared+43;
        else c_feature_bits_compared=c_feature_bits_compared+224;
    end
    final $display("C_RAM_FORMAT_COMPARE rgb_defined_bits=%0d feature_bits=%0d",c_rgb_defined_bits_compared,c_feature_bits_compared);
`endif
    for (genvar group_id=0; group_id<2; group_id++) begin : g_a7_group
        assign compact_write[group_id] = io_rgb_mode ? ram_wr_word[223:0] : compact_feature;
`ifdef SIM_ASSERT
        always @(posedge clk) if(!reset && ram_wr_valid[group_id]) begin
            if(io_rgb_mode) begin
                if(compact_write[group_id][42:0] !== compact_write_legacy[42:0]) $fatal(1,"C RGB compact write differs from legacy defined bits");
            end else if(compact_write[group_id] !== compact_write_legacy) $fatal(1,"C feature compact write differs from legacy word");
        end
`endif
        for (genvar channel=0; channel<32; channel++) begin : g_channel
            assign ram_rd_data[group_id][channel*8+:8] = {1'b0,compact_read[group_id][channel*7+:7]};
        end
    end
    always_ff @(posedge clk) begin
        if (reset || strip_start) rgb_return_q <= 0;
        else if (ram_read_fire) rgb_return_q <= io_read && io_rgb_mode;
    end
    assign io_rsp_word=rgb_return_q ? {213'd0,compact_read[held_rd_addr_q[9]][42:0]} : ram_rd_data[held_rd_addr_q[9]]; // 与既有返回共用原生输出。
    assign io_rd_ready=!strip_start && !replay_busy_q && !replay_start && !rd_valid && (!rsp_valid_q || return_ready); // 模型读优先，保持时只等其归属客户。
    assign io_wr_ready=!strip_start && !replay_busy_q && !wr_valid && !fw_valid; // 正常写优先，合法队列布局不与同址读冲突。
    assign rsp_valid = rsp_valid_q && !rsp_io_q; // 模型返回有效位。
    assign rsp_kind = rsp_kind_q;                              // 返回读客户
    assign rsp_row = rsp_row_q;                                // 返回真实行号
    assign rsp_x = rsp_x_q;                                    // 返回真实列号
    assign rsp_word = ram_rd_data[held_rd_addr_q[9]];          // 读地址在回压期间保持
    assign replay_busy = replay_busy_q;                       // 重放忙状态
    assign rd_ready = !strip_start && !replay_busy_q && !replay_start && // 读写握手与冲突判定的续行
                      (!rsp_valid_q || return_ready); // 读口可连续吞吐，IO原生保持期间不能偷换地址。
    assign replay_start_ready = !cfg_front && !strip_start && !replay_busy_q && // 读写握手与冲突判定的续行
                                !rsp_valid_q && !rd_valid && !wr_active_q; // 整行切换点
    assign rd_fire = rd_valid && rd_ready && !strip_start && // 读写握手与冲突判定的续行
                     (cfg_front ? (rd_kind == 2'd2 && front_tag_ok) : // 读写握手与冲突判定的续行
                      ((rd_kind == 2'd0 || rd_kind == 2'd1) && rd_map_ok && rd_tag_ok)); // 合法单字读
    assign replay_fire = replay_busy_q && replay_gap_q == 0 && // 读写握手与冲突判定的续行
                         replay_x_q < replay_end_q && // 读写握手与冲突判定的续行
                         (!rsp_valid_q || return_ready) && replay_x_ok; // 按四拍节奏重放。
    assign ram_read_fire = rd_fire || replay_fire || io_read; // 共享单逻辑读口，不增加读口或数据暂存。
    // 预选读地址：重放忙时固定重放地址；否则由请求有效选模型地址或 IO 地址。
    // IO read 只会在 !replay_busy_q && !rd_valid 时发生，rd_fire 只会在 !replay_busy_q，
    // replay_fire 只会在 replay_busy_q。故每个真实读事务仍选择原地址；RE=0 时 RAM 原生保持。
    assign chosen_rd_addr = replay_busy_q ? replay_addr : rd_valid ?
                            (cfg_front ? front_addr(rd_row, rd_x) : rd_addr) : io_rd_addr;
`ifdef SIM_ASSERT
    // 旧选择式作逐事务影子证明；RE 必须由 ram_read_fire 控制，不能常开，否则地址预选会改写返回数据。
    assign old_chosen_rd_addr = io_read ? io_rd_addr : replay_fire ? replay_addr :
                                cfg_front ? front_addr(rd_row, rd_x) : rd_addr;
    always @(posedge clk) if (!reset && ram_read_fire) begin
        if (chosen_rd_addr !== old_chosen_rd_addr)
            $fatal(1, "BANK_C preselected read address differs on accepted RAM read");
        if (ram_rd_idx[chosen_rd_addr[9]] !== old_chosen_rd_addr[8:0])
            $fatal(1, "BANK_C preselected local index differs on accepted RAM read");
    end
`endif
    assign chosen_kind = replay_fire ? 2'd3 : rd_kind;        // 返回类型
    assign chosen_row = replay_fire ? replay_row_q : rd_row;  // 返回行号
    assign chosen_x = replay_fire ? replay_x_q : rd_x;        // 返回列号
    wire [9:0] write_check_addr=cfg_front ? fw_addr : wr_addr; // 两种写相位互斥，碰撞比较共用一个地址。
    wire write_check_valid=cfg_front ? fw_valid : wr_valid; // 仅真实写请求参与碰撞检查。
    wire same_io=write_check_addr==io_rd_addr; // IO地址比较与读授权并行。
    // 碰撞契约：同一Body中心范围在strip内固定；中心区域彼此不重叠，模型单字读不访问共享边缘。
    wire same_front=fw_row[0]==rd_row[0] && (fw_col>>1)==(rd_x>>1); // 前端同parity同像素对就是同一原字。
    wire same_body=wr_is_center && wr_body==rd_body && wr_row[0]==rd_row[0] && wr_x==rd_x; // 直接比较中心逻辑坐标，删除先减基址再加物理基址的串行路径。
    wire same_model=cfg_front ? same_front : same_body; // 只在模型读已合法发起时使用；IO仍比较完整物理地址。
`ifdef SIM_ASSERT // 以旧物理地址等式证明固定范围契约下的新判断等价。
    always @(posedge clk)if(!reset && write_check_valid && rd_fire && (cfg_front || wr_map_ok))begin // 非法写由既有协议检查拒绝，不用于简化关系。
        if(same_model!==(write_check_addr==(cfg_front ? front_addr(rd_row,rd_x) : rd_addr)))$fatal(1,"C collision logical/physical mismatch"); // 必须逐事务一致。
    end // 等价检查结束。
`endif // 仿真等价检查结束。
    assign write_collision=write_check_valid && (rd_valid ? same_model : io_rd_valid && same_io); // 模型请求优先于IO；同址待读请求即保留读优先权，不串接返回ready、标签检查和实际读握手。
    assign fw_ready = cfg_front && !strip_start && !replay_busy_q && !write_collision; // 前端写口状态
    assign wr_ready = !cfg_front && !strip_start && !replay_busy_q && !write_collision; // 主体写口状态
    assign front_write = fw_valid && fw_ready && fw_col[0] && fw_col < COL_W'(960) && // 前端合法奇列整字写。
                         !front_enter && (fw_begin ? !fw_active_q : fw_active_q && fw_row == fw_row_q); // 首字建行，其余字验行。
    assign body_write = wr_valid && wr_ready && wr_map_ok && // 读写握手与冲突判定的续行
                         wr_context_ok && wr_sequence_ok && wr_tag_ok && wr_last_ok && wr_range_ok; // 主体合法写
    assign ram_wr_word = cfg_front ? fw_data : wr_data;        // 两种相位互斥，先选一次整字数据。

    always_comb begin                                         // RAM 端口装配
        ram_rd_valid = 2'b00;                                 // 默认不发读
        ram_wr_valid = 2'b00;                                 // 默认不发写
        ram_rd_idx[0] = chosen_rd_addr[8:0];                  // 预选共享地址；RE=0 时 RAM 原生保持返回
        ram_rd_idx[1] = chosen_rd_addr[8:0];                  // 两个半区始终见同一局部地址
        ram_wr_idx[0] = fw_valid && cfg_front ? fw_addr[8:0] : wr_valid && !cfg_front ? wr_addr[8:0] : io_wr_addr[8:0]; // 地址按请求优先级预选，不再经过合法性和碰撞使能链。
        ram_wr_idx[1] = ram_wr_idx[0]; // 非写半区的地址无副作用，两个半区共用同一窄地址。                // 默认写地址
        ram_wr_data[0] = ram_wr_word; ram_wr_data[1] = ram_wr_word; // 两半区共用数据，仅写使能选择落点
        if (ram_read_fire) begin                              // 真正发送一个读
            ram_rd_valid[chosen_rd_addr[9]] = 1'b1;           // 选择物理半区
        end                                                   // RAM 读装配结束
        if (front_write) begin                                // 前端偶奇对写入
            ram_wr_valid[fw_addr[9]] = 1'b1;                   // 选择物理半区
        end else if (body_write) begin                        // 主体整字写入
            ram_wr_valid[wr_addr[9]] = 1'b1;                   // 选择物理半区
        end else if(io_write)begin // 输出队列只替换写地址，共用既有数据总线。
            ram_wr_valid[io_wr_addr[9]]=1;ram_wr_idx[io_wr_addr[9]]=io_wr_addr[8:0]; // 空闲物理字写入。
        end                                                   // RAM 写装配结束
    end                                                       // RAM 端口装配结束
    always_ff @(posedge clk) begin                            // 相位、行标签及读返回时序
        if (reset) begin                                      // 同步复位开始
            rsp_io_q<=0; // 初始无IO归属。
            cfg_front_q <= 1'b0;                              // 上一拍相位清零
            fw_active_q <= 1'b0;                              // 前端无正在写入行
            fw_row_q <= '0;                                   // 前端写行号清零
            wr_active_q <= 1'b0;                              // 主体无正在写入行
            wr_preserve_q <= 1'b0;                            // 原位覆盖标记清零
            wr_body_q <= '0;                                  // 主体写目标清零
            wr_row_q <= '0;                                   // 主体写行号清零
`ifdef SIM_ASSERT // 写行范围影子复位。
            wr_lo_q <= '0; wr_hi_q <= '0; // 不保存无效范围。
`endif // 影子复位结束。
            wr_next_q <= '0;    // 主体写列状态清零
            edge_valid_q <= 1'b0;                             // 共享边缘无归属
            edge_left_q <= 1'b0; edge_right_q <= 1'b0;       // 共享边缘两侧无效
            edge_body_q <= '0; edge_row_q <= '0;               // 共享边缘客户清零
`ifdef SIM_ASSERT // 只供范围契约检查，不占硬件存储。
            edge_lo_q <= '0; edge_hi_q <= '0;                  // 共享边缘范围清零
`endif // 范围影子状态结束。
            replay_busy_q <= 1'b0;                            // 重放空闲
            replay_body_q <= '0; replay_row_q <= '0;          // 重放目标清零
            replay_lo_q <= '0; replay_hi_q <= '0;             // 重放中心范围清零
            replay_x_q <= '0; replay_end_q <= '0;             // 重放列计数清零
            replay_gap_q <= '0;                               // 重放读间隔清零
            replay_done <= 1'b0;                              // 完成脉冲清零
            rsp_valid_q <= 1'b0;                              // 无待处理读返回
            rsp_kind_q <= '0; rsp_row_q <= '0; rsp_x_q <= '0; // 返回标签清零
            held_rd_addr_q <= '0;                             // RAM 读地址清零
            protocol_error <= 1'b0;                           // 错误锁存清零
            for (int unsigned b = 0; b < 4; b++) begin       // 遍历四个主体区域
`ifdef SIM_ASSERT // 只供范围契约检查，不占硬件存储。
                range_valid_q[b] <= 1'b0;                     // strip 范围初始未锁定
`endif // 范围影子状态结束。
`ifdef SIM_ASSERT // 只供范围契约检查，不占硬件存储。
                lo_tag_q[b] <= '0; hi_tag_q[b] <= '0;          // 每个 Body 的范围标签清零
`endif // 范围影子状态结束。
                for (int unsigned p = 0; p < 2; p++) begin   // 遍历两个行 parity
                    row_valid_q[b][p] <= 1'b0;               // 中心行初始无效
                    row_tag_q[b][p] <= '0;                    // 真实行标签清零
                end                                           // parity 遍历结束
            end                                               // Body 遍历结束
            for (int unsigned p = 0; p < 2; p++) begin       // 前端与 Tail 两槽
                front_valid_q[p] <= 1'b0;                     // 前端行初始无效
                front_row_q[p] <= '0;                         // 前端真实行标签清零
                tail_valid_q[p] <= 1'b0;                      // X4 行初始无效
            end                                               // 两槽遍历结束
        end else begin                                        // 正常运行开始
            cfg_front_q <= cfg_front;                         // 相位打一拍
            replay_done <= 1'b0;                              // 完成脉冲默认清零
            // A row number may be prepared while the row context is inactive.
            // Every consumer of wr_row_q is guarded by wr_active_q, so this can
            // settle before ready without changing memory writes or row ownership.
            // The actual row/tag/RAM updates below still require wr_valid&&wr_ready.
            if (wr_valid && !cfg_front && !strip_start && !wr_dma_row && wr_begin && !wr_active_q)
                wr_row_q <= wr_row;
            if (front_enter) begin                            // 切入前端相位
                fw_active_q <= 1'b0;                          // 旧写行状态失效
                front_valid_q[0] <= 1'b0;                     // 旧偶行失效
                front_valid_q[1] <= 1'b0;                     // 旧奇行失效
            end                                               // 前端切入结束
            if (fw_valid && fw_ready) begin                   // 前端一个已配好的整字被接受。
                if (!front_write) protocol_error <= 1'b1;    // 相位、坐标或行上下文非法。
                if (fw_begin && front_write) begin            // 首个整字建立当前真实行。
                    if (fw_col != COL_W'(1)) protocol_error <= 1'b1; // 首字对应原像素列零和一。
                    front_valid_q[fw_row[0]] <= 1'b0;         // 旧 parity 行先失效。
                    fw_active_q <= 1'b1;                      // 后续整字仍属于这一行。
                    fw_row_q <= fw_row;                        // 保存正在写的真实行号。
                end                                           // 首字状态结束。
                if (fw_complete && front_write) begin         // 最后一个整字提交完整行。
                    front_valid_q[fw_row[0]] <= 1'b1;         // 完整行可读。
                    front_row_q[fw_row[0]] <= fw_row;          // 保存真实行号。
                    fw_active_q <= 1'b0;                      // 行写入结束。
                end                                           // 整行提交结束。
            end                                               // 前端写入结束。
            if (wr_valid && wr_ready) begin                   // 主体一个整字被接受
                if (!body_write) protocol_error <= 1'b1;     // 非法写不得落 RAM
                else begin                                    // 合法主体写
                    if (!wr_dma_row) wr_next_q <= wr_x + 1'b1; // 只有计算行推进共享列序；镜像写不得搅乱它
                                                              // （镜像的列连续性靠 wr_dma_row 旁路 + 影子断言）
                    if (wr_begin) begin                       // 主体行开始
`ifdef SIM_ASSERT // 描述符范围锁定仅作为仿真影子状态。
                        if (!range_valid_q[wr_body]) begin    // 本 Body 首行建立 strip 范围（镜像与计算共用同一套范围标签）
                            range_valid_q[wr_body] <= 1'b1;  // 锁定本 strip 的范围
                            lo_tag_q[wr_body] <= wr_center_lo; // 保存中心起点
                            hi_tag_q[wr_body] <= wr_center_hi; // 保存中心终点
                        end                                   // 首行锁定结束
`endif // 综合不保存重复范围。
                        if (!wr_dma_row) begin                // 只有计算写行才占用写行上下文（不变量 2）
                        wr_active_q <= 1'b1;                  // 标记行写入中
                        wr_preserve_q <= wr_preserve;         // 保存原位覆盖模式
                        wr_body_q <= wr_body;                 // 保存目标区域
`ifdef SIM_ASSERT // 只供范围契约检查，不占硬件存储。
                        wr_lo_q <= wr_center_lo;              // 保存中心起点
`endif // 范围影子状态结束。
`ifdef SIM_ASSERT // 只供范围契约检查，不占硬件存储。
                        wr_hi_q <= wr_center_hi;              // 保存中心终点
`endif // 范围影子状态结束。
                        end                                   // 计算写行上下文更新结束
                        if (!wr_preserve) row_valid_q[wr_body][wr_row[0]] <= 1'b0; // 新行先使旧标签失效（镜像也必须做：Body0.V 的残差读靠这个标签判新旧）
                        if (wr_body == 2'd3) tail_valid_q[wr_row[0]] <= 1'b0; // X4 尚未完整
                        if (wr_body != 0 && !wr_preserve) begin // V0/1/2 更新共享边缘归属
                            edge_valid_q <= 1'b1;             // 共享边缘已有新归属
                            edge_body_q <= wr_body;           // 保存 Xb 标签
                            edge_row_q <= wr_row;             // 保存真实行号
`ifdef SIM_ASSERT // 只供范围契约检查，不占硬件存储。
                            edge_lo_q <= wr_center_lo;        // 保存中心起点
`endif // 范围影子状态结束。
`ifdef SIM_ASSERT // 只供范围契约检查，不占硬件存储。
                            edge_hi_q <= wr_center_hi;        // 保存中心终点
`endif // 范围影子状态结束。
                            edge_left_q <= 1'b0;             // 旧左边缘失效
                            edge_right_q <= 1'b0;            // 旧右边缘失效
                        end                                   // 边缘归属更新结束
                    end                                       // 主体行首结束
                    if (wr_is_left) edge_left_q <= 1'b1;     // 本次写入真实左边缘
                    if (wr_is_right) edge_right_q <= 1'b1;   // 本次写入真实右边缘
                    if (wr_complete) begin                    // 最后一字提交整行
                        if (!wr_dma_row) wr_active_q <= 1'b0; // 只有计算行才结束写行上下文（镜像行不受此位管理）
                        row_valid_q[wr_body][wr_row[0]] <= 1'b1; // 新中心行可读（镜像与计算都用它给读客户判新旧）
                        row_tag_q[wr_body][wr_row[0]] <= wr_row; // 保存真实行标签
                        if (wr_preserve) tail_valid_q[wr_row[0]] <= 1'b1; // X4 行可供 Tail
                    end                                       // 主体行提交结束
                end                                           // 合法主体写结束
            end                                               // 主体写入结束
            if (rd_valid && rd_ready && !rd_fire) protocol_error <= 1'b1; // 无效读请求
            if (replay_start && replay_start_ready) begin    // 重放命令被接受
                if (!replay_start_ok) protocol_error <= 1'b1; // 未提交或边缘归属异常
                else begin                                    // 合法重放开始
                    replay_busy_q <= 1'b1;                    // 重放进入忙状态
                    replay_body_q <= replay_body;             // 保存 Xb
                    replay_row_q <= replay_row;               // 保存真实行号
                    replay_lo_q <= replay_center_lo;          // 保存中心起点
                    replay_hi_q <= replay_center_hi;          // 保存中心终点
                    replay_x_q <= replay_x_lo;                // 设置首列
                    replay_end_q <= replay_x_hi;              // 保存尾界
                    replay_gap_q <= '0;                       // 首字可以立即预取
                end                                           // 合法重放命令结束
            end                                               // 重放命令处理结束
            if (replay_gap_q != 0) replay_gap_q <= replay_gap_q - 1'b1; // 四拍间隔计时
            if (ram_read_fire) begin                          // RAM 本拍收到一个读
                rsp_io_q<=io_read; // 与真实RAM读同拍保存归属。
                held_rd_addr_q <= chosen_rd_addr;             // 保存地址保证回压稳定
                rsp_valid_q <= 1'b1;                          // 下拍数据有效
                rsp_kind_q <= chosen_kind;                    // 锁存返回类型
                rsp_row_q <= chosen_row;                      // 锁存真实行号
                rsp_x_q <= chosen_x;                          // 锁存真实列号
                if (replay_fire) begin                        // 重放前进一步
                    replay_x_q <= replay_x_q + 1'b1;          // 下一真实列
                    replay_gap_q <= 2'd3;                    // 接下来隔三拍
                end                                           // 重放读推进结束
            end else if (rsp_valid_q && return_ready) begin // 归属客户实际消费且无新读。
                rsp_valid_q <= 1'b0;                          // 清返回有效位
            end                                               // RAM 读时序结束
            if (replay_busy_q && replay_x_q == replay_end_q && // strip 边界与完成条件的续行
                rsp_valid_q && rsp_ready && rsp_kind_q == 2'd3) begin // 最后重放字被接收
                replay_busy_q <= 1'b0;                        // 重放结束
                replay_done <= 1'b1;                          // 产生完成脉冲
            end                                               // 重放完成处理结束
            if (strip_start) begin                            // 每个新 strip 都清旧行归属
                if (cfg_front || wr_active_q || replay_busy_q || rsp_valid_q || rd_valid || wr_valid || fw_valid || io_rd_valid || io_wr_valid) // IO也必须在边界排空。
                    protocol_error <= 1'b1;                   // strip 边界必须静止
                wr_active_q <= 1'b0;                          // 清未完成主体写行
                replay_busy_q <= 1'b0;                        // 重放返回空闲
                rsp_valid_q <= 1'b0;                          // 不保留上一 strip 返回
                edge_valid_q <= 1'b0;                         // 共享边缘归属失效
                edge_left_q <= 1'b0;                          // 左边缘失效
                edge_right_q <= 1'b0;                         // 右边缘失效
                for (int unsigned b = 0; b < 4; b++) begin   // 四个主体区域
`ifdef SIM_ASSERT // 只供范围契约检查，不占硬件存储。
                    range_valid_q[b] <= 1'b0;                 // 新 strip 允许重新锁定范围
`endif // 范围影子状态结束。
                    for (int unsigned p = 0; p < 2; p++) begin // 两个行 parity
                        row_valid_q[b][p] <= 1'b0;           // 旧中心行不能跨 strip 使用
                    end                                       // parity 清理结束
                end                                           // Body 清理结束
                tail_valid_q[0] <= 1'b0;                      // X4 偶行失效
                tail_valid_q[1] <= 1'b0;                      // X4 奇行失效
            end                                               // 新 strip 处理结束
        end                                                   // 正常运行结束
    end                                                       // 时序过程结束
`ifdef SIM_ASSERT                                           // 仿真时把非法访问显式报错
    always @(posedge clk) if (!reset && !strip_start) begin
        if (wr_valid && !cfg_front &&
            (wr_center_hi<=wr_center_lo || wr_center_hi-wr_center_lo>width(wr_body)))
            $fatal(1,"BANK_C write descriptor exceeds fixed strip region");
        if (rd_valid && !cfg_front &&
            (rd_center_hi<=rd_center_lo || rd_center_hi-rd_center_lo>width(rd_body)))
            $fatal(1,"BANK_C read descriptor exceeds fixed strip region");
        if (replay_start &&
            (replay_center_hi<=replay_center_lo || replay_center_hi-replay_center_lo>width(replay_body)))
            $fatal(1,"BANK_C replay descriptor exceeds fixed strip region");
    end
    // 镜像写（body0）的两条影子检查。只在仿真存在，综合时整体剪掉，不占 XLR：
    //   · 列连续性：镜像已旁路共享 wr_next_q，这里用影子寄存器替它证伪；
    //   · 不变量 1：镜像绝不能在计算写行上下文活动期间写 C（wrapper 的 c_dma_slot 负责，此处证伪）。
    logic wr_dma_seen_q;                                      // 仿真影子：镜像行是否已经开始
    logic [COL_W-1:0] wr_dma_x_q;                             // 仿真影子：上一镜像写的列号
    always_ff @(posedge clk) begin                            // 镜像列序影子检查
        if (reset) begin wr_dma_seen_q <= 1'b0; wr_dma_x_q <= '0; end // 复位清影子
        else if (wr_valid && wr_ready && body_write && wr_dma_row) begin // 本拍真正落了一个镜像中心字
            if (wr_begin && wr_x != wr_center_lo) $fatal(1, "BANK_C dma row start column"); // 首字必须是中心起点
            if (!wr_begin && !(wr_dma_seen_q && wr_x == wr_dma_x_q + 1'b1)) $fatal(1, "BANK_C dma row gap"); // 其余字必须严格 +1
            wr_dma_seen_q <= 1'b1; wr_dma_x_q <= wr_x;         // 记录影子状态
        end                                                   // 镜像字结束
    end                                                       // 影子检查结束
    always_ff @(posedge clk) if (!reset && wr_dma_row && body_write && wr_active_q) // 计算写行上下文活动期间
        $fatal(1, "BANK_C dma write inside compute row");      // 镜像不得插进计算行（会覆盖 X1..X3 读标签语义）
    always_ff @(posedge clk) begin                            // RAM 与客户协议断言
        if (!reset) begin                                     // 复位期间不检查
            if (ram_rd_valid[0] && ram_wr_valid[0] && ram_rd_idx[0] == ram_wr_idx[0]) // 仿真协议断言的判定条件
                $fatal(1, "BANK_C low-half same-address read/write"); // 低半区同址冲突
            if (ram_rd_valid[1] && ram_wr_valid[1] && ram_rd_idx[1] == ram_wr_idx[1]) // 仿真协议断言的判定条件
                $fatal(1, "BANK_C high-half same-address read/write"); // 高半区同址冲突
            if (wr_valid && wr_ready && !body_write) // 仿真协议断言的判定条件
                $fatal(1, "BANK_C invalid Body write");    // 非法主体写被上游送入
            if (fw_valid && fw_ready && !front_write)         // 仿真协议断言的判定条件。
                $fatal(1, "BANK_C invalid frontend pair"); // 奇列缺少合法偶列
            if (rd_valid && rd_ready && !rd_fire) // 仿真协议断言的判定条件
                $fatal(1, "BANK_C uncommitted read");       // 未提交行不得读取
            if (replay_start && replay_start_ready && !replay_start_ok) // 仿真协议断言的判定条件
                $fatal(1, "BANK_C invalid replay");        // 旧行或错误 edge 不得重放
        end                                                   // 正常时钟检查结束
    end                                                       // 仿真断言结束
`endif                                                      // 综合时不例化断言
endmodule                                                    // C 片模块结束
