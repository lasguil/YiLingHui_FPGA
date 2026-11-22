// 协议契约：DMA就绪按客户静态端口表判定，与原端口数组判据逐拍等价；未提交请求不预占端口，不阻塞为其装入源行的DMA。
// 协议契约：删除通用fill_word，V直接消费rsp_front_word物理H0/H2，RGB消费rsp_rgb_word；fill_valid/group/done仍定义返回拍。
// 协议契约：rsp_half只供Decoder-H，固定组1 A口；Down使用两条物理整字口，Stem使用rsp_input_word，禁止把rsp_half当通用返回。
// 协议契约：X0与Head固定读组1，rsp_word直连组1；Down额外直连组0，输入段只消费rsp_input_word低128位。
// 协议契约：两组1024×128真双口，共26RAM10；每端口每拍读或写，计算优先，DMA只在两个目标端口均空闲时接受。
// D的C16写口逐像素128位有效，Reduce只写未放大源像素；head保存四个C4源像素，nearest在消费端恢复。
// V固定两拍读H0/H2并直接装偶奇窗口，无512位H暂存；残差晚读及逻辑reflect/置换顺序保持。
// 单字返回回压会暂停相关物理输出的读写；DMA可被回压，计算结果不可回压；层切换前排空。
module ngm_bank_ctrl_d #(                                      // D 片控制器参数。
    parameter int unsigned ROW_W = 11,                          // 真实行号位宽。
    parameter int unsigned COL_W = 11                           // 真实列号位宽。
) (                                                             // 端口列表开始。
    input logic clk,                                             // 工作时钟。
    input logic reset,                                           // 同步复位。
    input logic [COL_W-1:0] tail_base, // 本strip保存的Body3首列，运行期间保持。
    input logic cfg_front,                                       // 前端暂存相位。
    input logic wr_valid,                                        // C16 原生单像素128位写有效。
    output logic wr_ready,                                       // C16 原生像素结果可接收。
    input logic [1:0] wr_kind,                                   // 1=H、2=Head 输入、3=前端；RES 走另一源字口。
    input logic [ROW_W-1:0] wr_row,                               // 写入真实行号。
    input logic [COL_W-1:0] wr_x,                                 // C16 像素列。
    input logic [1:0] wr_slot,                                    // H 物理行槽。
    input logic [255:0] wr_data,                                  // 仅低128位有效，高128位不存入D。
    input logic wr_last,                                         // 本拍为一行最后一个原生像素。
    input logic wr_begin, // 首个原生像素；接受时废弃该目标行旧标签。
    input logic word_valid,                                      // Reduce原始C16源像素或Head四个C4源像素有效。
    output logic word_ready,                                     // 共用128位源字写口可接收。
    input logic word_kind,                                       // 0=Decoder RES、1=RGB 行。
    input logic [ROW_W-1:0] word_row,                             // nearest目标偶行坐标；物理保存行号为此值除二。
    input logic [COL_W-1:0] word_x,                               // nearest目标偶列坐标；D换算到紧凑源地址。
    input logic [1:0] word_slot,                                  // RGB三条Head源行槽；RES 忽略。
    input logic [255:0] word_data,                                // 低128位为未复制的源数据，高128位不存入D。
    input logic word_last,                                       // 该源行最后一笔128位写入。
    input logic dma_valid,                                       // Body的X0整字或Stem输入段DDR拍有效。
    output logic dma_ready,                                      // X0 整字预取可接收。
    input logic [ROW_W-1:0] dma_row,                              // 预取真实行号。
    input logic [COL_W-1:0] dma_x, // 首个实际DMA字的真实列，建立X0局部零点。
    input logic [7:0] dma_word,                                   // Body为0..131；前端上行段为0..23。
    input logic [255:0] dma_data,                                 // X0 的 C32 数据。
    input logic dma_last,                                        // 预取行最后一个字。
    input logic req_valid,                                       // 读请求有效。
    output logic req_ready,                                      // 读请求可接收。
    input logic [2:0] req_kind,                                   // 0=Decoder-H、1=Decoder-V、2=RGB、3=X0、4=前端、5=Head、6=输入上行段。
    input logic [ROW_W-1:0] req_row,                              // 请求的中心真实行号。
    input logic [COL_W-1:0] req_x,                                // 像素列或 RGB 四点组首列。
    input logic [COL_W-1:0] req_width,                            // RGB 有效宽度，最大 496。
    input wire logic [2:0][1:0] req_tap_slot,                     // 上中下行的 H/RGB 物理槽。
    input wire logic [2:0][ROW_W-1:0] req_tap_row,                // 上中下行的真实行号。
    input logic skip_req_valid, // Decoder-V实际结果对齐的RES请求，偶列每对只读一次。
    output logic skip_req_ready, // RES优先读时隙可接受。
    input logic [ROW_W-1:0] skip_req_row, // Decoder-V真实结果行。
    input logic [COL_W-1:0] skip_req_x, // Decoder-V真实偶像素列。
    output logic rsp_valid,                                      // 单字读返回有效。
    input logic rsp_ready,                                       // 单字读返回被接收。
    output logic [2:0] rsp_kind,                                 // 单字返回类型。
    output logic [ROW_W-1:0] rsp_row,                             // 单字返回真实行。
    output logic [COL_W-1:0] rsp_x,                               // 单字返回列号。
    output wire [255:0] rsp_front_word, // 组0两个原生端口直通。
    output wire [127:0] rsp_input_word, // 输入段固定组0 A口。
    output logic [255:0] rsp_word,                                // 单字返回整字。
    output logic [127:0] rsp_half,                                // Decoder-H固定128位源像素。
    output logic [1:0] fill_valid,                                // 窗口两个装填口有效位。
    output logic [1:0][1:0] fill_group,                           // 两个口的八格组号。
    output wire [127:0] rsp_rgb_word, // RGB两行源字各自在原生返回拍直连，不经统一装窗数据口。
    output wire [2:0] rsp_v_tags, // V三抽头到H0/H2的窄物理标签。
    output logic fill_done,                                      // 当前像素或 RGB 组装完。
    output logic [ROW_W-1:0] fill_row,                            // 当前装填的中心行。
    output logic [COL_W-1:0] fill_x,                              // 当前装填的像素列或组首列。
    output logic v_skip_valid,                                   // Decoder-V结果对齐的残差有效。
    output logic [127:0] v_skip,                                  // Decoder-V 当前像素 residual。
    output logic protocol_error                                  // 错误锁存到复位。
);                                                              // 端口列表结束。

    localparam logic [2:0] RD_H=0,RD_V=1,RD_RGB=2,RD_X0=3,RD_FRONT=4,RD_HEAD=5,RD_INPUT=6; // 固定客户表。
    wire [COL_W-1:0] dec_base=COL_W'(tail_base<<1),rgb_base=COL_W'(tail_base<<2); // 坐标只做固定倍数换算。
    wire [COL_W-1:0] wx=cfg_front ? wr_x : wr_x-dec_base; // C16局部列。
    wire [COL_W-1:0] ox=word_x-(word_kind ? rgb_base : dec_base); // 两个源行写口的局部列。
    logic [8:0] x0_lo_q;
    wire [COL_W-1:0] qx=(req_kind==RD_FRONT || req_kind==RD_INPUT) ? req_x :
        req_kind==RD_X0 ? COL_W'(9'(req_x)-x0_lo_q) : req_x-(req_kind==RD_RGB ? rgb_base : dec_base);
    logic [1:0] en[2],we[2];logic [9:0] addr[2][2];logic [127:0] din[2][2];wire [127:0] dout[2][2]; // 两组真双口，每口可读或写。
    ngm_d_dual128_ram u_act_ram(.clk,.en,.we,.addr,.din,.dout); // 26RAM10，四路128位寻址。
    logic front_q,x0_valid_q;logic [ROW_W-1:0] x0_row_q; // 相位和X0提交。
    logic [2:0] h_valid_q,rgb_valid_q;logic [ROW_W-1:0] h_row_q[3],rgb_row_q[3]; // 工作行标签。
    logic [1:0] res_valid_q,front_valid_q;logic [ROW_W-1:0] res_row_q[2],front_row_q[2]; // 两个源行标签。
    logic rsp_valid_q;logic [2:0] rsp_kind_q;logic [ROW_W-1:0] rsp_row_q;logic [COL_W-1:0] rsp_x_q; // 返回只有窄元数据。
    logic v_second_q,v_even_q,v_odd_q;logic [ROW_W-1:0] v_row_q,odd_row_q;logic [COL_W-1:0] v_x_q,odd_x_q;logic [2:0][1:0] v_slot_q,odd_slot_q; // 原两点返回节拍。
    logic rgb_phase_q,rgb_ret_q;logic rgb_ret_group_q;logic [ROW_W-1:0] rgb_row_q_center;logic [COL_W-1:0] rgb_x_q,rgb_width_q;logic [1:0] rgb_next_slot_q; // RGB两源行流水。
    logic skip_read_q,skip_even_q,skip_odd_q;logic [127:0] skip_hold_q; // RES晚读仍保持原结果消费拍。
    logic tag_ok,single_fire,v_fire,rgb_fire;wire held=rsp_valid_q && !rsp_ready; // 读回压保持两个端口输出。
    wire skip_fire=skip_req_valid && skip_req_ready; // 固定结果读授权。
    wire calc_fire=wr_valid && wr_ready || word_valid && word_ready; // 单阵列每拍一笔128位结果。
    logic calc_bank;logic [9:0] calc_addr;logic [127:0] calc_data; // 生产者只写物理B口。
    wire dma_fire=dma_valid && dma_ready; // DMA只有全部所需端口空闲才接受。
    function automatic [9:0] rgb_addr(input logic [1:0] slot,input logic [5:0] w); // RGB行槽布局。
        rgb_addr=(slot==0 ? 10'd496 : slot==1 ? 10'd558 : 10'd620)+10'(w); // 紧凑Head源字。
    endfunction // RGB地址结束。
    function automatic [127:0] rgb_pack(input logic [127:0] a,b,input logic [COL_W-1:0] x,width); // 两相邻源字固定格选择。
        logic [255:0] pair;integer src;pair={b,a};rgb_pack=0; // 仅测试可达四点起始相位。
        for(int c=0;c<4;c++)begin // 四个源像素位置，生成期展开。
            if(x==0)src=c==0 ? 0 : c-1; // 首组真实reflect映射零零一二。
            else src=(x[2] ? 1 : 3)+c; // 普通组左源偏移只有一或三。
            if(c==3 && x+COL_W'(4)==width)src=x[2] ? 3 : 5; // 真实右帧边恢复reflect，不读取未写源。
            case(src) // 八条常量32位连线，不使用可变宽移位器。
                0:rgb_pack[c*32+:32]=pair[0+:32];1:rgb_pack[c*32+:32]=pair[32+:32]; // 首两个源。
                2:rgb_pack[c*32+:32]=pair[64+:32];3:rgb_pack[c*32+:32]=pair[96+:32]; // 当前字后两个源。
                4:rgb_pack[c*32+:32]=pair[128+:32];5:rgb_pack[c*32+:32]=pair[160+:32]; // 下一字前两个源。
                6:rgb_pack[c*32+:32]=pair[192+:32];default:rgb_pack[c*32+:32]=pair[224+:32]; // 下一字后两个源。
            endcase // 固定源选择结束。
        end // 四格结束。
    endfunction // RGB拼装结束。
    wire tag_res=res_valid_q[req_row[1]] && res_row_q[req_row[1]]==(req_row>>1); // H/单字客户只比较其自己的真实源行。
    wire tag_head=h_valid_q[1] && h_row_q[1]==req_row; // 固定组1工作行。
    wire tag_x0=x0_valid_q && x0_row_q==req_row; // 固定X0或输入段。
    wire tag_front=front_valid_q[req_row[0]] && front_row_q[req_row[0]]==req_row; // 前端按真实行提交。
    wire single_gate=req_valid && !reset && cfg_front==front_q && !held && !v_second_q && !rgb_phase_q && !v_even_q && !v_odd_q && !skip_req_valid && cfg_front==(req_kind==RD_FRONT || req_kind==RD_INPUT); // 只描述可能占读端口的单字授权。
    wire group1_single=single_gate && ((req_kind==RD_H && tag_res) || (req_kind==RD_HEAD && tag_head) || (req_kind==RD_X0 && tag_x0) || (req_kind==RD_FRONT && req_row[0] && tag_front)); // 组1从不接V/RGB数据读，不经过其标签选择。
    wire group0_b_single=single_gate && req_kind==RD_FRONT && !req_row[0] && tag_front; // 输入段只读A口，不阻塞前端DMA的B口。
    wire group1_busy=group1_single || skip_fire || (calc_fire && calc_bank); // 尾部DMA要A/B均空闲。
    wire group0_b_busy=group0_b_single || v_second_q || v_even_q || rgb_fire || rgb_phase_q || (calc_fire && !calc_bank); // 前端DMA只需B口空闲。
`ifdef SIM_ASSERT // 对照实际端口表检查新窄授权，不能把端口冲突默默藏起来。
    logic port_block_ref; // 只存在于模拟，记录DMA授权前的物理端口占用。
`endif // 影子结束。
    always_comb begin // 按客户固定真实行归属。
        tag_ok=0; // 默认拒绝未提交行。
        case(req_kind) // 可达客户表。
            RD_H:tag_ok=tag_res; // H读原始RES源行。
            RD_HEAD:tag_ok=tag_head; // Head只读V工作行。
            RD_X0,RD_INPUT:tag_ok=tag_x0; // 一行预取或输入段。
            RD_FRONT:tag_ok=tag_front; // 前端真实行。
            RD_V:begin // 仍验证每个逻辑抽头的真实归属，不假定工具删除比较。
                tag_ok=res_valid_q[req_row[1]] && res_row_q[req_row[1]]==(req_row>>1); // 残差也必须已提交。
                for(int t=0;t<3;t++)if((req_tap_slot[t]!=0 && req_tap_slot[t]!=2) || !h_valid_q[req_tap_slot[t]] || h_row_q[req_tap_slot[t]]!=(req_tap_row[t]>>1))tag_ok=0; // 两个物理源槽。
            end // V归属检查结束。
            RD_RGB:begin tag_ok=1;for(int t=0;t<3;t+=2)if(req_tap_slot[t]>2 || !rgb_valid_q[req_tap_slot[t]] || rgb_row_q[req_tap_slot[t]]!=(req_tap_row[t]>>1))tag_ok=0;end // 两个独立Head源行。
            default:tag_ok=0; // 未定义客户。
        endcase // 客户表结束。
    end // 行标签检查结束。
    assign req_ready=!reset && cfg_front==front_q && cfg_front==(req_kind==RD_FRONT || req_kind==RD_INPUT) && !held && !v_second_q && !rgb_phase_q && (req_kind==RD_V || (!v_even_q && !v_odd_q)) && !skip_req_valid && tag_ok; // 不额外减少V稳态吞吐。
    assign single_fire=req_valid && req_ready && req_kind!=RD_V && req_kind!=RD_RGB; // 单字请求。
    assign v_fire=req_valid && req_ready && req_kind==RD_V;assign rgb_fire=req_valid && req_ready && req_kind==RD_RGB; // 两种窗口请求。
    assign skip_req_ready=!reset && !cfg_front && cfg_front==front_q && !held && res_valid_q[skip_req_row[1]] && res_row_q[skip_req_row[1]]==(skip_req_row>>1); // V残差固定组1 A口。
    assign wr_ready=!reset && cfg_front==front_q && !held;assign word_ready=wr_ready && !cfg_front; // 结果为原生128位，无偶奇配对条件。
    always_comb begin // 生产者静态归属，只有窄地址选择。
        calc_bank=wr_kind==2 ? 1'b1 : cfg_front ? wr_row[0] : 1'b0; // V写组1，H写组0，前端按行parity。
        calc_addr=cfg_front ? 10'(wx) : wr_kind==2 ? 10'(wx) : (wr_slot==2 ? 10'd248 : 10'd0)+10'(wx); // H0/H2与工作行。
        calc_data=wr_data[127:0]; // 原生单像素。
        if(word_valid)begin calc_bank=!word_kind;calc_addr=word_kind ? rgb_addr(word_slot,6'(ox>>3)) : (word_row[1] ? 10'd372 : 10'd248)+10'(ox>>1);calc_data=word_data[127:0];end // Reduce写源像素，Head写四C4源像素。
    end // 计算写地址结束。
    always_comb begin // 四端口固定读客户表，B口写在无读时才获授权。
        for(int g=0;g<2;g++)for(int k=0;k<2;k++)begin en[g][k]=0;we[g][k]=0;addr[g][k]=0;din[g][k]=0;end // 空闲原生保持输出。
        if(single_fire)begin // 请求类型只选择窄地址，不排序数据。
            case(req_kind) // 单字物理表。
                RD_H:begin en[1][0]=1;addr[1][0]=(req_row[1] ? 10'd372 : 10'd248)+10'(qx>>1);end // H只读一个源像素。
                RD_HEAD:begin en[1]=2'b11;addr[1][0]=10'(qx);addr[1][1]=10'(qx)+1'b1;end // 工作行两个相邻像素。
                RD_X0:begin en[1]=2'b11;addr[1][0]=10'd496+10'(qx<<1);addr[1][1]=10'd497+10'(qx<<1);end // 两半共用一组真双口。
                RD_INPUT:begin en[0][0]=1;addr[0][0]=10'd960+10'(qx);end // 上行RGB段原始拍。
                default:begin en[req_row[0]]=2'b11;addr[req_row[0]][0]=10'(qx)&10'h3fe;addr[req_row[0]][1]=(10'(qx)&10'h3fe)+1'b1;end // 前端相邻两像素。
            endcase // 单字表结束。
        end // 单字读取结束。
        if(v_second_q || v_even_q)begin en[0]=2'b11;addr[0][0]=10'(v_x_q)+(v_even_q ? 10'd1 : 10'd0);addr[0][1]=10'd248+10'(v_x_q)+(v_even_q ? 10'd1 : 10'd0);end // 每拍同时读H0/H2，偶奇像素连续两拍。
        if(rgb_fire || rgb_phase_q)begin // 每行最多两个相邻Head字，两个读口归属恒定。
            en[0]=2'b11;addr[0][0]=rgb_addr(rgb_fire ? req_tap_slot[0] : rgb_next_slot_q,6'(((rgb_fire ? qx : rgb_x_q)==0 ? COL_W'(0) : (rgb_fire ? qx : rgb_x_q)-1'b1)>>3)); // 第一个源字固定A口。
            addr[0][1]=addr[0][0]+1'b1; // 第二个源字固定B口，末组不会消费越界字的数据。
        end // RGB发读结束。
        if(skip_fire)begin en[1][0]=1;addr[1][0]=(skip_req_row[1] ? 10'd372 : 10'd248)+10'((skip_req_x-dec_base)>>1);end // RES不展开nearest。
        if(calc_fire)begin en[calc_bank][1]=1;we[calc_bank][1]=1;addr[calc_bank][1]=calc_addr;din[calc_bank][1]=calc_data;end // 单阵列结果固定B口写。
`ifdef SIM_ASSERT // 在DMA自身占端口之前取影子值。
        port_block_ref=cfg_front ? en[0][1] : en[1]!=0; // 与旧授权公式逐拍对照。
`endif // 物理影子结束。
        dma_ready=!reset && cfg_front==front_q && !held && (cfg_front ? dma_word<24 && !group0_b_busy : dma_word<132 && !group1_busy); // 真双口写刷新输出，持有返回时不能改写。
        if(dma_fire)begin // DMA只占尚未使用的物理端口。
            if(cfg_front)begin en[0][1]=1;we[0][1]=1;addr[0][1]=10'd960+10'(dma_word);din[0][1]=dma_data[127:0];end // 前端只用低128位。
            else begin en[1]=2'b11;we[1]=2'b11;addr[1][0]=10'd496+10'(dma_word<<1);addr[1][1]=10'd497+10'(dma_word<<1);din[1][0]=dma_data[127:0];din[1][1]=dma_data[255:128];end // X0两半同拍写。
        end // DMA写结束。
    end // 四端口调度结束。
    always_ff @(posedge clk)begin // 标签和各固定流水状态。
        if(reset)begin // 无效数据不用复位，全部有效位清零。
            front_q<=0;x0_valid_q<=0;x0_row_q<=0;x0_lo_q<=0;h_valid_q<=0;rgb_valid_q<=0;res_valid_q<=0;front_valid_q<=0; // 行提交清零。
            for(int s=0;s<3;s++)begin h_row_q[s]<=0;rgb_row_q[s]<=0;end // 行标签复位。
            for(int s=0;s<2;s++)begin res_row_q[s]<=0;front_row_q[s]<=0;end // 双行标签复位。
            rsp_valid_q<=0;rsp_kind_q<=0;rsp_row_q<=0;rsp_x_q<=0; // 单字返回控制。
            v_second_q<=0;v_even_q<=0;v_odd_q<=0;v_row_q<=0;odd_row_q<=0;v_x_q<=0;odd_x_q<=0;v_slot_q<=0;odd_slot_q<=0; // V两个像素元数据。
            rgb_phase_q<=0;rgb_ret_q<=0;rgb_ret_group_q<=0;rgb_row_q_center<=0;rgb_x_q<=0;rgb_width_q<=0;rgb_next_slot_q<=0; // RGB源行控制。
            skip_read_q<=0;skip_even_q<=0;skip_odd_q<=0;protocol_error<=0; // 结果对齐及错误复位。
        end else begin // 正常固定层运行。
            front_q<=cfg_front; // 保存相位。
            if(dma_fire && !cfg_front && dma_word==0)x0_lo_q<=9'(dma_x);
            if(front_q!=cfg_front)begin x0_valid_q<=0;front_valid_q<=0;h_valid_q<=0;rgb_valid_q<=0;res_valid_q<=0;end // 相位切换废弃旧内容。
            if(wr_valid && wr_ready)begin // 每个C16像素都真实落字。
                if(wr_kind==3)begin if(wr_begin)front_valid_q[wr_row[0]]<=0;if(wr_last)begin front_valid_q[wr_row[0]]<=1;front_row_q[wr_row[0]]<=wr_row;end end // 前端提交。
                else begin if(wr_begin)h_valid_q[wr_kind==2 ? 1 : wr_slot]<=0;if(wr_last)begin h_valid_q[wr_kind==2 ? 1 : wr_slot]<=1;h_row_q[wr_kind==2 ? 1 : wr_slot]<=wr_kind==2 ? wr_row : wr_row>>1;end end // H或V工作行提交。
            end // C16写提交结束。
            if(word_valid && word_ready)begin // 紧凑Reduce或Head源行写。
                if(word_kind)begin if(ox==0)rgb_valid_q[word_slot]<=0;if(word_last)begin rgb_valid_q[word_slot]<=1;rgb_row_q[word_slot]<=word_row>>1;end end // Head源行。
                else begin if(ox==0)res_valid_q[word_row[1]]<=0;if(word_last)begin res_valid_q[word_row[1]]<=1;res_row_q[word_row[1]]<=word_row>>1;end end // Reduce源行。
            end // 原生源行写提交结束。
            if(dma_fire)begin if(dma_word==0)x0_valid_q<=0;if(dma_last)begin x0_valid_q<=1;x0_row_q<=dma_row;end end // DMA行末提交。
            if(!rsp_valid_q || rsp_ready)begin rsp_valid_q<=single_fire;if(single_fire)begin rsp_kind_q<=req_kind;rsp_row_q<=req_row;rsp_x_q<=req_x;end end // 单字原生保持。
            v_second_q<=v_fire;v_even_q<=v_second_q;v_odd_q<=v_even_q; // 与原两点装窗拍一致，无宽H暂存。
            if(v_fire)begin v_row_q<=req_row;v_x_q<=qx;v_slot_q<=req_tap_slot;end // 当前偶点标签。
            if(v_even_q)begin odd_row_q<=v_row_q;odd_x_q<=v_x_q+1'b1;odd_slot_q<=v_slot_q;end // 下一对可覆盖当前标签，旧奇点仍独立。
            rgb_ret_q<=rgb_fire || rgb_phase_q;rgb_ret_group_q<=rgb_phase_q;rgb_phase_q<=rgb_fire; // 两行连续读取。
            if(rgb_fire)begin rgb_row_q_center<=req_row;rgb_x_q<=qx;rgb_width_q<=req_width;rgb_next_slot_q<=req_tap_slot[2];end // RGB组标签。
            skip_read_q<=skip_fire;skip_even_q<=skip_read_q;skip_odd_q<=skip_even_q;if(skip_read_q)skip_hold_q<=dout[1][0]; // 仍在原八拍结果时刻提供残差。
            if(req_valid && !tag_ok)protocol_error<=1; // 不允许陈旧行读取。
            if((wr_valid || word_valid || req_valid || dma_valid) && cfg_front!=front_q)protocol_error<=1; // 切换沿须无客户。
            if(wr_valid && word_valid)protocol_error<=1; // 单阵列结果类别必须互斥。
            if(wr_valid && (wr_kind==0 || cfg_front!=(wr_kind==3) || (!cfg_front && (wx>=248 || (wr_kind==1 && wr_slot!=0 && wr_slot!=2))) || (cfg_front && wx>=960)))protocol_error<=1; // 固定写表非法输入。
            if(word_valid && (cfg_front || (word_kind ? word_slot>2 || ox>=496 || ox[2:0]!=0 : ox>=248 || ox[0])))protocol_error<=1; // 原生源字形状。
            if(req_valid && (req_kind>RD_INPUT || cfg_front!=(req_kind==RD_FRONT || req_kind==RD_INPUT)))protocol_error<=1; // 请求阶段必须正确。
        end // 正常时序结束。
    end // 状态寄存器结束。
    assign rsp_valid=rsp_valid_q;assign rsp_kind=rsp_kind_q;assign rsp_row=rsp_row_q;assign rsp_x=rsp_x_q; // 单字返回元数据。
    assign rsp_word={dout[1][1],dout[1][0]};assign rsp_front_word={dout[0][1],dout[0][0]};assign rsp_input_word=dout[0][0]; // Down/Head/X0按端口固定拼字。
    assign rsp_half=dout[1][0]; // H原生源不再半字选择。
    always_comb begin // 两个窗口出口只汇聚固定源。
        fill_valid=0;fill_group=0;fill_done=0;fill_row=0;fill_x=0; // 默认无效。
        if(v_even_q || v_odd_q)begin // H0/H2已经分别由物理A/B口读出当前像素。
            fill_valid=2'b11;fill_group[0]=0;fill_group[1]=1;fill_done=1; // 两向量不经过256位保持或半字选择。
            fill_row=v_even_q ? v_row_q : odd_row_q;fill_x=dec_base+(v_even_q ? v_x_q : odd_x_q); // 返回真实坐标。
        end else if(rgb_ret_q)begin fill_valid[0]=1;fill_group[0]={1'b0,rgb_ret_group_q};fill_done=rgb_ret_group_q;fill_row=rgb_row_q_center;fill_x=rgb_base+rgb_x_q;end // 两源行RGB装填。
    end // 窗口返回结束。
    assign rsp_rgb_word=rgb_pack(dout[0][0],dout[0][1],rgb_x_q,rgb_width_q); // 仅在RGB有效拍解释，空闲不做宽清零。
    for(genvar t=0;t<3;t++)assign rsp_v_tags[t]=v_even_q ? v_slot_q[t][1] : odd_slot_q[t][1]; // 元数据与偶奇窗口同拍。
    assign v_skip_valid=skip_even_q || skip_odd_q;assign v_skip=skip_hold_q; // 两个nearest消费者共用一个源像素。
`ifdef SIM_ASSERT // 默认回归检查真双口冲突，不能依赖面积报告代替带宽判断。
    always @(posedge clk)if(!reset)begin // 每次端口授权检查。
        if(cfg_front==front_q && !held && dma_word<(cfg_front ? 8'd24 : 8'd132) && dma_ready!==!port_block_ref)$fatal(1,"D128 reservation mismatch"); // 新客户表必须与真实占用严格相同。
        if(skip_req_valid && (!skip_req_ready || skip_req_x[0]))$fatal(1,"D128 residual missed slot"); // 固定結果流水不可等待。
        if(calc_fire && ((calc_bank==0 && (v_second_q || v_even_q || rgb_fire || rgb_phase_q)) || (calc_bank==1 && single_fire && req_kind!=RD_H && req_kind!=RD_INPUT)))$fatal(1,"D128 compute read/write port conflict"); // 计算B写不能覆盖同时B读。
        if(dma_fire && held)$fatal(1,"D128 DMA changed held response"); // 真双口写会改变返回，必须回压DMA。
    end // 端口检查结束。
`endif // 仿真协议结束。
endmodule // D原生四路128位控制器结束。
