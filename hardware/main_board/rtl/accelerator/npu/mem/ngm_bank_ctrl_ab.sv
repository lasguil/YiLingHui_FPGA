/* OPTIMIZATION_NOTE_20261005
 * 无损压缩约束（2026-10-05）：每通道只存低7位，读时补零；合法特征范围为0..127。
 * 固定模型的ReLU及残差写回clamp保证该范围；这不是可接受任意signed INT8的存储器。
 * 若改激活、残差钳位、量化或图结构，须先证明每个A/B写入口的码域，不能只检查样本。
 * SIM_ASSERT仅仿真检查，综合后不会阻止负值被截掉；模型包部署前必须检查数值合同。
 * 当前每组1024x112、12块RAM10，两组每片24块；外部128/256位布局及读延迟不变。
 * 不能依据保留的通用参数名任意改变布局；改布局须协同修改结果整理、窗口及供数。
 * 详见 docs/OPTIMIZATION_CONSTRAINTS.md。
 */
// 协议契约：Body写入仍为逻辑C32整字，RAM中按P32固定转置保存；Body读出口改为窗口原生顺序，前端完全不变。
// 协议契约：前端两个数据口分别直出物理组0/1，front_slots给出逐层reflect后的真实抽头归属。
// 协议契约：A/B逻辑出口仍为两组128位，当前物理存储为两组1024×112，每片24块RAM10。
// Body每个P32存储字的低高半分别在组0/1同地址，一拍同时读出，三抽头仍三拍。
// 前端每组保存一条1024像素行，row[1]选组；同片两行分组，上下两抽头同拍读取。
// 前端fw_valid每个像素一次，fw_data低128位有效，fw_col无需为奇列；结果整理器同步修改。
// 前端fill_word仅低128位有效，上层不再选择奇偶列半字；Body完整256位有效。
// RAM10采用合法1024×10模式，每组12块；码域0..127使物理位宽缩减无损，D保持完整8位。
// RAM返回一拍，READ_FIRST及所有真实行槽生命周期沿用基线，不新增宽缓存或DSP。
module ngm_bank_ctrl_ab #(            // A/B 片控制器：参数
    parameter int unsigned BANK_SEL = 0,          // 0 = A 片（偶行 B0/B1），1 = B 片（奇行 B2/B3）
    parameter int unsigned SLOT_N   = 3,          // 主体：一个环几行
    parameter int unsigned ADDR_W   = 10,         // 片内逻辑地址位宽（1024 字）
    parameter int unsigned WORD_W   = 256,        // 字宽
    parameter int unsigned IDX_W    = ADDR_W - 1, // 组内（半区）索引位宽（512 字）
    parameter int unsigned BLK_W    = 20,         // 每块 RAM10 的宽度
    parameter int unsigned BLK_N    = 13,         // 一组的块数
    parameter int unsigned GRP_N    = 2,          // 组数（两个深度半区）
    parameter int unsigned ROW_W    = 11,         // 行号位宽
    parameter int unsigned COL_W    = 11,         // 列号位宽
    parameter int unsigned TAP_N    = 3,          // 抽头数（主体和前端均为竖向三抽头）
    parameter int unsigned CELL_G_W = 2,          // 装填口"写窗口哪一组 8 格"的位宽
    parameter int unsigned FR_COL_MAX = 1024       // 前端合法列上界（槽 480 字 = 960 像素，留到 1024）
) ( // 参数区结束，接口开始。
    input  logic                     clk,             // 时钟
    input  logic                     reset,           // 同步复位

    // ------------------------------ 层配置（与行/层起点同拍摆上，本行期间不变）------------------------------
    input  logic                     cfg_front,       // 0 = 主体相位，1 = 前端 C16 相位
    input  logic                     cfg_ring,        // 主体：本行用本片的哪个环（0/1）
    input  logic [1:0]               wr_slot_in,      // 主体写入真实行的三行环槽，由调度提供。
    input  logic [1:0]               req_slot_in,     // 主体读取中心行的三行环槽，由调度提供。

    // ------------------------------ 写口一：主体（上游结果整理器，一个像素一个 C32 向量）------------------------------
    input  logic                     wr_valid,        // 本拍要写一个字
    input  logic [COL_W-1:0]         wr_col,          // 写到哪一列
    input  logic [WORD_W-1:0]        wr_data,         // 写什么（整字）
    output logic                     wr_ready,        // 能收（恒 1）

    // ------------------------------ 写口二：前端 H-stage 每拍一个 C16 像素 ------------------------------
    input  logic                     fw_valid,        // 本拍要写一个低128位有效的C16像素。
    input  logic [ROW_W-1:0]         fw_row,          // 写到哪一行（必须与本片奇偶相符）
    input  logic [COL_W-1:0]         fw_col,          // 写到哪一列
    input  logic [WORD_W-1:0]        fw_data,         // 每拍像素在低128位，高128位不消费。
    output logic                     fw_ready,        // 整字写口可收。

    // ------------------------------ 窗口请求（当前组在算时，把"下一组"的坐标提前摆上）------------------------------
    input  logic                     req_valid,       // 本拍有窗口请求
    input  logic [ROW_W-1:0]         req_row,         // 请求中心真实行号
    input  logic [COL_W-1:0]         req_col,         // 请求列号
    input  logic                     req_last_row,    // 请求中心是本层最后一条真实行
    output logic                     req_ready,       // 能收（取数机空闲）

    // ------------------------------ 装填口（给路由侧；主体直通，前端由路由侧跨片压字）------------------------------
    output logic [1:0]               fill_valid,      // 第 i 个口这一拍有字
    output logic [1:0][CELL_G_W-1:0] fill_group,      // 第 i 个口的抽头号（窗口里第几组 8 格）
    output logic [1:0][WORD_W-1:0]   fill_word,       // 第 i 个口的字
    output logic [2:0] front_slots, // 前端三抽头物理组，必须随返回锁存。
    output logic                     fill_done,       // 一拍脉冲：本模块这一组的字都推出去了

    // ------------------------------ 自查 ------------------------------
    output logic                     protocol_error   // 一次拉高保持到复位
); // 接口定义结束。
    function automatic int unsigned ring_pitch(input int unsigned ring);     // 环行距
        if (BANK_SEL == 0) ring_pitch = (ring == 0) ? 130 : 128;             // A 片
        else               ring_pitch = (ring == 0) ? 126 : 124;             // B 片
    endfunction // 三行环槽映射函数结束。
    function automatic logic [ADDR_W-1:0] body_base(input logic ring,input logic [1:0] slot); // 固定环槽基址。
        if (BANK_SEL==0) begin                                // A 片的两个 Body 环。
            case ({ring,slot})                                 // 仅六个合法物理行槽。
                3'b000: body_base=ADDR_W'(0);                   // Body0 槽零。
                3'b001: body_base=ADDR_W'(130);                 // Body0 槽一。
                3'b010: body_base=ADDR_W'(260);                 // Body0 槽二。
                3'b100: body_base=ADDR_W'(390);                 // Body1 槽零。
                3'b101: body_base=ADDR_W'(518);                 // Body1 槽一。
                default: body_base=ADDR_W'(646);                // Body1 槽二。
            endcase                                             // A 片基址结束。
        end else begin                                          // B 片的两个 Body 环。
            case ({ring,slot})                                 // 仅六个合法物理行槽。
                3'b000: body_base=ADDR_W'(0);                   // Body2 槽零。
                3'b001: body_base=ADDR_W'(126);                 // Body2 槽一。
                3'b010: body_base=ADDR_W'(252);                 // Body2 槽二。
                3'b100: body_base=ADDR_W'(378);                 // Body3 槽零。
                3'b101: body_base=ADDR_W'(502);                 // Body3 槽一。
                default: body_base=ADDR_W'(626);                // Body3 槽二。
            endcase                                             // B 片基址结束。
        end                                                     // 固定 BANK_SEL 分支结束。
    endfunction                                                 // 固定基址函数结束。

    logic [9:0] ram_rd_idx[2],ram_wr_idx[2]; // 两组各1024深度。
    wire [255:0] body_storage_word; // 写回端按模型固定置换，只有连线无运行期选择。
    for(genvar cell_id=0;cell_id<8;cell_id++)for(genvar byte_id=0;byte_id<4;byte_id++)begin:g_body_storage // P32在保存H-stage结果时完成。
        assign body_storage_word[(cell_id*4+byte_id)*8+:8]=wr_data[(byte_id*8+cell_id)*8+:8]; // 与旧窗口P32逐字节相同。
    end // 固定物理通道摆位结束。
    wire [127:0] ram_rd_data[2];logic [127:0] ram_wr_data[2];logic [1:0] ram_wr_valid; // 原生半字读写。
    // Store existing nonnegative INT8 codes exactly; restore the zero sign bit.
    wire [111:0] compact_read[2], compact_write[2];
    for (genvar group_id=0; group_id<2; group_id++) begin : g_a7
        for (genvar channel=0; channel<16; channel++) begin : g_channel
            assign compact_write[group_id][channel*7+:7] = ram_wr_data[group_id][channel*8+:7];
            assign ram_rd_data[group_id][channel*8+:8] = {1'b0,compact_read[group_id][channel*7+:7]};
`ifdef SIM_ASSERT
            always @(posedge clk) if (!reset && ram_wr_valid[group_id] && ram_wr_data[group_id][channel*8+7])
                $fatal(1,"A/B compact storage received a negative feature");
`endif
        end
    end
    ngm_act_ram #(.ADDR_W(11),.WORD_W(112),.BLK_W(10),.BLK_N(12),.GRP_N(2),.IDX_W(10)) u_act_ram( // 每组12块1024×10，合计24块。
        .clk(clk),.reset(reset),.rd_valid(2'b11),.rd_idx(ram_rd_idx),.rd_data(compact_read), // 返回一拍，不添加数据寄存器。
        .wr_valid(ram_wr_valid),.wr_idx(ram_wr_idx),.wr_data(compact_write)); // 固定物理组。
    wire [9:0] wr_addr=body_base(cfg_ring,wr_slot_in)+10'(wr_col); // Body地址保留原环基址。
    logic [1:0] rd_slot[3];logic [9:0] tap_addr[3];logic [2:0] front_slot; // 三个Body地址或前端物理组。
    wire owns_two=BANK_SEL==0 ? req_row[0] : ~req_row[0]; // 行奇偶分片关系不变。
    assign rd_slot[1]=req_slot_in; // 中心槽来自调度。
    assign rd_slot[0]=req_slot_in==0 ? 2'd2 : req_slot_in-1'b1; // 上槽循环。
    assign rd_slot[2]=req_slot_in==2 ? 2'd0 : req_slot_in+1'b1; // 下槽循环。
    always_comb begin // 反射先确定真实行，物理地址只用连线和原有基址加法。
        for(int t=0;t<3;t++)begin // 三个固定抽头。
            automatic logic [ROW_W-1:0] r; // 仅窄行号。
            r=req_row+ROW_W'(t)-1'b1;front_slot[t]=r[1]; // 前端真实行对应物理组。
            tap_addr[t]=body_base(cfg_ring,rd_slot[t])+10'(req_col); // Body两组同地址。
        end // 三抽头结束。
        if(req_row==0)begin front_slot[0]=front_slot[2];tap_addr[0]=tap_addr[2];end // 首行逐层reflect。
        if(req_last_row)begin front_slot[2]=front_slot[0];tap_addr[2]=tap_addr[0];end // 末行逐层reflect。
    end // 地址确定结束。
    logic fetch_q;logic [1:0] sent_q,ret_tap_q;logic [9:0] later_addr_q[2]; // Body仍然只保存两条窄地址。
    logic front_pending_q,front_two_q;logic [2:0] front_slot_q; // 前端返回归属标签。
    wire body_issue=!cfg_front && ((!fetch_q && req_valid) || (fetch_q && sent_q<3)); // 接受沿即发首读。
    wire [9:0] body_addr=!fetch_q ? tap_addr[0] : sent_q==1 ? later_addr_q[0] : later_addr_q[1]; // 三拍原地址。
    always_ff @(posedge clk)begin // 数据不保存，只有控制标签。
        if(reset)begin fetch_q<=0;sent_q<=0;ret_tap_q<=0;later_addr_q[0]<=0;later_addr_q[1]<=0;front_pending_q<=0;front_two_q<=0;front_slot_q<=0;end // 仅复位窄控制。
        else if(cfg_front)begin // 前端每拍接受一组，次拍直接返回。
            fetch_q<=0;sent_q<=0;front_pending_q<=req_valid; // Body状态排空。
            if(req_valid)begin front_two_q<=owns_two;front_slot_q<=front_slot;end // 地址半区归属锁存。
        end else begin // Body三个抽头读出。
            front_pending_q<=0; // 不跨相位保留前端返回。
            if(!fetch_q && req_valid)begin fetch_q<=1;sent_q<=1;ret_tap_q<=0;later_addr_q[0]<=tap_addr[1];later_addr_q[1]<=tap_addr[2];end // 首读与两条地址保存。
            else if(fetch_q && sent_q<3)begin ret_tap_q<=sent_q;sent_q<=sent_q+1'b1;end // 第二、第三读。
            else if(fetch_q)begin fetch_q<=0;sent_q<=0;end // 最后返回沿之后释放。
        end // Body状态结束。
    end // 窄流水结束。
    always_comb begin // 两组物理RAM读口，前端两行各占一个读口。
        ram_rd_idx[0]=0;ram_rd_idx[1]=0; // 无请求时地址无关。
        if(cfg_front)begin // 前端列直接是像素地址，无奇偶列选择。
            if(owns_two)begin ram_rd_idx[front_slot[0]]=10'(req_col);ram_rd_idx[front_slot[2]]=10'(req_col);end // reflect同组时自然取同一地址。
            else ram_rd_idx[front_slot[1]]=10'(req_col); // 中间行。
        end else if(body_issue)begin ram_rd_idx[0]=body_addr;ram_rd_idx[1]=body_addr;end // Body两组同步读完整像素。
    end // 读口结束。
    always_comb begin // 原生写口，不保存偶列、不拆解已配好的整字。
        ram_wr_valid=0;ram_wr_idx[0]=wr_addr;ram_wr_idx[1]=wr_addr; // Body共同地址。
        ram_wr_data[0]=cfg_front ? fw_data[127:0] : body_storage_word[127:0]; // 低通道组或前端完整像素。
        ram_wr_data[1]=cfg_front ? fw_data[127:0] : body_storage_word[255:128]; // 高通道组或另一前端行。
        if(cfg_front && fw_valid)begin ram_wr_valid[fw_row[1]]=1;ram_wr_idx[fw_row[1]]=10'(fw_col);end // 每个像素直接写一次。
        else if(!cfg_front && wr_valid)ram_wr_valid=2'b11; // Body完整像素同拍写两组。
    end // 写口结束。
    always_comb begin // 保留原抽头编号和有效时刻，数据宽度由相位约定。
        fill_valid=0;fill_group[0]=ret_tap_q;fill_group[1]=ret_tap_q;fill_done=0; // 控制默认无返回。
        fill_word[0]=cfg_front ? {128'b0,ram_rd_data[0]} : {ram_rd_data[1],ram_rd_data[0]}; // 前端单像素或Body整像素。
        fill_word[1]={128'b0,ram_rd_data[1]}; // 前端下抽头原生128位。
        if(cfg_front && front_pending_q)begin fill_valid=front_two_q ? 2'b11 : 2'b01;fill_group[0]=front_two_q ? 0 : 1;fill_group[1]=2;fill_done=1;end // 前端一拍完整返回。
        else if(!cfg_front && fetch_q)begin fill_valid=1;fill_done=sent_q==3;end // Body依次三个抽头。
    end // 装填结束。
    assign front_slots=front_slot_q; // 只传三位行组标签，数据不排序。
    assign wr_ready=1;assign fw_ready=1;assign req_ready=cfg_front || !fetch_q; // 吞吐和原模块一致。
    always_ff @(posedge clk)begin // 沿用模型有效输入范围错误检查。
        if(reset)protocol_error<=0; // 清错误。
        else begin // 错误粘滞。
            if(req_valid && (cfg_front ? req_col>=COL_W'(FR_COL_MAX) : req_col>=COL_W'(ring_pitch(cfg_ring))))protocol_error<=1; // 列范围。
            if(req_valid && req_last_row && req_row==0)protocol_error<=1; // 高度至少二。
            if(wr_valid && !cfg_front && wr_col>=COL_W'(ring_pitch(cfg_ring)))protocol_error<=1; // Body写范围。
            if(cfg_front && fw_valid && fw_row[0]!=1'(BANK_SEL))protocol_error<=1; // 前端写错片。
        end // 错误更新结束。
    end // 错误流水结束。
endmodule // 原生128位布局研究结束。
