/* OPTIMIZATION_NOTE_20261005
 * 窗口压缩约束（2026-10-05）：固定17层中64个恒零bit7删除，实际704条EFX_SRL8。
 * 逻辑窗口仍24格x32位；Stem原始RGB及有符号Head所需bit7必须真实保存，不能全体补零。
 * 其余特征码域依赖上游ReLU/残差clamp；修改层角色或signed特征路径须重算位存活集合。
 * 窗口年龄、槽标签、role_swap与CE必须同拍维护；改布局须连同bank及operand映射一起验证。
 * 宽历史无数据复位，行首装填和有效归属负责屏蔽旧数据；不能在授权前读取。
 * 详见 docs/OPTIMIZATION_CONSTRAINTS.md。
 */
// 协议契约：读地址的C16/C32模式在每个装填沿寄存，首窗完成后才发射；写数据和写使能仍用当拍层号，不改变装填延迟。
// 协议契约：固定17层、24格×32位逻辑窗口，恒零位删除后为704条EFX_SRL8；操作数排列、权重和数值不变。
// C16/C32横向分别将原生128/256位新列同时移入三份现有历史，活动列通过三位读地址保持，不复制宽数据。
// 活动和准备各三个三位年龄；新列移入时已有年龄加一，复制拍只把活动中/右地址给准备左/中。
// 首列reflect把真实第1列同时标作左、右；末列右地址指向活动中列，禁止读帧外列；strip内部边界不reflect。
// role_swap采用计入同拍移入的准备年龄；暂停时不移入、不推进年龄，维持原来的装填和issue拍数。
// 每条新行首窗在使用前重新装入全部实际列并设置准备年龄，不复位宽历史，不读取前一行未授权数据。
// Body-V的A/B原字已在写端完成P32，和Body-H、Reduce、Head共享自然顺序入口；Encoder-V仍按固定P16接物理源。
// Decoder-V保存两个物理H源与三位槽标签；RGB只保存两源行各四个C4像素，均保持基线物理布局。
// Down按两次返回只更新各格低/高字节对；Head范围外裁零；所有非横向字节保留最近两版本和原来的窄CE。
// 两写口仍按组、格、字节授权；非横向同目标口一优先；横向授权粒度必须为完整128/256位原字。
// 横向当前窗最多回看四个真实原字，8深度足够；完成未消费时供数器禁止继续移入新列，所有权由行引擎维持。
module ngm_tap_window #( // 冻结物理尺寸。
    parameter int unsigned BANK_CELLS=24, // 每半24格。
    parameter int unsigned CELL_BITS=32, // 每格四字节。
    parameter int unsigned WORD_CELLS=8, // 每字八格。
    parameter int unsigned PORT_COUNT=2, // 两口装填控制。
    parameter int unsigned GROUP_W=$clog2(BANK_CELLS/WORD_CELLS) // 三组编号。
) ( // 数据源与窄控制分开。
    input logic clk,role_swap, // 时钟与本沿角色翻转授权，不要求另存全局角色。
    input logic [4:0] layer, // 首窗前有效的模型层。
    input logic copy_window,right_reflect,head_padding, // 内部复制与裁零授权。
    input logic [PORT_COUNT-1:0] load_valid, // 装填有效。
    input logic [PORT_COUNT*GROUP_W-1:0] load_group, // 目标八格组。
    input logic [PORT_COUNT*WORD_CELLS-1:0] load_cell_enable, // 每口格使能。
    input logic [CELL_BITS/8-1:0] load_byte_enable, // 字节使能。
    input logic [255:0] d_source_front_word, // Down组0原生并行像素。
    input logic [127:0] d_source_rgb_word, // 紧凑RGB源字。
    input logic [2:0] d_source_v_tags, // 三个逻辑抽头的物理槽。
    input logic [255:0] c_source_word,d_source_word, // 原生单字。
    input logic c_source_odd, // Encoder-H半字位置。
    input logic [127:0] d_source_half,stem_source_word, // 已选半字和Stem输入。
    input logic [511:0] bank_source_word, // 两个固定用途的抽头口。
    output wire [BANK_CELLS*CELL_BITS-1:0] window_cells // 活动窗输出。
); // 接口结束。
    // 横向按真实列历史寻址，其他层按最近两版本寻址，共用原来的每位一条SRL8。
    wire h16=layer==1 || layer==13; // C16横向。
    wire h32=layer==4 || layer==6 || layer==8 || layer==10; // C32横向。
    wire v16=layer==2; // C16竖向。
    wire v32=layer==5 || layer==7 || layer==9 || layer==11; // C32竖向。
    wire rgb=layer==16,down=layer==3,head=layer==15; // 固定布局。
    logic read_h16_q,read_h32_q; // 仅增加两位静态读模式，不增加激活数据寄存器。
    always_ff @(posedge clk)begin read_h16_q<=h16;read_h32_q<=h32;end // 首次装填沿已采样本层，消除层号译码到DSP的组合路径。
    wire horizontal=h16 || h32; // 横向统一历史控制，层间分时。
    wire history_packet=horizontal && (|load_valid) && (!copy_window || (!right_reflect && ((load_valid[0] && load_group[0+:GROUP_W]==(h32 ? 2 : 1) && (h32 || load_cell_enable[0])) || (load_valid[1] && load_group[GROUP_W+:GROUP_W]==(h32 ? 2 : 1) && (h32 || load_cell_enable[8]))))); // 只有新原字到达才移动历史。
    wire [255:0] history_word=v32 ? bank_source_word[255:0] : ((layer==4 || layer==15) ? d_source_word : c_source_word); // 三个空间位置共享一条原字源。
    wire [127:0] history_half=layer==13 ? d_source_half : (c_source_odd ? c_source_word[255:128] : c_source_word[127:0]); // C16整条半字只选一次。
    logic [2:0] active_age_q[3],prepared_age_q[3],prepared_age_next[3],active_age_next[3]; // 三位年龄代替宽复制。
    for(genvar position=0;position<3;position++)begin:g_history_control // 三个逻辑抽头的历史地址。
        localparam int PREVIOUS=position==2 ? 1 : position+1; // 左中来自活动中右，末列reflect来自中列。
        localparam int HALF_GROUP=position==2 ? 1 : 0,HALF_BIT=position==1 ? 4 : 0; // C16左中在组零两半，右在组一低半。
        wire hit32=(load_valid[0] && load_group[0+:GROUP_W]==position) || (load_valid[1] && load_group[GROUP_W+:GROUP_W]==position); // C32整字目标。
        wire hit16=(load_valid[0] && load_group[0+:GROUP_W]==HALF_GROUP && load_cell_enable[HALF_BIT]) || (load_valid[1] && load_group[GROUP_W+:GROUP_W]==HALF_GROUP && load_cell_enable[8+HALF_BIT]); // C16半字目标。
        wire hit=h32 ? hit32 : hit16; // 当前准备抽头授权。
        wire copying=copy_window && (position<2 || right_reflect); // 沿用现有窄复制协议。
        always_comb begin // 先计入同拍移位，再覆盖真实目标。
            prepared_age_next[position]=prepared_age_q[position]+3'(history_packet); // 已有历史随原字推进一格。
            if(hit && horizontal)prepared_age_next[position]=copying ? active_age_q[PREVIOUS]+3'(history_packet) : 3'd0; // 复制只复制地址，新列为最新项。
        end // 准备地址组合结束。
        always_comb begin
            active_age_next[position] = active_age_q[position];
            if(horizontal) begin
                if(role_swap) active_age_next[position] = prepared_age_next[position];
                else if(history_packet) active_age_next[position] = active_age_q[position]+3'd1;
            end
        end
        always_ff @(posedge clk)if(horizontal)begin // 首窗完整赋值，不复位无效历史数据。
            prepared_age_q[position]<=prepared_age_next[position]; // 保存下一准备位置。
            if(role_swap)active_age_q[position]<=prepared_age_next[position]; // 装填和翻转同拍时直接采用新位置。
            else if(history_packet)active_age_q[position]<=active_age_q[position]+3'd1; // 移入时活动抽头的值保持不变。
        end // 历史地址寄存结束。
    end // 三抽头地址结束。
    initial if(BANK_CELLS!=24 || CELL_BITS!=32 || WORD_CELLS!=8 || PORT_COUNT!=2) // 仅展开检查。
        $fatal(1,"fixed model window dimensions"); // 禁止误用为通用窗口。
    for(genvar g=0;g<3;g++)begin:g_group // 固定目标组。
        wire hit0=load_valid[0] && load_group[0+:GROUP_W]==GROUP_W'(g); // 口零命中。
        wire hit1=load_valid[1] && load_group[GROUP_W+:GROUP_W]==GROUP_W'(g); // 口一命中。
        for(genvar half=0;half<2;half++)begin:g_half // 半字四格共用角色标记。
            wire half_ce=(hit0 || hit1) && (hit1 ? load_cell_enable[8+half*4] : load_cell_enable[half*4]); // 模型格使能按半字成组。
            for(genvar pair=0;pair<2;pair++)begin:g_pair // Down低高字节对分别跟踪。
                logic read_latest_q;
                logic [2:0] read_address_q;
                wire read_latest_next = half_ce && load_byte_enable[pair*2] ? role_swap :
                                        role_swap ? ~read_latest_q : read_latest_q;
                // Register the final address, not window data. Use next ages and
                // role state so simultaneous load/swap retains the original cycle.
                always_ff @(posedge clk)begin
                    read_latest_q <= read_latest_next;
                    if(h32) read_address_q <= ~active_age_next[g];
                    else if(h16 && g*8+half*4<12)
                        read_address_q <= ~active_age_next[(g*8+half*4)/4];
                    else read_address_q <= {2'b11,read_latest_next};
                end // 数据不复位，首窗所有使用字节必须先完整装填。
            end // 两个字节对结束。
        end // 两个半字结束。
        for(genvar c=0;c<8;c++)begin:g_cell // 每格只接实际候选。
            localparam int CELL=g*8+c; // 固定格号。
            wire ce=(hit0 || hit1) && (hit1 ? load_cell_enable[8+c] : load_cell_enable[c]); // 窄使能沿用口一优先。
            // Replicate only the narrow SRL read address locally: one 3-bit
            // register per cell and byte pair. syn_keep prevents synthesis
            // from merging equivalent registers across neighboring cells.
            (* syn_keep = 1 *) logic [2:0] local_read_address_q[2];
            for(genvar local_pair=0;local_pair<2;local_pair++)begin:g_local_pair
                wire [2:0] shared_read_address_next = h32 ? ~active_age_next[g] :
                    (h16 && CELL<12) ? ~active_age_next[(g*8+(c/4)*4)/4] :
                    {2'b11,g_half[c/4].g_pair[local_pair].read_latest_next};
                always_ff @(posedge clk)
                    local_read_address_q[local_pair] <= shared_read_address_next;
`ifdef SIM_ASSERT
                always @(negedge clk) begin
                    if (!$isunknown(local_read_address_q[local_pair]) &&
                        local_read_address_q[local_pair] !== g_half[c/4].g_pair[local_pair].read_address_q)
                        $fatal(1,"local window address mismatch g=%0d c=%0d pair=%0d",g,c,local_pair);
                end
`endif
            end
            for(genvar b=0;b<4;b++)begin:g_byte // 固定字节索引。
                wire [7:0] small_sources,vertical16; // 低十二格布局。
                if(CELL<12)begin:g_c16 // C16只有十二格。

                    if(CELL<4)begin:g_stem // Stem只接低四格。
                        assign small_sources=({8{layer==0}} & stem_source_word[CELL*32+b*8+:8]); // 补零由原源提供。
                    end else begin:g_other // 其他格没有Stem候选。
                        assign small_sources=8'd0; // 不建多余来源。
                    end // Stem边界结束。
                    if(CELL<8)begin:g_top_mid // 上中来自口零。
                        assign vertical16={8{v16}} & bank_source_word[(CELL/4)*128+(4*b+c%4)*8+:8]; // P16固定置换。
                    end else begin:g_bottom // 下半字来自口一。
                        assign vertical16={8{v16}} & bank_source_word[256+(4*b+c%4)*8+:8]; // 固定下抽头。
                    end // 竖向布局结束。
                end else begin:g_no_c16 // 高十二格不连C16源。
                    assign small_sources=8'd0;assign vertical16=(CELL==12 && b==0) ? ({8{v16}} & bank_source_word[384+:8]) : 8'd0; // 无这些候选。
                end // C16生成结束。
                wire [7:0] down_source; // 三条1×1布局。
                if(CELL<16)begin:g_down_head // 仅前两组接Down和Head。
                    if(b<2)assign down_source={8{down}} & d_source_front_word[(b%2)*128+CELL*8+:8]; // Down上行恒为2*y，固定物理组0。
                    else assign down_source={8{down}} & d_source_word[(b%2)*128+CELL*8+:8]; // 下行恒为2*y+1，固定物理组1。 // 字节摆位固定，上下行由CE区分。
                end else begin:g_no_down_head // 第三组无此来源。
                    assign down_source=8'd0; // 不建非法候选。
                end // Down和Head结束。
                wire [7:0] dec_physical; // 只在合法格展开数据索引。
                if(CELL<8)begin:g_dec_data // 两条物理源各四格。
                    assign dec_physical={8{layer==14}} & d_source_front_word[(CELL/4)*128+(4*b+c%4)*8+:8]; // P16固定连线。
                end else if(CELL==8 && b==0)begin:g_dec_meta // 三个窄标签。
                    assign dec_physical={8{layer==14}} & {5'b0,d_source_v_tags}; // 元数据随窗存储。
                end else begin:g_dec_unused // 不建立越界候选。
                    assign dec_physical=0; // 没有此来源。
                end // 合法源生成结束。
                wire [7:0] rgb_source; // 仅八个实际RGB源格展开索引。
                if(g<2 && c<4)assign rgb_source={8{rgb}} & d_source_rgb_word[c*32+b*8+:8]; // 固定字节直接进各组。
                else assign rgb_source=0; // 显式不接未使用格。
                wire [7:0] external_data=small_sources | vertical16 | down_source | // 外部源一次合并。
                    dec_physical | // Decoder-V两个物理源及标签。
                    ({8{h32 || v32 || (head && CELL<16 && !head_padding) || (layer==12 && g==0)}} & history_word[c*32+b*8+:8]) | // P32固定置换。
                    rgb_source; // RGB只接口零，无任意端口选择。
                wire [7:0] next_data=external_data | ({8{h16 && CELL<12}} & history_half[(c%4)*32+b*8+:8]); // 两逻辑半区共用一份候选合并。
                wire [2:0] read_address; // 逻辑抽头只改变窄历史地址。
                assign read_address=local_read_address_q[b/2];
                for(genvar bit_id=0;bit_id<8;bit_id++)begin:g_bit // 每位直接例化Titanium存储原语。
                    // Only raw Stem and signed Head-to-RGB sources need an eighth bit.
                    if (bit_id==7 && !(CELL<4 || (g<2 && c<4))) begin : g_zero_sign
                        assign window_cells[CELL*32+b*8+bit_id] = 1'b0;
                    end else begin : g_storage
                    EFX_SRL8 #(.INIT(8'h00)) u_history ( // 原语Q取反，存储取反数据以免增加输出反相器。
                        .D(~(bit_id==7 ? next_data[bit_id] && (layer==0 || rgb) : next_data[bit_id])),.A(read_address),.CLK(clk),.CE((h32 || h16 && CELL<12) ? history_packet : ce && load_byte_enable[b]), // 只有真实装填才移动当前字节。
                        .Q(window_cells[CELL*32+b*8+bit_id]),.Q7() // 只读最新/前版，不用七拍延迟口。
                    ); // 本位两版历史存储结束。
                    end
                end // 八位结束。
            end // 四字节结束。
        end // 八格结束。
    end // 三组结束。
endmodule // 固定模型窗口结束。
