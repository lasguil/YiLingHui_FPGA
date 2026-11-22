// 协议契约：只在实际消费沿允许下一窄请求提前进入memory请求寄存；最早数据返回在翻转之后，不提前覆盖窗口。
// 协议契约：RGB两拍装两个独立源内，每内只装低四格；其他客户节奏不变。
// 数据契约：本模块只产生窄装填控制；C/D原字、bank抽头和Stem数据直接进入窗口。
// 横向复制在窗口内部完成，本模块不接活动窗口或拼接宽总线；装填握手与完成拍不变。
// 协议契约：固定17层的逻辑窗口请求转换为memory_subsystem原字请求和现有窗口写使能。
// row_clear在内命令接受沿有效，layer/row/slot/width/first_x/count在本内保持；不跨内预装窗口。
// 通常三个、Decoder-V四个名额仅保存窄计数；内内1/4/5步进，不设宽历史缓存。
// 横向重叠由窗口内部固定跨格复制；完成未消费时禁止写另一窗，window_take来自真实内引擎。
// 首窗逐半字或整字直接装填；Down上下内分别写每格的低、高两字节；其余写使能全一。
// Encoder/Body/Decoder-V的通道置换是固定连线；残差读独立，C返回在V层无条件消费。
// Decoder-V一次请求返回两窗，先接收两个逻辑名额；RGB须等上窗消费后才启动下一物理事务。
// Stem半字由分段RGB配对器提供；本模块不读取Stem段字，顶层在layer0复用原字请求口。
// Head范围外的双像素字直接装零，不读未保存地址；RGB范围和逐层reflect由已有bank实现。
// reset/row_clear仅清窄控制；所有有效窗口格在使用前写入；不新增激活RAM、DSP或宽数据寄存器。
module ngm_window_source( // 两半窗口的供数与所有权控制。
    input logic clk,reset,row_clear, // 时钟、工作复位与新内命令。
    input logic [4:0] layer, // 当前固定模型层。
    input logic [10:0] row,first_x,first_ab_col,src_width,read_lo,read_hi, // 内描述符保持至排空。
    input logic [9:0] point_count, // 本内逻辑窗口数。
    input logic [1:0] slot, // 当前三内环中心槽。
    input logic win_req_valid, // 内定序器的逻辑请求。
    output logic win_req_ready, // 三个窄名额。
    input logic window_take, // 真实点引擎消费一个完整窗口。
    output logic req_valid, // memory_subsystem原字或整内重放请求。
    input logic req_ready, // 原字请求接受。
    output logic [10:0] req_row,req_x,req_ab_col, // 实际源坐标。
    output logic [1:0] req_slot, // 内槽直通。
    output logic req_subread, // Down上下内或Head两个双像素字。
    output logic [10:0] replay_lo,replay_hi, // Body-H实际真实列读取范围。
    input logic c_rsp_valid,d_rsp_valid, // C/D原生单字返回。
    output logic c_rsp_ready,d_rsp_ready, // 返回直接写窗后才释放。
    input logic [1:0] bank_fill_valid, // AB或D窗口返回。
    input wire logic [1:0][1:0] bank_fill_group, // 对应八格组。
    input logic bank_fill_done, // 当前物理窗口完整。
    input logic stem_valid, // RGB配对器一个PixelUnshuffle结果。
    output logic stem_ready, // 直接写窗时接受。
    output logic [1:0] load_valid, // 现有窗口两写口。
    output logic [1:0][1:0] load_group, // 组号。
    output logic copy_window,right_reflect,head_padding, // 固定格位复制、右边界与Head裁零授权。
    output logic [15:0] load_cell_enable, // 每口八格使能。
    output logic [3:0] load_byte_enable, // 每格四字节使能。
    output logic window_done, // 与最后一次写入同拍。
    output logic idle,protocol_error // 排空和硬件错误保持。
); // 接口结束。
    logic horizontal16,horizontal32,horizontal,replay,vertical,from_c;
    // row_clear occupies the existing SETTLE cycle, before any request.
    always_ff @(posedge clk)begin
        if(reset)begin
            horizontal16<=0;horizontal32<=0;horizontal<=0;
            replay<=0;vertical<=0;from_c<=0;
        end else if(row_clear)begin
            horizontal16<=layer==1 || layer==13;
            horizontal32<=layer==4 || layer==6 || layer==8 || layer==10;
            horizontal<=layer==1 || layer==13 || layer==4 || layer==6 || layer==8 || layer==10;
            replay<=layer==6 || layer==8 || layer==10;
            vertical<=layer==2 || layer==5 || layer==7 || layer==9 || layer==11 || layer==14 || layer==16;
            from_c<=layer==1 || layer==6 || layer==8 || layer==10 || layer==12;
        end
    end
    wire response_valid=from_c ? c_rsp_valid : d_rsp_valid; // 单字返回有效。
    logic [2:0] credits_q,unsent_q; // Decoder-V四个、其他三个逻辑请求，分别计完成与物理发起。
    logic [10:0] fetch_x_q,emit_x_q,dispatch_x_q,dispatch_ab_q,last_request_x_q; // 仅窄源和目标列。
    logic [1:0] boot_q; // 横向首窗0左、1中、2右。
    logic started_q,first_taken_q,loaded_q,copy_done_q,replay_sent_q; // 窗口角色和重放启动状态。
    logic subread_q,read_sub_q;logic [1:0] streams_q; // 当前写子字、查询子字与最多两个多拍原窗窄事务。
    wire raw_pending_q=streams_q!=0; // RGB预发的下一事务也计入，不被旧窗完成误清。
    logic [1:0] singles_q; // 原生RAM输出和请求寄存中的单字在途数量，不保存数据。
    logic [2:0] pair_pending_q; // Decoder-V允许提前排下一对，最多四个窗口返回在途。
    logic response_take,copy_step,head_zero,dispatch_fire; // 当前组合事务。
    wire request_take=win_req_valid && win_req_ready; // 逻辑请求接受。
    wire raw_fire=req_valid && req_ready; // 原字命令接受。
    wire room=!loaded_q && credits_q!=0; // 未消费窗口不能被覆盖。
    wire normal_horizontal=started_q && first_taken_q; // 活动窗在首个消费沿之后才可复制。
    wire reflect_right=emit_x_q==src_width-1'b1; // 最末中心的右列从活动中列取。
    wire [2:0] group_step=layer==15 ? 3'd4 : layer==16 ? 3'd4 : 3'd1; // 固定组步进。
    assign win_req_ready=!reset && !row_clear && (credits_q<(layer==14 ? 3'd4 : 3'd3) || window_done); // 完成沿补入窄名额，Decoder-V提前排下一对。
    assign req_row=row;assign req_slot=slot; // 当前描述符保持。
    assign replay_lo=first_x==0 ? 11'd0 : first_x-1'b1; // 首窗左列只取真实帧内。
    wire [11:0] replay_end={1'b0,first_x}+{2'b0,point_count}+12'd1; // 包含最后一个右抽头。
    assign replay_hi=replay_end>{1'b0,src_width} ? src_width : replay_end[10:0]; // 末帧reflect不读帧外。
    assign idle=credits_q==0 && !loaded_q && !raw_pending_q && pair_pending_q==0 && singles_q==0; // 允许内控制排空。
    assign copy_window=normal_horizontal; // 重叠复制只给窄授权，数据在窗口内部跨半区固定连线。
    assign right_reflect=normal_horizontal && reflect_right; // 末列右抽头从活动窗中列复制。
    assign head_padding=layer==15 && head_zero && singles_q==0; // 裁零只在前面实际返回排空后写入。
    always_comb begin // 窄控制决定写哪一格、哪一字节以及何时消费。
        req_valid=0;req_x=dispatch_x_q;req_ab_col=dispatch_ab_q;req_subread=subread_q; // 默认没有物理请求。
        c_rsp_ready=vertical;d_rsp_ready=0;stem_ready=0; // V的C返回仅属于独立残差口。
        load_valid=0;load_group=0;load_cell_enable=16'hffff;load_byte_enable=4'hf;window_done=0; // 默认不写窗。
        response_take=0;copy_step=0;head_zero=0;dispatch_fire=0; // 组合事件初值。
        if(horizontal)begin // 原读流和窗口写入独立，RAM返回可保持等待空半窗。
            req_x=fetch_x_q;req_ab_col=0;req_subread=0; // 横向使用真实列，AB无客户。
            req_valid=credits_q!=0 && (replay ? !replay_sent_q : fetch_x_q<src_width && fetch_x_q<=last_request_x_q+11'd1); // 重放一内一次，单字源只读已请求的范围。
            if(room && !started_q && response_valid)begin // 首窗直接装目标格，无历史数据暂存。
                response_take=1;load_valid=1; // 当前原字直接写窗。
                if(horizontal32)begin // C32每个位置完整八格。
                    load_group[0]=boot_q; // 左、中、右。
                    if(first_x==0 && boot_q==2)begin load_valid=3;load_group={2'd2,2'd0};end // 第1列同时作左右reflect。
                end else begin // C16每个位置四格，使用逐格CE。
                    load_group[0]=boot_q==2 ? 2'd1 : 2'd0; // 左中同组，右列下一组。
                    load_cell_enable[7:0]=boot_q==1 ? 8'hf0 : 8'h0f; // 保留已经写好的另一半。
                    if(first_x==0 && boot_q==2)begin load_valid=3;load_group={2'd1,2'd0};load_cell_enable=16'h0f0f;end // 第1列同时写左右。
                end // 首窗数据宽度分支结束。
                window_done=boot_q==2; // 右列写入才完成。
            end else if(room && normal_horizontal)begin // 后续窗直接复用活动窗。
                if(horizontal32 && !copy_done_q)begin // 两写口一拍复制中、右整字。
                    load_valid=3;load_group={2'd1,2'd0};copy_step=1; // 下一窗左、中。
                end else if(response_valid || reflect_right)begin // 新右列到达或末帧reflect。
                    if(horizontal32)begin load_valid=1;load_group[0]=2;end // 第二拍写右列。
                    else begin load_valid=3;load_group={2'd1,2'd0};end // C16两个口同拍成窗。
                    window_done=1;response_take=!reflect_right; // reflect不消耗原字。
                end // 新右列处理结束。
            end // 横向成窗结束。
            if(from_c)c_rsp_ready=response_take;else d_rsp_ready=response_take; // 只在实际写入沿释放原字。
        end else if(vertical)begin // 已有bank的抽头窗直接写入，无宽中间缓存。
            req_subread=0;req_valid=unsent_q!=0 && !loaded_q; // 请求按描述符周期发起。
            if(layer==14)req_valid=(unsent_q>=2 || unsent_q==1 && request_take) && (pair_pending_q<=2 || pair_pending_q==3 && bank_fill_done && window_take) && !loaded_q; // 旧对末窗同拍释放名额，下一对提前进入一级请求寄存。
            else if(layer==16)req_valid=(unsent_q!=0 || request_take) && (!raw_pending_q || bank_fill_valid[0] && bank_fill_group[0]==0 || bank_fill_done && window_take) && (!loaded_q || window_take); // 新名额可在实际消费沿进入请求寄存，读返回仍晚于翻转。
            else if(layer!=2)req_valid=unsent_q!=0 && (!raw_pending_q || bank_fill_done && window_take) && !loaded_q; // 最后一拍可预发下一原窗，返回在翻转沿之后。
            load_valid=bank_fill_valid;load_group=bank_fill_group;window_done=bank_fill_done; // bank负责组号和时序。
            dispatch_fire=raw_fire; // 完整原窗请求。
        end else if(layer==0)begin // Stem结果直接进既有窗口。
            stem_ready=room;load_valid={1'b0,stem_valid && stem_ready};window_done=load_valid[0]; // 十二字节只需第一组。
        end else begin // Down、Reduce和Head的逐字直装路径。
            req_subread=read_sub_q; // 查询子读与返回子读分开，允许两个字连续发起。
            head_zero=layer==15 && (dispatch_x_q+11'({read_sub_q,1'b0})<read_lo || dispatch_x_q+11'({read_sub_q,1'b0})>=read_hi); // 成对裁掉的字不用访问RAM。
            req_valid=unsent_q!=0 && !loaded_q && !head_zero; // RAM原生输出及请求寄存承担等待，不串内等待每字返回。
            if(room && (singles_q!=0 && response_valid || head_zero && singles_q==0))begin // 裁零先等前面实际原字排空，保持严格顺序。
                response_take=!head_zero || singles_q!=0;load_valid=1; // 无宽保持寄存器。
                if(layer==3)begin // PixelUnshuffle按通道写四位置。
                    load_valid=3;load_group={2'd1,2'd0};load_byte_enable=subread_q ? 4'hc : 4'h3; // 上下内只改变字节使能。
                end else if(layer==15)load_group[0]={1'b0,subread_q}; // Head四点分两个字。
                window_done=layer==12 || subread_q; // Reduce一字，Down/Head两字。
            end // 原字返回结束。
            if(from_c)c_rsp_ready=response_take;else d_rsp_ready=response_take; // 实际写入才释放RAM返回。
            dispatch_fire=(raw_fire || head_zero && room && singles_q==0) && (layer==12 || read_sub_q); // 发完本窗的两个查询才释放未发起名额。
        end // 客户选择结束。
        if(layer==16)load_cell_enable=16'h000f; // RGB每源内只写四个C4格，不写重复值。
        if(reset || row_clear)begin req_valid=0;load_valid=0;window_done=0;c_rsp_ready=0;d_rsp_ready=0;stem_ready=0;response_take=0;copy_step=0;dispatch_fire=0;end // 边界沿不产生事务。
    end // 组合连线结束。
    always_ff @(posedge clk)begin // 只保存窄字段。
        if(reset || row_clear)begin // 新内重新确定首窗。
            credits_q<=0;unsent_q<=0;fetch_x_q<=first_x==0 ? 11'd0 : first_x-1'b1; // 源读从真实左抽头开始。
            emit_x_q<=first_x;dispatch_x_q<=first_x;dispatch_ab_q<=first_ab_col;last_request_x_q<=first_x; // 内内坐标。
            boot_q<=first_x==0 ? 2'd1 : 2'd0;started_q<=0;first_taken_q<=0;loaded_q<=0;copy_done_q<=0;replay_sent_q<=0; // 清窗口所有权。
            streams_q<=0;subread_q<=0;read_sub_q<=0;pair_pending_q<=0;singles_q<=0; // 清原字事务。
            if(reset)protocol_error<=0; // 内切换不能掩盖错误。
        end else begin // 正常本内运内。
            case({request_take,window_done}) // 完整窗口完成释放窄名额。
                2'b10:credits_q<=credits_q+1'b1;2'b01:credits_q<=credits_q-1'b1;default:begin end // 同拍抵消。
            endcase // 逻辑计数结束。
            if(request_take)last_request_x_q<=last_request_x_q+(credits_q==0 && !started_q ? 11'd0 : 11'(group_step)); // 横向允许读取已接收请求的新右列。
            if(vertical || !horizontal && layer!=0)begin // 原窗请求发起数量。
                if(request_take || dispatch_fire)unsent_q<=unsent_q+3'(request_take)-(dispatch_fire ? (layer==14 ? 3'd2 : 3'd1) : 3'd0); // Decoder-V一次消费两个逻辑名额。
            end // 未发起计数结束。
            case({window_done,window_take}) // 完整但未消费的半窗只有一份。
                2'b10:loaded_q<=1;2'b01:loaded_q<=0;default:begin end // 同拍装好并消费无等待。
            endcase // 半窗占用结束。
            if(window_take)first_taken_q<=1; // 活动窗从此可复用。
            if(copy_step)copy_done_q<=1; // Body-H已复制左、中。
            if(window_done)begin started_q<=1;copy_done_q<=0;emit_x_q<=emit_x_q+11'(group_step);end // 下一目标窗。
            if(horizontal)begin // 源原读和首窗装填。
                if(raw_fire)begin if(replay)replay_sent_q<=1;else fetch_x_q<=fetch_x_q+1'b1;end // 每个真实源列只请求一次。
                if(response_take && !started_q)boot_q<=boot_q+1'b1; // 左、中、右首窗顺序。
            end else if(vertical)begin // 物理成窗流水。
                if(raw_fire)begin dispatch_x_q<=dispatch_x_q+11'(layer==14 ? 3'd2 : group_step);dispatch_ab_q<=dispatch_ab_q+11'(layer==14 ? 3'd2 : group_step);end // 下一待发原窗。
                if(layer!=2 && layer!=14 && (raw_fire || window_done))streams_q<=streams_q+2'(raw_fire)-2'(window_done); // 多拍旧窗完成与下一请求分别计数。
                if(layer==14 && (raw_fire || window_done))pair_pending_q<=pair_pending_q+(raw_fire ? 3'd2 : 3'd0)-3'(window_done); // 前一对返回时可有下一对窄请求在途。
            end else if(layer!=0)begin // 普通单字、两字读取。
                if(raw_fire || response_take)singles_q<=singles_q+2'(raw_fire)-2'(response_take); // 原字只保存计数，返回保持在RAM输出上。
                if(raw_fire || head_zero && room && singles_q==0)read_sub_q<=layer==12 ? 1'b0 : !read_sub_q; // 发出子查询即推进。
                if(response_take || head_zero && room && singles_q==0)subread_q<=!subread_q; // 实际写子字独立推进。
                if(window_done)subread_q<=0; // 下一窗从第一个子字开始。
                if(dispatch_fire)begin dispatch_x_q<=dispatch_x_q+11'(group_step);dispatch_ab_q<=dispatch_ab_q+11'(group_step);end // 发完本窗查询后即可预取下一窗。
            end // 客户推进结束。
            if(window_done && (credits_q==0 || loaded_q))protocol_error<=1; // 未请求或覆盖待消费窗为实际错误。
        end // 正常推进结束。
    end // 窄状态结束。
`ifdef SIM_ASSERT // 只在仿真检查非法调度，不增加宽比较器。
    always @(posedge clk)if(!reset && !row_clear)begin // 同真实窗口所有权比对。
        if((|load_valid) && loaded_q)$fatal(1,"WINDOW overwrite pending half"); // 消费沿本身也不能提前改旧半窗。
        if(window_done && credits_q==0)$fatal(1,"WINDOW unsolicited completion"); // 必须有逻辑请求。
        if(horizontal && started_q && (|load_valid) && !first_taken_q)$fatal(1,"WINDOW copy before first take"); // 复制不能读取尚未激活的半窗。
        if(layer==14 && raw_fire && (dispatch_x_q[0] || unsent_q+3'(request_take)<2))$fatal(1,"WINDOW decoder pair request"); // 包含同拍新接受的名额，仍先接受两个逻辑请求。
    end // 仿真契约结束。
`endif // 仿真限定结束。
endmodule // 窗口供数结束。
