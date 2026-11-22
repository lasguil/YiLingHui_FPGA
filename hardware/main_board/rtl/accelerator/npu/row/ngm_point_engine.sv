// 协议契约：每行启动提交已完整装载的单套上下文锚点；装载位置和ready显式传递；bias/RQ/residual分别在6/7/8拍消费，最终结果和标签在9拍输出。
// ============================================================================
// 点引擎（当前版本：只负责"在正确的拍，把数据喂到正确的地方"）
//
// 它把一个（或一组）空间点的窗口，变成阵列要的那一串 issue，并在正确的拍把三样东西
// 摆到正确的读口上：
//   · 操作数成形器：kind / slot / batch（外加那 768 位窗口本身）
//   · 常驻槽（权重 + 参数）：逻辑槽号 = 批 × 段 + 段
//   · 计算簇：issue / issue_first / issue_last，以及逐批的量化参数与 skip 码
//
// **结果标签**：结果比"本点最后一刀"晚 9 拍才回来（八拍阵列/量化商捕获，第九拍舍入/残差组合），
// 那时坐标早就换成下一个点了，所以要把"这一批属于哪个点、哪一批"跟着结果一起走。
// 做法是八深SRL之后加一级FF：issue_last沿移入{行,列,批}，第8拍选残差，第9拍送写回。
// 标签数据不复位，仅有效流水复位。下游约定**每拍都收走**（不做背压），所以这里是定值延迟，不是队列。
// 若下游真的停顿、或者这个 9 拍常数与阵列实际不符，protocol_error 会拉高。
//
// ------------------------------- 时序与时刻 -------------------------------
// 阵列侧（见 ngm_pe_12mac / ngm_mac_array_16x12 的文件头）：一刀 = issue 一拍；
// 批内第一刀 issue_first、批内最后一刀 issue_last。相对时刻（t = 某拍 issue）：
//   · activation / weight          必须在 t 那一拍有效        → 成形器与常驻槽按当拍 slot/batch 取
//   · bias                         必须在 t_first + 6 那一拍有效
//   · 量化参数（pre/M18/post/relu6） 必须在 t_last + 7 那一拍有效（重量化输入端 = PE 出结果那拍）
//   · skip 码 / 残差使能            必须在 t_last + 8 那一拍有效（skip在第8拍捕获，残差在第9拍相加，最终结果第9拍输出）
// 参数都按**批**存，而它们在不同深度才被取用；所以这里不延迟参数数据，只延迟 1 位批号，
// 让常驻槽在正确那一拍读出正确那一批（三个抽头 delay[5] / [6] / [7] 对应上面后三行）。
//
// 点与点之间：空闲时随时收；忙时只在"本点最后一刀"那一拍收下一个点，计数器归零接着发，
// 这样 issue 序列不断流（一个点 = 批数 × 段数 拍）。
//
// ----------------------------- 上游要给的 -----------------------------
// · layer_start_valid + layer_kind / layer_slots / layer_batches：层边界（三样一共 7 位）。
//   通路由上游从窗形与每组输入通道数解出来、段数 = ceil(reduction_length/12)、
//   批数 = ceil(cout/16)；描述符不进本模块；
// · point_valid + 行/列 + window_vectors：一个点的窗口。行/列在**接收那一拍**锁存；
//   window_vectors 要稳到 window_released 那一拍之后才能换（成形器整条链都在读它）；
// · skip_codes：位宽 = 批数 × 128，每批 128 位放在自己那一段里（上游把该批的正确半字摆好）；
// · weight_stream_*：常驻槽的装载流。
//
// ------------------------------- 位宽约定 -------------------------------
// 下游（成形器的 batch、常驻槽的 bias_batch/quant_batch、结果标签的批字段）拿到的都是
// **批号**，不是批数，所以内部一律用 1 位索引（最多 2 批），两边同宽、不做位宽转换：
//   · 批数 batches_q：计数，取值 1/2 → 必须 2 位；批号 batch_q：索引，取值 0/1 → 1 位
//   · 段数 slots_q / 段号 slot_q：计数取值 1/2/3、索引取值 0/1/2 → 都是 2 位
//   · 逻辑槽号 = 批号 × 段数 + 段号 → 3 位（最大 1×3+2 = 5）
// 若将来 batch_count 超过 2，这四处要一起放宽：batch_q、batch_delay_q、标签的批字段、
// 常驻槽的两个参数读地址端口。
//
// ------------------------------- 协议检查 -------------------------------
// protocol_error：还没做完就换层、段数或批数给成 0。
// ============================================================================
module ngm_point_engine #( // 固定模型的计算与标签控制模块。
    parameter int unsigned LANES     = 16,          // 车道条数（与 ngm_compute_cluster 一致）
    parameter int unsigned LANE_W    = LANES * 8,   // 一次返回：16 条车道的码
    parameter int unsigned AXIS_W    = 11,          // 行号/列号位宽：Spec 上限 1920×1080 → 11 位够
    parameter int unsigned WINDOW_W  = 768,         // 抽头窗口引出：24 格 × 32 位
    parameter int unsigned BATCH_MAX = 2,           // 输出通道批次上限（模型的 body/down 是 2）
    parameter int unsigned SKIP_W    = BATCH_MAX * LANE_W // 最多两批残差码的接口总位宽。
) ( // 端口连接或参数定义结束。
    input  logic                clk, // 工作时钟。
    input  logic                reset, // 同步复位，只清控制和有效位。

    // 层配置：只在层边界变
    input  logic [2:0]          layer_kind, // 行启动时锁存运算形状。
    input  logic [1:0]          layer_slots,      // 段数（计数，取值 1/2/3）
    input  logic [1:0]          layer_batches,    // 批数（计数，取值 1/2）
    input  logic                layer_start_valid, // 本行启动并提交完整权重锚点。
    output logic                layer_start_ready, // 点末片或空闲时才能提交下一行。

    // 点窗口输入
    input  logic                point_valid, // 完整窗口对应的空间点请求。
    output logic                point_ready, // 当前点末片或空闲时接下一点。
    input  logic [AXIS_W-1:0]   point_row, // 本点真实行号。
    input logic point_in_range, // Precomputed for the same accepted point.
    input  logic [AXIS_W-1:0]   point_x, // 本组第一个像素的真实列号。
    input logic [1:0] dec_v, // 行描述符保持至所有结果排空。
    input  logic [WINDOW_W-1:0] window_vectors, // 当前活动窗口的24格32位激活字。
    input  logic [SKIP_W-1:0]   skip_codes, // 第8拍消费的同域INT8残差半字。

    // 常驻槽的装载流
    input logic weights_live, // 行内及最后issue之前权重仍有效。
    input logic [2:0] weight_stream_slot, // 正在装载的逻辑槽。
    input logic [5:0] weight_stream_pair, // 正在装载的40位组。
    input logic weight_stream_param, // 参数流标记。
    output wire weight_stream_ready, // 容量及参数尾部回压。
    input  logic                weight_stream_valid, // 主表返回40位项有效。
    input  logic [39:0]         weight_stream_data, // 两个相邻20位编码字。

    // 结果输出（当前直通；标签逻辑未实现，见文件头）
    output wire output_in_range, // Same nine-cycle tag as row/x/batch.
    output logic                output_valid, // 第9拍结果及标签有效，输出无回压。
    input  logic                output_ready,     // 暂未使用
    output logic [AXIS_W-1:0]   output_row, // 与结果对齐的真实行号。
    output logic [AXIS_W-1:0]   output_x, // 与结果对齐的真实组首列。
    output wire residual_x_odd, // 第八拍的残差半字选择。
    output logic                output_batch, // 与结果对齐的低/高批号。
    output logic [LANE_W-1:0]   output_codes, // 16车道最终码值。

    // 本点最后一个 issue 那一拍拉高：上游据此换窗口（乒乓就在这一拍之后翻角色）
    output logic                window_released, // 本组末片已采样，上游可以交换窗口角色。

    output logic                protocol_error // 发现握手或固定延迟失配后保持至复位。
); // 端口连接或参数定义结束。
    // ------------------------------- 层配置 -------------------------------
    logic [2:0] kind_q;        // 通路编号（0=1×1、1=enc/dec、2=body、3=head、4=rgb）
    logic [1:0] slots_q;       // 段数
    logic [1:0] batches_q;     // 批数

    // ---------------------------- issue 状态 ----------------------------
    logic [1:0] slot_q;        // 当前是第几段（段号：0..2）
    logic       batch_q;       // 当前是第几批（批号：0/1，与下游同宽；批数见 batches_q）
    logic       chain_busy_q;  // 正在发这一串 issue

    // 点的行/列在**接收那一拍**锁存：上游收下之后就可以换下一个点的坐标
    logic pt_range_q;
    logic [AXIS_W-1:0] pt_row_q, pt_x_q;   // 点的坐标（接收那一拍锁存）

    // 计算簇回来的结果（协议检查要用，所以先声明）
    logic              result_valid; // 最终第9拍结果有效。
    logic [LANE_W-1:0] result_codes; // 最终16车道INT8码值。

    wire batch_first = chain_busy_q && (slot_q == 2'd0); // 当前批的第一个段。
    wire batch_last  = chain_busy_q && (slot_q == slots_q - 2'd1); // 当前批的最后一个段。
    wire point_last  = batch_last && (batch_q == batches_q - 2'd1); // 本组最后一批的末段。

    // 阵列按"批内第一刀 / 批内最后一刀"认：每个批次是一条独立的累加
    wire issue_first_now = batch_first; // 本拍实际首片标记。
    wire issue_last_now  = batch_last; // 本拍实际末片标记。

    // 常驻槽读地址：**逻辑槽号** = 批 × 段 + 段（槽模块内部再加固定偏移）
    wire [2:0] slot_read_addr = 3'(batch_q) * 3'(slots_q) + 3'(slot_q); // 批号与段号组成逻辑权重槽地址。

    // ------------------- 1 位批号延迟线（参数跟着结果走） -------------------
    // delay[k] = (k+1) 拍前那一批（每拍把当前批号从低位塞进去、整体上移一位）。
    // 三个抽头按"信号真正被消费的那一拍"取，最深 8 拍 → 8 位够：
    //   · 偏置：PE 在批内第一刀 +6 那一拍把 bias 取进加法器        → 6 拍前 → delay[5]
    //   · pre/M18/post/relu6：重量化输入端 = PE 出结果那一拍（+7） → 7 拍前 → delay[6]
    //   · skip 码：残差输入在cluster第8拍被捕获           → 8 拍前 → delay[7]
    logic [7:0] batch_delay_q; // 批号的8拍窄流水，对齐三个参数消费时刻。
    always_ff @(posedge clk) // 时钟沿推进点控制或窄流水。
        if (reset) batch_delay_q <= '0; // 批号逐拍移入，复位后旧参数选择无效。
        else       batch_delay_q <= {batch_delay_q[6:0], batch_q}; // 批号逐拍移入，复位后旧参数选择无效。

    wire bias_batch  = batch_delay_q[5]; // 第6拍bias的批号。
    wire quant_batch = batch_delay_q[6]; // 第7拍RQ参数的批号。
    wire skip_batch  = batch_delay_q[7]; // 末片后第8拍的残差批号。

    // --------------------------- 结果标签流水线 ---------------------------
    // 结果比"本点最后一刀"晚9拍；第8拍捕获skip，第9拍完成组合结果。所以把这一批的标签
    // 在issue_last沿塞入八深SRL；其输出再寄存一级，与第9拍结果对齐：
    //   delay[0] 是刚塞进去的，delay[7] 是 8 拍前塞进去的 —— 第8拍标签用于残差选半字，第9拍寄存标签用于最终写回。
    // 下游每拍都收走（不做背压），所以这里是定值延迟，不是队列。
    localparam int unsigned TAG_W     = AXIS_W + AXIS_W + 2;   // 范围标志 + 行 + 列 + 批；原行列/批的低位位置不变。
    localparam int unsigned TAG_DELAY = 9; // 最终结果标签固定延迟9拍。

    // 标签数据走**显式 EFX_SRL8**：每位一条、8 深、抽头固定在最老一位（A=0，即 8 拍前）。
    // 为什么数据链不复位：它只在有效位为 1 时被读，而 SRL8 原语没有复位端；若写成"整链复位"，
    // 工具会把它实现成"复位期间往链里送 0"，清零变成 8 拍而不是 1 拍（实测：33 位链多出 31 个
    // LUT4）。另外 EFX_SRL8 的读是 Q = ~data[~A]（取反 + 反向索引），所以读出来整字再取反还原。
    wire [TAG_W-1:0] tag_in = {pt_range_q, pt_row_q, pt_x_q, batch_q};        // 每拍把当前标签位移进去
    logic [TAG_W-1:0] tag_stage1; // 八拍SRL之后的结果标签FF，与结果数据同时采样。
    wire [TAG_W-1:0] tag_raw;                                     // SRL8 直接读出来的
    always_ff @(posedge clk)tag_stage1<=~tag_raw; // 数据不复位，有效位同步清零。
    for (genvar b = 0; b < TAG_W; b = b + 1) begin : g_tag_srl // 按常量位数展开标签流水，不使用宽动态选择。
        EFX_SRL8 u_srl8 ( // 每标签位一条八深SRL，读最老抽头。
            .D   (tag_in[b]),                                     // 当前标签位
            .A   (3'd0),                                          // 抽头固定在最老一位（8 拍前）
            .CLK (clk),                                           // 时钟
            .CE  (1'b1),                                          // 每拍都移
            .Q   (tag_raw[b]),                                    // 取反后的抽头
            .Q7  ()                                               // 本模块不用
        ); // 端口连接或参数定义结束。
    end // 本段控制或模块定义结束。
    logic [TAG_DELAY-1:0] tag_valid_q;                            // 有效位：9位触发器（这一位必须复位）
    always_ff @(posedge clk) begin // 时钟沿推进点控制或窄流水。
        if (reset) tag_valid_q <= '0;                             // 复位清零
        else       tag_valid_q <= {tag_valid_q[TAG_DELAY-2:0], issue_last_now}; // 每拍移进本批最后一刀
    end // 本段控制或模块定义结束。

    wire [TAG_W-1:0] tag_out   = tag_stage1;                        // 结果寄存已完成SRL输出反相还原。
    assign residual_x_odd=~tag_raw[1]; // 第八拍列奇偶不经过新增结果寄存器。
    wire             tag_valid = tag_valid_q[TAG_DELAY-1];        // 9拍前那次本批最后issue。

    // ------------------------------- 收点 -------------------------------
    // 空闲时随时收；忙时只在"本点最后一刀"那一拍收，这样下一条 issue 紧跟着发、不断流。
    wire point_take = point_valid && point_ready; // 本拍实际接收一个新空间点。
    assign point_ready = chain_busy_q ? point_last : 1'b1; // 当前点末片或空闲时接下一点。

    // 窗口保持契约：上游要让 window_vectors 稳到这一拍（本点最后一刀）之后才能换
    assign window_released = point_last; // 本组末片已采样，上游可以交换窗口角色。

    // 层边界在「空闲」或「本点最后一刀那一拍」都能收：
    //   · 空闲时收：配置锁存后下一拍才用得上，当前没有链在跑，天然安全；
    //   · 最后一刀那一拍收：当前这一刀用的还是旧配置（配置在时钟沿才锁存），而下一拍进来的
    //     新点用的就是新配置 —— 正好对上。这样行与行（甚至层与层）之间可以一刀不空。
    // 更早不给：那时候链上还有刀没发完，换了配置会把这一串要切的刀数切错（自查会报）。
    assign layer_start_ready = !chain_busy_q || point_last; // 点末片或空闲时才能提交下一行。

    // ------------------------------- 时序 -------------------------------
    always_ff @(posedge clk) begin // 时钟沿推进点控制或窄流水。
        if (reset) begin // 按当前握手和点状态选择更新分支。
            chain_busy_q <= 1'b0; // 点接受后开始逐段issue，末片后释放当前点。
            slot_q       <= 2'd0; // 批内递增段号，批末回到段零。
            batch_q      <= 1'b0; // 低批结束转高批，整组结束释放窗口。
            kind_q       <= 3'd0; // 连接当前配置、流水标签或有效位。
            slots_q      <= 2'd1; // 连接当前配置、流水标签或有效位。
            batches_q    <= 2'd1; // 连接当前配置、流水标签或有效位。
            pt_row_q     <= '0; // 接收新点时保存真实行列标签。
            pt_range_q <= 0;
            pt_x_q       <= '0; // 接收新点时保存真实行列标签。
        end else begin // 本段控制或模块定义结束。
            // 层边界：收下三样配置
            if (layer_start_valid && layer_start_ready) begin // 按当前握手和点状态选择更新分支。
                kind_q    <= layer_kind; // 连接当前配置、流水标签或有效位。
                slots_q   <= layer_slots; // 连接当前配置、流水标签或有效位。
                batches_q <= layer_batches; // 连接当前配置、流水标签或有效位。
            end // 本段控制或模块定义结束。

            // 链的推进：一拍一刀；段走满换下一批；最后一批走完这个点结束
            if (chain_busy_q) begin // 点接受后开始逐段issue，末片后释放当前点。
                if (point_last) begin // 按当前握手和点状态选择更新分支。
                    if (point_take) begin          // 就地收下一个点：issue 不断流
                        slot_q   <= 2'd0; // 批内递增段号，批末回到段零。
                        batch_q  <= 1'b0; // 低批结束转高批，整组结束释放窗口。
                        pt_row_q <= point_row; // 接收新点时保存真实行列标签。
                        pt_x_q   <= point_x; pt_range_q <= point_in_range; // 接收新点时保存真实行列标签。
                    end else begin // 本段控制或模块定义结束。
                        chain_busy_q <= 1'b0; // 点接受后开始逐段issue，末片后释放当前点。
                    end // 本段控制或模块定义结束。
                end else if (slot_q == slots_q - 2'd1) begin // 批内递增段号，批末回到段零。
                    slot_q  <= 2'd0; // 批内递增段号，批末回到段零。
                    batch_q <= batch_q + 1'b1; // 低批结束转高批，整组结束释放窗口。
                end else begin // 本段控制或模块定义结束。
                    slot_q <= slot_q + 2'd1; // 批内递增段号，批末回到段零。
                end // 本段控制或模块定义结束。
            end else if (point_valid && point_ready) begin // 本段控制或模块定义结束。
                chain_busy_q <= 1'b1; // 点接受后开始逐段issue，末片后释放当前点。
                slot_q       <= 2'd0; // 批内递增段号，批末回到段零。
                batch_q      <= 1'b0; // 低批结束转高批，整组结束释放窗口。
                pt_row_q     <= point_row; // 接收新点时保存真实行列标签。
                pt_x_q       <= point_x; pt_range_q <= point_in_range; // 接收新点时保存真实行列标签。
            end // 本段控制或模块定义结束。
        end // 本段控制或模块定义结束。
    end // 本段控制或模块定义结束。

    // --------------------------- 协议检查 ---------------------------
    always_ff @(posedge clk) begin // 时钟沿推进点控制或窄流水。
        if (reset) protocol_error <= 1'b0; // 非法握手或结果延迟不一致时保持错误。
        else if (layer_start_valid && !layer_start_ready) protocol_error <= 1'b1;  // 没做完就换层
        else if (layer_start_valid && (layer_slots == 2'd0 || layer_batches == 2'd0)) // 按当前握手和点状态选择更新分支。
            protocol_error <= 1'b1;                                                // 段数/批数不能是 0
        else if (result_valid != tag_valid) // 按当前握手和点状态选择更新分支。
            protocol_error <= 1'b1;      // 结果回来的那一拍标签链上必须正好有一项（延迟常数对不对）
        else if (result_valid && !output_ready) // 按当前握手和点状态选择更新分支。
            protocol_error <= 1'b1;      // 下游必须每拍都收走（本设计不做背压）
    end // 本段控制或模块定义结束。

    // ------------------------------- 子模块 -------------------------------
    logic [1535:0]     activation_operands; // 16车道各12个INT8激活操作数。
    logic [1535:0]     weight_operands; // 与激活逐项对应的INT8权重。
    // 参数总线：384 偏置 + 48 pre + 272 m18 + 80 post + 2 使能 = 786 位
    // （16 车道 × 49 是前 784 位，relu6 在 784、residual 在 785，所以总宽要多 2 位）
    localparam int unsigned PARAM_W = LANES*49 + 2; // 本行固定配置或对应流水信号。
    logic [PARAM_W-1:0] param_context; // 按6/7/8拍消费返回的786位参数字段。

    ngm_operand_former u_operand_former ( // 固定模型激活成形，不改变真实坐标标签。
        .kind                (kind_q), // 固定模型操作数成形档位。
        .slot                (slot_q), // 当前段号，选择本批的12路操作数。
        .batch               (batch_q),
        .dec_v(dec_v), // 两源窗口只供Decoder-V使用。
        .rgb_x_odd(pt_x_q[0]),.rgb_y_odd(pt_row_q[0]), // 当前组的真实nearest相位。 // 当前低/高批号。
        .window_cells        (window_vectors), // window_cells端口按当前切片或流水标签连接。
        .activation_operands (activation_operands) // 16车道各12个INT8激活操作数。
    ); // 端口连接或参数定义结束。

    ngm_weight_slots u_weight_slots ( // 单套物理SRL权重及参数上下文。
        .clk           (clk), // 工作时钟。
        .reset         (reset), // 同步复位，只清控制和有效位。
        .weights_live(weights_live), // 整行生命周期，不以点间空拍提前释放。
        .next_count(3'(layer_slots)*3'(layer_batches)), // 提交使用当前行实际上下文数。
        .stream_slot(weight_stream_slot),.stream_pair(weight_stream_pair), // 显式装载位置。
        .stream_param(weight_stream_param),.stream_ready(weight_stream_ready), // 回压。
        .stream_valid  (weight_stream_valid), // stream_valid端口按当前切片或流水标签连接。
        .stream_data   (weight_stream_data), // stream_data端口按当前切片或流水标签连接。
        .commit        (layer_start_valid && layer_start_ready),  // 新一行启动那一拍：提交已装载层锚点
        .read_addr     (slot_read_addr), // 当前issue的逻辑权重槽号。
        .read_context  (weight_operands), // 单套SRL返回1536位权重上下文。
        .bias_batch    (bias_batch), // 第6拍bias的批号。
        .quant_batch   (quant_batch), // 第7拍RQ参数的批号。
        .param_context (param_context) // 按6/7/8拍消费返回的786位参数字段。
    ); // 端口连接或参数定义结束。

    ngm_compute_cluster u_compute_cluster ( // 连接当前配置、流水标签或有效位。
        .clk                (clk), // 工作时钟。
        .reset              (reset), // 同步复位，只清控制和有效位。
        .activation_operands(activation_operands), // 16车道各12个INT8激活操作数。
        .weight_operands    (weight_operands), // 与激活逐项对应的INT8权重。
        .bias_operands      (param_context[0 +: LANES*24]), // 16车道各24位bias，在首片后第6拍使用。
        .issue              (chain_busy_q), // 本拍阵列执行一个切片。
        .issue_first        (issue_first_now), // 本批首片，开启新的累加。
        .issue_last         (issue_last_now), // 本批末片，发起本批结果流水。
        .pre_shifts         (param_context[LANES*24 +: LANES*3]), // 16车道的重量化预移位。
        .multipliers_m18    (param_context[LANES*24 + LANES*3 +: LANES*17]), // 16车道的17位量化乘数。
        .post_shifts        (param_context[LANES*24 + LANES*3 + LANES*17 +: LANES*5]), // 16车道的重量化后移位。
        .relu6_enable       (param_context[LANES*49]), // 当前批分支的ReLU裁剪授权。
        .skip_codes         (skip_codes[{skip_batch, 7'b0} +: LANES*8]), // 第8拍消费的同域INT8残差半字。
        .residual_enable    (param_context[LANES*49 + 1]), // 第8拍残差相加及最终裁剪授权。
        .result_valid       (result_valid), // 最终第9拍结果有效。
        .result_codes       (result_codes) // 最终16车道INT8码值。
    ); // 端口连接或参数定义结束。

    // ------------------------------- 结果 -------------------------------
    // 结果 + 8 拍前塞进标签链的那一项（属于哪个点、哪一批）一起送出去。
    // 下游每拍都收走，不做背压；迟收或停顿由 protocol_error 报出来。
    assign output_valid = result_valid; // 第9拍结果及标签有效，输出无回压。
    assign output_codes = result_codes; // 16车道最终码值。
    assign {output_in_range, output_row, output_x, output_batch} = tag_out; // 固定连接当前流水结果与对应标签。

endmodule // 本段控制或模块定义结束。
