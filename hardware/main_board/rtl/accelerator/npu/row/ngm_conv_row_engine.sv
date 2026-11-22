/* OPTIMIZATION_NOTE_20261005
 * 行级错误逻辑约束（2026-10-05）：多个置1分支合成并行事件，sticky仍同拍置位并保持到reset。
 * 等价化简依赖row_boundary=pe_window_released&&(idx_q==pcnt_q)，及lut_step_q为2位。
 * 修改边界定义、RGB步数/计数位宽时须同步复核此处，不能仅修改上游后沿用!lut_step_q[1]。
 * 该改动用于缩短组合路径，不删异常覆盖、不延迟上报、不增加流水或缓存。
 * 详见 docs/OPTIMIZATION_CONSTRAINTS.md。
 */
// 协议契约：D的half出口固定Decoder-H组1 A口；其他D客户只使用各自物理整字或input出口，源字段无valid时不解释。
// 协议契约：Head/X0固定消费D组1，Down依返回行parity选组0/1，选择只在Down字节格位中存在。
// 协议契约：RGB每组仍查表三拍，后两拍各输出两个RGB565像素；接口高字节不消费。
// 协议契约：单套上下文预取与整行计算并行；row_busy保持至末组末issue采样沿，点间空闲不释放旧权重。
// 装填契约：load_layer随保持的行描述符；原生数据与load_valid同拍，不增加流水延迟。
// 横向重叠在u_tap_window内部通过SRL历史地址复用；行引擎不导出宽窗口用于回送。
// ============================================================================
// 行卷积引擎：吃一条特征行、吐一条特征行（前面/主体/尾部三种相位共用这一份实例）
//
// 它自己不做任何算术，只把三件现成部件接成一条流水线，并管三件事：
//   · 走位：把这一行的每个"组"（一组 = 几个相邻像素，按层是 1/4 个：head 和rgb都是4、
//     其余 15 层都是 1；本模型没有 2 这一档）依次摆给点引擎，
//     每组占 段数×批数 拍，组与组之间不停；
//   · 窗口轮换：抽头窗口是两块各 24 格，一块在算、一块在装。装数据的口写不进"正在算"的那块，
//     所以翻牌只有两个时机 —— 行内每**摆出**一组翻一次（与"被点引擎收下"同拍）、
//     空闲（行与行之间）每装好一组翻一次；不能挂在"算完一组"上，见下面窗口轮换那一节；
//   · 输出去向：前面 16 层的码带着行/列/批原样出去（给存储侧写回激活存储），
//     rgb 那一层的码先进 sigmoid 查表，出来的 12个像素字节分三拍发（每拍4个字节）。
//
// ------------------------------ 一行怎么走 ------------------------------
// 上一级把"开始这一行"和这一行的形状（通路、段数、批数、每组几个像素、一行几组）摆在同一个
// 拍上，本模块当拍就把形状转给点引擎、并把第 0 组也摆上去（点引擎同一拍收下这两样）。
// 之后每收走一组，列号前进"每组几个像素"，直到本行最后一组算完（window_released 且已经
// 摆完所有组），这一行结束、可以接下一行。
//
// **行与行之间可以一刀不空**：行起点在上一行末组的最后一刀那一拍就能被收下（点引擎允许层边界
// 在它最后一刀那一拍接收）。零空拍还要一个前提：**下一行第 0 组在这一行最后一组期间已经装完**
// —— 装它要 ceil(字数/2) 拍，而可用的窗口是这一行每组的拍数（段数×批数），所以条件是
// ceil(下一行字数/2) ≤ 本行每组拍数。不满足时（例如 1 拍/组的 enc 后面接要写 2 拍的 body）
// 只能在空闲期装，那时才留一小段。算帧周期按"每行 组数×每组拍数 + 0 或 1~2 拍"计。
//
// ------------------------ 存储侧要配合的两件事 ------------------------
// 1) 装填节奏：算第 k 组的时候装第 k+1 组（写口自己会写进"不在算"的那一块）。
//    截止时间 = 这一组的拍数（段数 × 批数）：
//      enc/dec/stem  1 拍/组 → 这一组 12 格 = 2 个字，**两个写口必须同拍各写一个字**
//      head          2 拍/组 → 16 格 = 2 个字
//      rgb/reduce    3 拍/组 → 21 格 / 8 格
//      body          4 拍/组 → 24 格 = 3 个字
//      down          6 拍/组 → 16 格 = 2 个字
// 2) 每装好一组就报一次"装好了"（fill_done，一拍脉冲）。本模块记着"已经装好的半区数 − 已经
//    摆出的组数"：只有它不为 0 才允许摆出下一组。上游晚一拍的结果是这一行停一拍再走
//    （点引擎本来就允许拍与拍之间有停顿），而不是把没装满的半区当成数据算出去。
//
// 3) 下一行第 0 组装在哪一拍拍都行，只要不早于"本行最后一组算完"：可以等本行结束后的空闲期
//    装（装好会翻牌），也可以就在本行最后一组发出最后一刀的同一拍装好（那一拍引擎已经不再用那个
//    半区了，翻牌不影响任何人，行与行之间还能少空一拍）。再早就不行 —— 末组还在算的时候把
//    下一行第 0 组写进去，翻牌会翻在错的时刻，自查会报出来。
//
// ------------------------------ 两个自查 ------------------------------
// protocol_error（一次拉高就一直保持到复位）：
//   · 点引擎自己报的错（换层太早、段数或批数给成 0、下游没按时收走结果）；
//   · 空闲期又来一次"装好了"（上游多装了一组，那组会被下一行的第 0 组挤掉）；
//   · 行内装的比用的还多（上游多装了一组）；
//   · rgb 的码来得比查表吃得还快（速率算错，会拼出错像素）。
// ============================================================================
module ngm_conv_row_engine #(  // 行卷积引擎：参数（窗口/阵列尺寸、行号宽度、查表的档数）
    parameter int unsigned WINDOW_CELLS = 24,      // 抽头窗口一个缓冲区的格数（与 ngm_tap_window 一致）
    parameter int unsigned CELL_BITS    = 32,      // 每格的位数（4 字节 = 4 个通道）
    parameter int unsigned WORD_CELLS   = 8,       // 一个写口一次写 8 格 = 256 位
    parameter int unsigned PORT_COUNT   = 2,       // 抽头窗口的写口数（每拍最多两个字）
    parameter int unsigned LANES        = 16,      // 阵列车道数（与点引擎一致）
    parameter int unsigned LANE_W       = LANES * 8,   // 一拍结果的位数：16 条车道 × 8 位
    parameter int unsigned BATCH_MAX    = 2,       // 批数上限（模型的 body/down 是 2）
    parameter int unsigned PG_W         = 3,       // "每组几个像素"的位宽（取值1/4，接口保留3位）
    parameter int unsigned PCNT_W       = 10,      // "一行几组"的位宽（H/2 域最多 960 组 → 10 位）
    parameter int unsigned ROW_W        = 11,      // 行号/列号位宽：Spec 上限 1920x1080 → 11 位（与点引擎一致）
    parameter int unsigned LUT_LANES    = 4,       // sigmoid 表一次查几个码
    parameter int unsigned LUT_STEPS    = 3,       // 12个码分三步喂完（4×3=12）
    parameter [1023:0]     LUT_INIT     = "sigmoid_u8.hex", // sigmoid 半表文件（必须传真实表）
    localparam int unsigned GROUP_W     = $clog2(WINDOW_CELLS / WORD_CELLS) // 写口的组号位宽（24/8 = 3 组 → 2 位）
) (                                            // 端口表开始
    input  logic                        clk,               // 时钟
    input  logic                        reset,             // 同步复位（高有效）

    // ---------------- 行起点：形状与行号在这一拍有效（valid/ready 握手，可一直拉到被收下）----------------
    input  logic                        row_start_valid,   // 上一级要开始一行
    output logic                        row_ready,         // 本模块可以接下一行（够数据 + 窗口空 + 点引擎闲）
    input  logic [2:0]                  cfg_kind,          // 通路编号（0=1×1、1=enc/dec、2=body、3=head、4=rgb）
    input  logic [1:0]                  cfg_slots,         // 段数（计数：1/2/3）
    input  logic [1:0]                  cfg_batches,       // 批数（计数：1/2）
    input  logic [PG_W-1:0]             cfg_point_group,   // 每组几个像素（1/4：head=4、rgb=4、其余=1）
    input  logic [PCNT_W-1:0]           cfg_point_count,   // 本行一共几组
    input logic [ROW_W-1:0] cfg_x_start, // 行首真实列；走位器直接计真实坐标，不在写回再加基址。
    input  logic [ROW_W-1:0]            cfg_row,           // 本行行号（跟着结果一起走）

    // ---------------- 抽头窗口的两个写口（存储侧直通进窗口）----------------
    input  logic [PORT_COUNT-1:0]       load_valid,        // 第 i 个写口这一拍要写
    input  logic [PORT_COUNT*GROUP_W-1:0] load_group,      // 第 i 个写口写进哪一组（一组 8 格）
    input logic [4:0] load_layer, // 装填所属固定模型层，在行开始前已经有效。
    input logic copy_window,right_reflect,head_padding, // 窄控制授权窗口内部复制或裁零。
    input logic [255:0] d_source_front_word, // Down组0原生并行像素。
    input logic [127:0] d_source_rgb_word, // D紧凑RGB源字。
    input logic [2:0] d_source_v_tags, // V窄物理槽标签。
    input logic [255:0] c_source_word,d_source_word, // C/D原生单字直接连到各格候选源。
    input logic c_source_odd, // Encoder-H读取原字的奇像素半字。
    input logic [127:0] d_source_half,stem_source_word, // Decoder-H半字与Stem输入。
    input logic [511:0] bank_source_word, // V/RGB原生两个抽头口，固定连到对应格位。
    input logic [PORT_COUNT*WORD_CELLS-1:0] load_cell_enable, // 窗口逐格写使能，正常整字装填全一。
    input logic [CELL_BITS/8-1:0] load_byte_enable, // Down分两行写入对应字节，其他层全一。
    input  logic                        fill_done,         // 一拍脉冲：往窗口里装的那一组已经写完了（不带半区信息）

    // ---------------- 给存储侧的两个状态（只报"什么时候"，不报"哪一半"）----------------
    output logic                        window_released,   // 本组最后一刀那一拍（上游据此推它自己的账）
    output logic                        row_boundary,      // 上面那一拍属于本行最后一组

    // ---------------- 权重流与残差码（直通点引擎）----------------
    input logic [2:0] weight_stream_slot, // 主表返回逻辑槽。
    input logic [5:0] weight_stream_pair, // 主表返回40位组。
    input logic weight_stream_param, // 参数标记。
    output wire weight_stream_ready, // 常驻槽回压。
    input  logic                        weight_stream_valid,   // 常驻槽的装载流有效
    input  logic [39:0]                 weight_stream_data,    // 常驻槽的装载流数据（每拍两个字）
    input  logic [BATCH_MAX*LANE_W-1:0] skip_codes,            // 逐批的残差半字（需要与结果同拍送入）

    // ---------------- 结果出口一：前面 16 层的码（带行/列/批）----------------
    input logic [ROW_W-1:0] emit_lo,emit_hi, // Stable for all points/results in this row.
    output wire code_in_range,
    output logic                        code_valid,        // 这一拍有一个结果码
    output logic [ROW_W-1:0]            code_row,          // 这个结果属于哪一行
    output logic [ROW_W-1:0]            code_x,            // 这个结果属于哪一组（本组第一个像素的列号）
    output wire residual_x_odd, // Encoder第八拍残差半字选择，独立于第九拍结果列号。
    output logic                        code_batch,        // 这个结果属于哪一批
    output logic [LANE_W-1:0]           code_lanes,        // 16 条车道的码

    // ---------------- 结果出口二：rgb 层的像素（已过 sigmoid）----------------
    output logic                        pixel_valid,       // 这一拍有 5 个像素
    output logic [ROW_W-1:0]            pixel_row,         // 这 5 个像素属于哪一行
    output logic [ROW_W-1:0]            pixel_x,           // 这一拍 5 个字节从哪个像素算起（本组第一个像素）
    output logic [1:0]                  pixel_beat,        // 这一拍是本组的第几拍（0/1/2，一组三拍）
    output logic [39:0]                 pixel_bytes,       // 5 个字节：第 i 个字节 = 本组第 5*beat+i 个字节

    output logic                        protocol_error     // 自查：上面四条里任意一条中了
);                                                                    // 端口表结束
    // ------------------------------ 推导常量 ------------------------------
    localparam int unsigned PIX_BYTES    = LUT_LANES * LUT_STEPS;      // 一个组出几个像素字节（5 × 3 = 15）
    localparam logic [2:0]  KIND_RGB     = 3'd4;                       // 通路编号 4 = rgb 层（唯一要查表的层）
    localparam int unsigned DRAIN_CYCLES = 9;                          // 结果比"最后一刀"晚 8 拍回来（原计算8拍+结果寄存1拍）

    // --------------------------- 点引擎的接口线 ---------------------------
    logic                    pe_layer_start_valid;   // 给点引擎的层边界（只在行起点那一拍拉高）
    logic                    pe_layer_start_ready;   // 点引擎说它可以收层边界（它空闲时才是 1）
    logic                    pe_point_valid;         // 给点引擎的点（一个组）
    logic                    pe_point_ready;         // 点引擎说这个点它收下了
    logic [ROW_W-1:0]        pe_point_row;           // 本点的行号
    logic [ROW_W-1:0]        pe_point_x;             // 本点的列号（本组第一个像素）
    logic [WINDOW_CELLS*CELL_BITS-1:0] window_cells; // 抽头窗口"正在算"的那一半（组合引出，768 位）
    logic                    pe_output_valid;        // 点引擎的结果有效（每个批次一拍）
    logic [ROW_W-1:0]        pe_output_row;          // 结果属于哪一行
    logic [ROW_W-1:0]        pe_output_x;            // 结果属于哪一组（本组第一个像素的列号）
    logic                    pe_output_batch;        // 结果属于哪一批
    logic [LANE_W-1:0]       pe_output_codes;        // 结果的 16 条车道码
    logic                    pe_window_released;     // 本组最后一个 issue 那一拍
    logic                    pe_protocol_error;      // 点引擎内部报的错
    logic                    pe_output_ready;        // 本设计不做背压：恒为 1，下游每拍都要收走

    // ------------------------------ 行状态 ------------------------------
    logic               row_busy_q;   // 1 = 这一行还没做完（从收起第 0 组到本行最后一组算完）
    logic [ROW_W-1:0]   row_q;        // 本行行号（行起点锁存，跟着结果走）
    logic [PG_W-1:0]    pg_q;         // 本行"每组几个像素"（行起点锁存）
    logic [PCNT_W-1:0]  pcnt_q;       // 本行一共几组（行起点锁存）
    logic [ROW_W-1:0]   x_q;          // 下一个要摆出的组的列号（本组第一个像素）
    logic [PCNT_W-1:0]  idx_q;        // 本行已经摆出几组（数到 pcnt_q 就没有了）
    logic               is_rgb_q;     // 1 = 正在飞的结果属于 rgb 层（决定走哪条出口）
    logic [3:0]         drain_q;      // 本行结果还有几拍才全部回来（0 = 没有结果在飞）
    wire role_swap; // 窗口内部版本标记按实际消费沿翻转，不重复保存全局角色。
    logic [1:0]         armed_q;      // 已经装好的半区数（0 = 下一组还摆不出去）

    // --------------------------- 组合出来的握手与判断 ---------------------------
    wire walk_more      = (idx_q < pcnt_q);                              // 本行还有组没摆出去
    wire point_take     = pe_point_valid && pe_point_ready;               // 这一拍有一个组被点引擎收走
    wire row_start_take = row_start_valid && row_ready;                   // 这一拍收下这一行的起点
    wire fill_ok_now    = (armed_q != 2'd0) || fill_done;                 // 半区够不够（当拍刚装好也算够）
    wire want_rgb       = (cfg_kind == KIND_RGB);                         // 来的这一行是不是 rgb 层
    wire rgb_switch     = (want_rgb != is_rgb_q);                         // 结果出口要不要换一条路
    wire drain_busy     = (drain_q != 4'd0);                              // 上一行的结果还没全部回来

    // --------------------------- 行起点与走位 ---------------------------
    assign row_ready = (!row_busy_q || row_boundary)                      // 上一行得做完（末组最后一刀那一拍算做完）
                     && fill_ok_now                                       // 下一行第 0 组的那一块得装好
                     && pe_layer_start_ready                              // 点引擎得闲（它在组与组之间会松一拍，所以还要看行忙）
                     && !(rgb_switch && (drain_busy || row_boundary));    // 换出口时，上一行的结果得全部回来
    assign pe_point_valid      = row_start_take ? 1'b1                    // 行起点那一拍：把第 0 组摆上（可与上一行末组同拍）
                                           : (row_busy_q ? (walk_more && fill_ok_now) : 1'b0); // 否则行内看还有没有组
    assign pe_point_row        = row_start_take ? cfg_row : row_q;        // 行起点那一拍用外部的行号，行内用锁存的
    assign pe_point_x          = row_start_take ? cfg_x_start : x_q;            // 行起点那一拍是本行真实首列，行内用走位器
    assign pe_layer_start_valid = row_start_take;                         // 层边界只在行起点那一拍拉一下
    assign pe_output_ready     = 1'b1;                                    // 结果永远当拍收走（点引擎会自查这一条）

    always_ff @(posedge clk) begin                                        // 行状态与走位器
        if (reset) begin                                                  // 复位：没有行在做
            row_busy_q <= 1'b0;                                           // 行不忙
            row_q      <= '0;                                             // 行号清零
            pg_q       <= '0;                                             // 每组像素数清零
            pcnt_q     <= '0;                                             // 一组都没有
            idx_q      <= '0;                                             // 摆出计数清零
            x_q        <= '0;                                             // 列号清零
        end else if (row_start_take) begin                                // 行起点：锁存形状、走位器摆到第 1 组
            row_busy_q <= 1'b1;                                           // 这一行开始（到本行最后一组算完才清）
            row_q      <= cfg_row;                                        // 记下本行行号
            pg_q       <= cfg_point_group;                                // 记下每组几个像素
            pcnt_q     <= (cfg_point_count == 0) ? PCNT_W'(1) : cfg_point_count; // 组数给 0 时当 1 处理（自查会报）
            idx_q      <= PCNT_W'(1);                                     // 第 0 组已经在同一拍摆出去了
            x_q        <= cfg_x_start+ROW_W'(cfg_point_group);                           // 下一组真实列=行首+每组像素数
        end else if (point_take) begin                                    // 收走一个组：列号前进一组、计数加一
            idx_q <= idx_q + 1'b1;                                        // 摆出的组数加一
            x_q   <= x_q + ROW_W'(pg_q);                                     // 列号前进"每组几个像素"
        end else if (row_boundary) begin                                  // 本行最后一组算完：这一行结束
            row_busy_q <= 1'b0;                                           // 行不忙了，可以接下一行
        end                                                               // 行状态分支结束
    end                                                                   // 行状态与走位器结束

    // --------------------------- 窗口轮换的两条规则 ---------------------------
    // 翻牌的意思是"把刚装满的那一半换成正在算的、原来在算的换成能装的"。它必须发生在
    // **某一组真正开始算**那一拍，而不是"上一组算完"那一拍 —— 平时这两件事同拍（算完一组
    // 的下一拍就开始下一组），但填充迟到时它们会分开：那时如果按"算完"就翻，等于把还没写的
    // 半区当成在算的，算出来就是上一组的数据。所以：
    //   · 空闲期（行还没开始）：每装好一组翻一次 —— 这时没有东西在算，翻完正好让刚装的那块去算；
    //   · 行内：每摆出去一组翻一次 —— 与"被点引擎收下"同拍，晚一点就开始算错。
    // 行内**不能**因为"装好了"就翻：装填本来就和计算重叠，一翻就把正在算的那块换掉了。
    //
    // 例外只有一个：**本行最后一组算出结果的同一拍**（row_boundary）收到"装好了"。这一装只能
    // 是下一行第 0 组（本行已经没有组要用它了），而这一拍也是本行最后一刀，翻牌不会影响任何人
    // （下一拍引擎就是空闲的）。如果不在这里翻，这次"装好了"就白装：下一行第 0 组会在
    // row_busy_q 仍为 1 的那一拍进来，两个分支都不翻，新行就会拿错半区算，而且一声不响。
    assign role_swap=!reset && ((fill_done && (!row_busy_q || row_boundary)) || (point_take && row_busy_q)); // 沿用原翻转条件，寄存读版本由窗口内部更新。

    // 富余计数：每装好一组加一、每摆出去一组减一。它就是"已经装好的半区数 − 已经摆出的组数"，
    // 也就是"往后还有几个能直接用的半区"。为什么要减在"摆出"而不是"算完"：摆出第 m 组的前提是
    // 前面已经装好了 m+1 组（第 0 组靠空闲期那一装，之后每组靠它前一组在算的时候那一装），
    // 所以判据是"装好的 > 已经摆出的"，减的时机必须与"摆出"同拍。若上游某一次装晚了，
    // 这个计数就停在 0，下一组摆不出去（引擎停一拍等），而不是拿没装满的半区去算。
    // 饱和在 3：真出错时由自查报出来，不让它回绕。
    always_ff @(posedge clk) begin                                        // 填充富余计数
        if (reset) armed_q <= 2'd0;                                       // 复位后一组都没装好
        else if (fill_done && !point_take) begin                          // 只是装好（没同时摆出一组）
            if (armed_q != 2'd3) armed_q <= armed_q + 1'b1;                // 加一，饱和在 3
        end else if (point_take && !fill_done) begin                      // 只是摆出一组（没同时装好）
            if (armed_q != 2'd0) armed_q <= armed_q - 1'b1;                // 减一，到底就不再减
        end                                                               // 同拍一进一出时两个分支都不走，计数不变
    end                                                                   // 填充富余计数结束

    assign window_released = pe_window_released;                          // 本组最后一刀那一拍
    assign row_boundary    = pe_window_released && (idx_q == pcnt_q);      // 这一拍属于本行最后一组

    // --------------------------- 结果出口的选择 ---------------------------
    always_ff @(posedge clk) begin                                        // 结果出口选择寄存器
        if (reset) is_rgb_q <= 1'b0;                                      // 复位后按"非 rgb"算
        else if (row_start_take) is_rgb_q <= want_rgb;                    // 行起点决定这一行的结果走哪条出口
    end                                                                   // 结果出口选择寄存器结束

    always_ff @(posedge clk) begin                                        // 结果清空倒计时
        if (reset) drain_q <= 4'd0;                                       // 复位后没有结果在飞
        else if (row_boundary) drain_q <= 4'(DRAIN_CYCLES);               // 本行最后一组issue后还要9拍结果才回来
        else if (drain_q != 4'd0) drain_q <= drain_q - 1'b1;              // 每拍减一，减到 0 就是全回来了
    end                                                                   // 结果清空倒计时结束

    // --------------------------- 出口一：前面 16 层的码 ---------------------------
    wire pe_output_in_range;
    assign code_in_range = pe_output_in_range;
    assign code_valid = pe_output_valid && !is_rgb_q;                     // 非 rgb 的层：码带标签原样出去
    assign code_row   = pe_output_row;                                    // 行号照搬
    assign code_x     = pe_output_x;                                      // 列号照搬（本组第一个像素）
    assign code_batch = pe_output_batch;                                  // 批号照搬
    assign code_lanes = pe_output_codes;                                  // 16 条车道的码照搬

    // --------------------------- 出口二：rgb 的查表（一组三拍、每拍4个字节） ---------------------------
    // 一份码里有 15 个有用码（5 个像素 × 3 通道；车道的排法就是"点优先"：车道 L = 点 L/3、通道 L%3），
    // 表一次只查 5 个，所以把这份码分三步喂进去，三步各出 5 个字节、各发一拍。
    // **不攒成 15 字节一拍**：攒就要一个 120 位的拼接寄存器，而下游本来就在按字节顺序写输出行，
    // 5 字节一拍连发三拍它更好接 —— 省下 120 个触发器，代价只是下游要知道"一组三拍"。
    //
    // 这一段有四条错开的流水，各自记各自的账，别混：
    //   收下码（第 X 拍）→ 喂三步（X+1 / X+2 / X+3）→ 出三拍字节（X+2 / X+3 / X+4）
    // 所以：码暂存只存有用的 15 条车道；行/列标签延迟两拍就正好对上第一拍（三拍同一份标签，
    // 因为相邻两份码相隔三拍）；"本组第几拍"用一个从"收码延迟两拍"起算的计数器给。
    logic [PIX_BYTES*8-1:0] lut_hold_q;    // 刚收到的那份码：只存有用的 15 条车道（车道 15 是重复的点）
    logic [1:0]             lut_step_q;    // 喂到第几步（0/1/2 是三步，3 = 空闲）
    logic [LUT_LANES*8-1:0] lut_in;        // 这一步要喂的 5 个码
    logic                   lut_in_valid;  // 这一步要喂表（三步之内）
    logic                   lut_out_valid; // 表说这一步的 5 个字节出来了
    logic [LUT_LANES*8-1:0] lut_out;       // 这一步的 5 个像素字节
    logic [2*ROW_W-1:0]     tag_cur_q;     // 正在发的这一组的 {行, 列}
    logic [2*ROW_W-1:0]     tag_nxt_q;     // 刚收到的那一组（本组三拍发完就换上它）
    logic [1:0]             beat_first_q;  // 两位：收码延迟两拍，标记"本组第一拍"
    logic [1:0]             beat_q;        // 这一拍是本组第几拍（0/1/2）

    wire lut_idle = (lut_step_q == 2'd3);                                 // 表没在吃（可以接下一份码）
    wire rgb_code = pe_output_valid && is_rgb_q;                          // rgb 层来了一份结果码
    wire beat_first = beat_first_q[0];                                    // 组边界：比第一拍早一拍（复位/换标签都在这一拍做，从边沿起生效）

    assign lut_in_valid = (lut_step_q != 2'd3);                           // 三步之内都在喂表
    assign lut_in       = lut_hold_q[lut_step_q*LUT_LANES*8 +: LUT_LANES*8]; // 按步号取 5 个码（第 0 步取最低 5 个）

    always_ff @(posedge clk) begin                                        // 喂表与标签流水
        if (reset) begin                                                  // 复位（只复位控制，数据位不复位）
            lut_step_q   <= 2'd3;                                         // 表空闲
            beat_first_q <= 2'd0;                                         // 还没有"本组第一拍"
            beat_q       <= 2'd0;                                         // 第 0 拍
        end else begin                                                    // 正常工作
            beat_first_q <= {beat_first_q[0], rgb_code};                  // 收码 -> 延迟一拍 -> 延迟两拍
            beat_q       <= beat_first ? 2'd0 :                           // 本组第一拍：从第 0 拍起数
                            ((beat_q == 2'd2) ? 2'd0 : beat_q + 1'b1);    // 否则 0→1→2→0 循环
            if (beat_first) tag_cur_q <= tag_nxt_q;                       // 本组三拍发完：把"下一组"换上
            if (rgb_code) begin                                           // 来了一份新的码：收下、从第 0 步开始
                lut_hold_q <= pe_output_codes[PIX_BYTES*8-1:0];           // 记下这份码的前 15 条车道
                tag_nxt_q  <= {pe_output_row, pe_output_x};               // 这一组的标签先进"下一组"
                lut_step_q <= 2'd0;                                       // 下一拍喂第 0 组 5 个码
            end else if (lut_step_q != 2'd3) begin                        // 没来新码、表还在吃：推进一步
                lut_step_q <= lut_step_q + 2'd1;                          // 0 → 1 → 2 → 3（空闲）
            end                                                           // 喂表分支结束
        end                                                               // 正常工作结束
    end                                                                   // 喂表与标签流水结束

    // pixel_valid 只用表自己的 out_valid 判定，**不再与当前的 is_rgb_q 相与**：
    // 末次 RGB 码在最后一刀后9拍才回来，之后表还要连吐三拍；而换出口那一拍 is_rgb_q 就翻了，
    // 再用它去过滤就会把最后一组像素（三拍）整组屏蔽掉。表只可能被 RGB 的码启动（喂表的状态
    // 只由 rgb_code 推进），所以 out_valid 本身就说明"这是 rgb 的结果"。
    assign pixel_valid = lut_out_valid && beat_q!=0;                                   // 表出一拍，就发一拍 5 个字节
    assign pixel_row   = tag_cur_q[2*ROW_W-1:ROW_W];                          // 这一拍属于哪一行（正在发的这一组的标签）
    assign pixel_x     = tag_cur_q[ROW_W-1:0];                                 // 这一拍 5 个字节从哪个像素算起
    assign pixel_beat  = beat_q;                                          // 这一拍是本组的第几拍
    // Four sigmoid RGB888 pixels still take three LUT cycles. Pack only at the
    // output boundary: cycle 0 saves pixel 0 and R1; cycles 1/2 emit two
    // RGB565 pixels each. Reuse 21 bits between the two partial channel sets.
    logic [20:0] rgb565_partial_q;
    wire [15:0] rgb565_first={lut_out[7:3],lut_out[15:10],lut_out[23:19]};
    wire [15:0] rgb565_second={rgb565_partial_q[20:16],lut_out[7:2],lut_out[15:11]};
    wire [15:0] rgb565_third={rgb565_partial_q[4:0],rgb565_partial_q[10:5],lut_out[7:3]};
    wire [15:0] rgb565_fourth={lut_out[15:11],lut_out[23:18],lut_out[31:27]};
    always_ff @(posedge clk)if(lut_out_valid)begin
        if(beat_q==0)rgb565_partial_q<={lut_out[31:27],rgb565_first};
        else if(beat_q==1)rgb565_partial_q[10:0]<={lut_out[31:26],lut_out[23:19]};
    end
    assign pixel_bytes = beat_q==1 ? {8'd0,rgb565_second,rgb565_partial_q[15:0]} :
                                             {8'd0,rgb565_fourth,rgb565_third};                                         // 5 个字节：第 i 个 = 本组第 5*beat+i 个字节

    // ------------------------------ 自查 ------------------------------
    logic proto_err_q;
    // row_boundary = pe_window_released && (idx_q == pcnt_q).
    // At the last group, !row_boundary therefore reduces to !pe_window_released.
    wire fill_protocol_error = fill_done &&
        (row_busy_q ? ((armed_q == 2'd3) ||
                       ((idx_q == pcnt_q) && !pe_window_released))
                    : (armed_q != 2'd0));
    wire rgb_protocol_error = rgb_code && !lut_step_q[1];
    wire protocol_event = pe_protocol_error || fill_protocol_error || rgb_protocol_error;

    always_ff @(posedge clk) begin
        if (reset) proto_err_q <= 1'b0;
        else proto_err_q <= proto_err_q || protocol_event;
    end
    assign protocol_error = proto_err_q;

    // ------------------------------ 子模块 ------------------------------
    ngm_tap_window #(                                                     // 抽头窗口：两块各 24 格，一块在算一块在装
        .BANK_CELLS (WINDOW_CELLS),                                       // 一个缓冲区的格数
        .CELL_BITS  (CELL_BITS),                                          // 每格的位数
        .WORD_CELLS (WORD_CELLS),                                         // 一个写口一次写 8 格
        .PORT_COUNT (PORT_COUNT)                                          // 写口数
    ) u_tap_window (                                                      // 抽头窗口例化
        .clk          (clk),                                              // 时钟
        .role_swap    (role_swap), // 同沿轮换活动/准备版本，不经过全局角色异或。
        .load_valid   (load_valid),                                       // 写口有效（存储侧直通）
        .load_group   (load_group),                                       // 写口组号（存储侧直通）
        .layer(load_layer),.copy_window(copy_window),.right_reflect(right_reflect),.head_padding(head_padding), // 固定路由授权。
        .d_source_rgb_word(d_source_rgb_word),.d_source_v_tags(d_source_v_tags),.d_source_front_word(d_source_front_word),.c_source_word(c_source_word),.d_source_word(d_source_word),.c_source_odd(c_source_odd), // 原生单字直达窗口。
        .d_source_half(d_source_half),.stem_source_word(stem_source_word),.bank_source_word(bank_source_word), // 固定半字与抽头源。
        .load_cell_enable(load_cell_enable),.load_byte_enable(load_byte_enable), // 使能直通，不增加宽暂存。
        .window_cells (window_cells)                                      // 正在算的那一半，组合引出
    );                                                                    // 抽头窗口例化结束

    ngm_point_engine #(                                                   // 点引擎：把窗口变成阵列要的每一拍，并把结果打上标签
        .LANES     (LANES),                                               // 车道条数
        .LANE_W    (LANE_W),                                              // 一拍结果的位数
        .WINDOW_W  (WINDOW_CELLS*CELL_BITS),                              // 窗口位数（24 格 × 32 位）
        .BATCH_MAX (BATCH_MAX)                                            // 批数上限
    ) u_point_engine (                                                    // 点引擎例化
        .clk               (clk),                                         // 时钟
        .reset             (reset),                                       // 复位
        .layer_kind        (cfg_kind),                                    // 通路编号（与行起点同拍进，点引擎当拍锁存）
        .layer_slots       (cfg_slots),                                   // 段数（同上）
        .layer_batches     (cfg_batches),                                 // 批数（同上）
        .layer_start_valid (pe_layer_start_valid),                        // 层边界（只在行起点那一拍）
        .layer_start_ready (pe_layer_start_ready),                        // 点引擎说可以收
        .point_valid       (pe_point_valid),                              // 一个组
        .point_ready       (pe_point_ready),                              // 点引擎说收下了
        .point_row         (pe_point_row),                                // 本组的行号
        .point_in_range    (pe_point_x>=emit_lo && pe_point_x<emit_hi),
        .point_x           (pe_point_x),                                  // 本组的列号
        .dec_v(load_layer==14 ? 2'd1 : load_layer==2 ? 2'd2 : 2'd0), // 当前固定模型层在流水排空前保持。
        .window_vectors    (window_cells),                                // 窗口正在算的那一半
        .skip_codes        (skip_codes),                                  // 残差半字（直通）
        .weights_live(row_busy_q), // 末组最后issue所在沿结束后才释放旧权重。
        .weight_stream_slot(weight_stream_slot),.weight_stream_pair(weight_stream_pair), // 返回位置。
        .weight_stream_param(weight_stream_param),.weight_stream_ready(weight_stream_ready), // 流握手。
        .weight_stream_valid (weight_stream_valid),                       // 常驻槽装载流（直通）
        .weight_stream_data  (weight_stream_data),                        // 常驻槽装载流数据（直通）
        .output_in_range   (pe_output_in_range),
        .output_valid      (pe_output_valid),                             // 结果有效
        .output_ready      (pe_output_ready),                             // 结果永远当拍收走
        .output_row        (pe_output_row),                               // 结果行号
        .output_x          (pe_output_x),                                 // 结果列号
        .residual_x_odd(residual_x_odd), // 残差消费时刻的窄标签。
        .output_batch      (pe_output_batch),                             // 结果批号
        .output_codes      (pe_output_codes),                             // 结果的 16 条车道码
        .window_released   (pe_window_released),                          // 本组最后一刀那一拍
        .protocol_error    (pe_protocol_error)                            // 点引擎自查
    );                                                                    // 点引擎例化结束

    ngm_sigmoid_lut #(                                                    // sigmoid 表：只给 rgb 层用
        .LANE_COUNT (LUT_LANES),                                          // 一次查 5 个码
        .INIT_FILE  (LUT_INIT)                                            // 半表文件（必须传真实表，否则综合会把表优化掉）
    ) u_sigmoid_lut (                                                     // sigmoid 表例化
        .clk       (clk),                                                 // 时钟
        .reset     (reset),                                               // 复位
        .in_valid  (lut_in_valid),                                        // 这一步有码要查
        .in_codes  (lut_in),                                              // 这一步的 5 个码
        .out_valid (lut_out_valid),                                       // 这一步的 5 个字节出来了
        .out_bytes (lut_out)                                              // 这一步的 5 个像素字节
    );                                                                    // sigmoid 表例化结束

endmodule                                                                 // 行卷积引擎结束
