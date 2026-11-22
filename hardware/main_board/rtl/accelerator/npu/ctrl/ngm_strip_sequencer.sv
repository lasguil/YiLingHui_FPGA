// 协议契约：T固定120且X0宽最多480，条带起点仅0/120/240/360，由两位索引生成固定表。
// 帧尺寸保持可配置；末strip和halo仍按真实宽度裁剪，不增加命令拍数。
// 协议契约：内部X0几何仅用9位，最大宽480、高270；放大坐标在输出前显式扩位再移位。
// 协议契约：RGB组宽4，strip四倍输出宽除四恰好是strip_len，接缝halo只加整组。
// 流式契约：内部接缝各多算两组四点组（8个RGB像素=2个X0列），帧边不扩展；
// 外侧组只作窗口上下文，绝不进入任何发射像素的抽头，且起始列使原图读基址保持16字节对齐。
// 协议契约：start执行checkpoint之后的整帧Body/Tail，前端四层由frame层负责；width4/height4是X0尺寸。
// T=120，每条row命令接受后等待row_done实际排空；row_ready适配器须先装好本stage的312项权重。
// boundary_ready表示所有存储/输出/DMA排空，strip_start据此清C旧标签；本模块不保存宽数据。
// DMA命令一次一行，同时写C残差和D预取，dma_done表示末字真正提交；首H0必须等它完成。
// 下一X0的预取在当前V0完成后启动；镜像提交结束前不启动新的Body行，避免C占用传成DDR返回背压。
// 权重准备仍可提前进行；DMA回压时字段保持，原长burst、中心/halo及行顺序不变。
// 外部行列都是真实坐标，AB局部首列为零；tail_base为Body3保存首列，D据此换算局部列。
// Decoder-H只计算偶逻辑行，H源行按奇偶写槽0/2；V结果固定写槽1，Head消费后再执行下一V。
// H/V范围向内裁两列（帧边不裁），保证横向真实依赖与C16配对；Head按四点组对齐。
// Head首末组在read_lo/hi之外的无消费者车道由供窗器置零，禁止越界RAM读；中心RGB不会使用这些车道。
// RGB源槽按Head行三槽轮转；RGB计算[4(s-lo),4(e+hi))，每组的源抽头仍落在本strip的D保存区内。
// read_width是整幅输入宽度，bank_rgb_width给D本strip保存宽度；reflect行必须先按真实高度映射再别名。
// 配置合法性由frame保证，SIM_ASSERT检查非法描述符，不为非法输入增加宽硬件检查。
// prefetch_valid在当前行已接受时提示下一实际层，加载器须等当前engine_row_start实际提交读bank后只装载一次。
// 提示可送已有row描述符查询口，不另复制ROM；当前行cfg已锁存，预取不得改变运行cfg。
module ngm_strip_sequencer #( // 固定模型strip命令生成器，与row控制器通过握手连接。
    parameter int unsigned ROW_W=11,COL_W=11,COUNT_W=10 // 标签和组数位宽。
)( // 接口开始。
    input logic clk,reset,start,boundary_ready, // 时钟、复位、启动和静止边界。
    output logic start_ready,busy,done,strip_start, // 启动接受、占用和单拍完成。
    input logic [COL_W-1:0] width4, // X0宽度2..480。
    input logic [ROW_W-1:0] height4, // X0高度2..270。
    output logic [COL_W-1:0] strip_s,strip_e,tail_base, // 中心范围和D真实列基址。
    output logic dma_valid, // 一行X0的DMA请求。
    input logic dma_ready,dma_done, // DMA请求接受和末字提交。
    output logic [ROW_W-1:0] dma_row, // DMA真实行号。
    output logic [COL_W-1:0] dma_lo,dma_hi,dma_center_lo,dma_center_hi, // 完整范围和C中心。
    output wire row_output_stage, // RGB is the only DDR output stage inside a strip.
    output logic row_valid, // 整行命令。
    input logic row_ready,row_done, // 命令接受和计算写回排空。
    output logic [4:0] row_layer, // 层号4..16。
    output logic prefetch_valid, // 当前行计算期间的下一层预取提示，非命令接受脉冲。
    output logic [4:0] prefetch_layer, // 下一实际执行层，包括跳过预热/drain的不存在行。
    output logic [ROW_W-1:0] row_id,read_height, // 真实行号和输入真实高度。
    output logic [COL_W-1:0] row_x,row_ab_col,read_width, // 组首列、AB局部首列、整幅输入宽度。
    output logic [COUNT_W-1:0] row_count, // 空间组数。
    output logic [1:0] read_slot,write_slot, // 输入物理槽与输出物理槽。
    output logic [COL_W-1:0] read_lo,read_hi,emit_lo,emit_hi, // 输入范围和写回/最终提交范围。
    output logic [COL_W-1:0] read_center_lo,read_center_hi,write_center_lo,write_center_hi, // C中心范围。
    output logic [COL_W-1:0] bank_rgb_width // D保存区局部RGB宽度。
); // 接口结束。
    typedef enum logic [2:0] {IDLE,BOUNDARY,BODY,REDUCE,HROW,VROW,HEAD,RGB} state_t; // 固定阶段。
    typedef enum logic [1:0] {DMA_EMPTY,DMA_OFFER,DMA_WAIT} dma_t; // 单条DMA状态。
    state_t state_q;dma_t dma_q; // 控制状态。
    logic waiting_q,prefetched_q; // 行已接受，X0已提交。
    logic [8:0] width_q,height_q,wave_q,tail_row_q;logic [9:0] v_next_q;logic [10:0] rgb_next_q; // 几何和波前。
    logic [2:0] phase_q;logic [1:0] wave_slot_q,rgb_source_slot_q,body_slot; // 窄阶段和环槽。
    logic [COL_W-1:0] out_lo,out_hi,in_lo,in_hi,dec_lo,dec_hi,head_lo,head_hi; // 共享范围计算。
    logic [2:0] halo;logic [1:0] body_index;logic [2:0] delay_rows; // 当前Body与波前延迟。
    logic body_real,finished,v_available,rgb_available; // 真实行和依赖就绪。
    logic [4:0] next_wave_layer; // 下一波前的首个真实stage。
    wire [6:0] strip_len=7'(strip_e-strip_s); // 长度最大120，仅保留七位。
    function automatic logic [1:0] previous_slot(input logic [1:0] s); // 三行环前一槽。
        previous_slot=s==0 ? 2'd2 : s-1'b1; // 不用宽行号取模。
    endfunction // 窄环结束。
    logic [1:0] strip_index_q; // 四个可达strip只需两位状态。
    wire [8:0] clip_lo[1:6],clip_hi[1:6]; // 六档边界全部是固定起点表，不保留几何缓存。
    always_comb begin // 固定四个条带起点，结束位置按帧尺寸裁剪。
        case(strip_index_q) // 只有四种可达位置。
            0:begin strip_s=0;strip_e=width_q>120 ? COL_W'(120) : COL_W'(width_q);end // 首条带。
            1:begin strip_s=COL_W'(120);strip_e=width_q>240 ? COL_W'(240) : COL_W'(width_q);end // 第二条带。
            2:begin strip_s=COL_W'(240);strip_e=width_q>360 ? COL_W'(360) : COL_W'(width_q);end // 第三条带。
            default:begin strip_s=COL_W'(360);strip_e=COL_W'(width_q);end // 第四条带必为末条带。
        endcase // 起点表结束。
    end // 起点和结束位置输出结束。
    for(genvar h=1;h<=6;h++)begin:g_geometry_table // halo是生成期常量，不使用运行时宽减法。
        assign clip_lo[h]=strip_index_q==0 ? 9'd0 : strip_index_q==1 ? 9'(120-h) : strip_index_q==2 ? 9'(240-h) : 9'(360-h); // 左界固定连线表。
        assign clip_hi[h]=strip_index_q==0 ? (width_q<9'(120+h) ? width_q : 9'(120+h)) : strip_index_q==1 ? (width_q<9'(240+h) ? width_q : 9'(240+h)) : strip_index_q==2 ? (width_q<9'(360+h) ? width_q : 9'(360+h)) : width_q; // 右界只有常量门限比较。
    end // 六档几何表结束。
    wire [COL_W-1:0] rgb_lo=tail_base,rgb_hi=COL_W'(clip_hi[2]); // RGB行覆盖D保存区全宽。
    wire [7:0] rgb_groups=8'(strip_len)+8'(rgb_lo==strip_s?0:2)+8'(rgb_hi==COL_W'(strip_e)?0:2); // 接缝两侧各两个四点组，最多124。
    assign start_ready=state_q==IDLE;assign busy=state_q!=IDLE; // 帧级控制。
    assign dma_valid=dma_q==DMA_OFFER; // 回压期间保持请求和行号。
    assign dma_lo=COL_W'(clip_lo[6]);assign dma_hi=COL_W'(clip_hi[6]); // X0完整输入区。
    assign dma_center_lo=COL_W'(clip_lo[5]);assign dma_center_hi=COL_W'(clip_hi[5]); // X0的C中心区。
    assign tail_base=COL_W'(clip_lo[2]);assign bank_rgb_width=COL_W'((COL_W'(clip_hi[2])-tail_base)<<2); // D局部基址和最大496列保存区。
    assign body_index=phase_q[2:1];assign halo=3'd5-{1'b0,body_index}; // Body输出halo依次5/4/3/2。
    assign out_lo=COL_W'(clip_lo[halo]);assign out_hi=COL_W'(clip_hi[halo]);assign in_lo=COL_W'(clip_lo[halo+1'b1]);assign in_hi=COL_W'(clip_hi[halo+1'b1]); // H需要额外一列。
    assign delay_rows={1'b0,body_index}+phase_q[0]; // H延迟b，V延迟b+1。
    assign body_real={1'b0,wave_q}>=delay_rows && ({1'b0,wave_q}-delay_rows)<{1'b0,height_q}; // 预热/drain只发真实行。
    always_comb begin // 窄环号相减。
        case(delay_rows) // 相差三行是同一槽。
            0,3:body_slot=wave_slot_q; // 中心槽。
            1,4:body_slot=previous_slot(wave_slot_q); // 前一槽。
            default:body_slot=previous_slot(previous_slot(wave_slot_q)); // 前两槽。
        endcase // 环槽选择结束。
    end // 环槽组合结束。
    assign dec_lo=tail_base==0 ? '0 : COL_W'((tail_base<<1)+2); // 内部strip裁一对像素，帧边reflect不裁。
    assign dec_hi=COL_W'(clip_hi[2])==width_q ? COL_W'(COL_W'(width_q)<<1) : COL_W'((COL_W'(clip_hi[2])<<1)-2); // 右边同理。
    assign head_lo={dec_lo[COL_W-1:2],2'b0};assign head_hi=COL_W'((dec_hi+3)>>2)<<2; // Head四点组对齐。
    assign v_available=v_next_q<(ROW_W'(height_q)<<1) && ((v_next_q>>1)<tail_row_q || !v_next_q[0] || tail_row_q==height_q-1'b1); // 两条H源行依赖齐全。
    assign rgb_available=rgb_next_q<(ROW_W'(height_q)<<2) && ((rgb_next_q>>1)<v_next_q || !rgb_next_q[0] || v_next_q==(ROW_W'(height_q)<<1)-1'b1); // 已提交Head源行依赖齐全。
    assign row_output_stage=state_q==RGB;
    // X0 and Body rows share C: a replay/compute row cannot overlap the
    // unfinished mirrored row DMA without holding the ordered DDR response.
    // Drain the prefetch before starting the next Body consumer/producer.
    // Reuse the existing DMA lifecycle, preserving row order and long bursts.
    assign row_valid=!waiting_q && (state_q==BODY ? body_real && dma_q==DMA_EMPTY && (phase_q!=0 || prefetched_q) : state_q==RGB ? rgb_available : state_q>=REDUCE); // 下一H0等DMA，RGB等源行。
    assign finished=waiting_q && row_done; // 只在实际排空后推进。
    always_comb begin // 下一波前首个有效层，只比较五种warm-up/drain位置。
        if(wave_q+1'b1<height_q)next_wave_layer=4; // 正常轮先H0。
        else if(wave_q+1'b1==height_q)next_wave_layer=5; // H0结束后的V0末行。
        else if(wave_q==height_q)next_wave_layer=7; // V1末行。
        else if(wave_q==height_q+1'b1)next_wave_layer=9; // V2末行。
        else next_wave_layer=11; // V3末行。
    end // 下一波前层选择结束。
    always_comb begin // 仅导出下一层号，不提前发起计算或存储访问。
        prefetch_valid=waiting_q;prefetch_layer=next_wave_layer; // 默认为下一Body轮。
        case(state_q) // 当前行的真实后继。
            BODY:prefetch_layer=phase_q==7 ? 5'd12 : (!phase_q[0] && row_id==0) ? next_wave_layer : row_layer+1'b1; // 预热跳过无依赖行。
            REDUCE:prefetch_layer=13; // Reduce之后H源行。
            HROW:prefetch_layer=14; // H源行之后真实V。
            VROW:prefetch_layer=15; // 固定工作槽必须先Head消费。
            HEAD:prefetch_layer=16; // Head之后至少一条RGB已齐依赖。
            RGB:begin // 先剩余RGB，再下一V或下一Body轮。
                if(rgb_next_q+1'b1<(ROW_W'(height_q)<<2) && (rgb_next_q[0] || v_next_q==(ROW_W'(height_q)<<1)-1'b1))prefetch_layer=16; // 下一RGB同样已齐依赖。
                else if(v_next_q==(ROW_W'(height_q)<<1)-1'b1)begin prefetch_layer=4;prefetch_valid=waiting_q && strip_e!=width_q;end // 下一strip或帧结束。
                else if((v_next_q>>1)<tail_row_q || tail_row_q==height_q-1'b1)prefetch_layer=14; // 当前源的另一真实V行。
            end // RGB后继结束。
            default:prefetch_valid=0; // 静止期间不预取运行后继。
        endcase // 预取后继选择结束。
    end // 预取提示结束。
    always_comb begin // 当前命令字段共享计算。
        row_layer=5'd4+{2'b0,phase_q};row_id=ROW_W'({1'b0,wave_q}-delay_rows); // Body层和真实行。
        row_x=out_lo;row_ab_col='0;row_count=COUNT_W'(out_hi-out_lo); // Body每组一像素。
        read_height=height_q;read_width=width_q;read_slot=body_slot;write_slot=body_slot; // Body三行环。
        read_lo=phase_q[0] ? out_lo : in_lo;read_hi=phase_q[0] ? out_hi : in_hi;emit_lo=out_lo;emit_hi=out_hi; // H/V横向范围。
        read_center_lo=out_lo;read_center_hi=out_hi; // Xb残差和重放中心范围。
        write_center_lo=COL_W'(clip_lo[phase_q==7 ? 3'd2 : halo-1'b1]);write_center_hi=COL_W'(clip_hi[phase_q==7 ? 3'd2 : halo-1'b1]); // V输出下一X槽；V3保留X3中心。
        if(state_q!=BODY)begin // 尾部公共尺寸。
            row_id=v_next_q;row_x=dec_lo;row_count=COUNT_W'(dec_hi-dec_lo); // 默认真实V行。
            read_height=ROW_W'(ROW_W'(height_q)<<1);read_width=COL_W'(COL_W'(width_q)<<1);read_slot={row_id[1],1'b0};write_slot=1; // H源行两槽，V工作槽固定。
            read_lo=dec_lo;read_hi=dec_hi;emit_lo=dec_lo;emit_hi=dec_hi; // 正确且成对的C16保存范围。
            read_center_lo=tail_base;read_center_hi=COL_W'(clip_hi[2]);write_center_lo=tail_base;write_center_hi=COL_W'(clip_hi[2]); // X4中心范围。
            case(state_q) // 固定尾部拓扑。
                REDUCE:begin row_layer=12;row_id=tail_row_q;row_x=tail_base;row_count=COUNT_W'(COL_W'(clip_hi[2])-tail_base);read_height=height_q;read_width=width_q;read_lo=tail_base;read_hi=COL_W'(clip_hi[2]);emit_lo=tail_base;emit_hi=COL_W'(clip_hi[2]);end // Reduce一源行物理写一次。
                HROW:begin row_layer=13;row_id=ROW_W'(ROW_W'(tail_row_q)<<1);read_lo=COL_W'(tail_base<<1);read_hi=COL_W'(COL_W'(clip_hi[2])<<1);write_slot={tail_row_q[0],1'b0};end // H只计算偶行，共享另一逻辑行。
                VROW:row_layer=14; // V仍逐真实行计算。
                HEAD:begin row_layer=15;row_x=head_lo;row_count=COUNT_W'((head_hi-head_lo)>>2);read_slot=1;write_slot=rgb_source_slot_q;emit_lo=head_lo;emit_hi=head_hi;end // 对齐组中无消费者车道置零。
                RGB:begin row_layer=16;row_id=rgb_next_q;row_x=COL_W'(rgb_lo<<2);row_count=COUNT_W'(rgb_groups);read_height=ROW_W'(ROW_W'(height_q)<<2);read_width=COL_W'(width_q<<2);read_slot=(rgb_next_q>>1)==v_next_q ? rgb_source_slot_q : previous_slot(rgb_source_slot_q);read_lo=COL_W'(head_lo<<1);read_hi=COL_W'(head_hi<<1);emit_lo=COL_W'(rgb_lo<<2);emit_hi=COL_W'(rgb_hi<<2);end // RGB含接缝halo，输出列数由emit范围预译码。
                default:begin end // 静止状态不消费描述符。
            endcase // 尾部命令结束。
        end // 尾部公共字段结束。
    end // 描述符组合结束。
    always_ff @(posedge clk)begin // 固定顺序控制。
        if(reset)begin // 清窄控制与配置。
            state_q<=IDLE;dma_q<=DMA_EMPTY;waiting_q<=0;prefetched_q<=0;done<=0;strip_start<=0; // 空闲。
            width_q<=0;height_q<=0;strip_index_q<=0;wave_q<=0;phase_q<=0;wave_slot_q<=0; // 几何。
            tail_row_q<=0;v_next_q<=0;rgb_next_q<=0;rgb_source_slot_q<=0;dma_row<=0; // 尾部和预取。
        end else begin // 正常推进。
            done<=0;strip_start<=0; // 单拍通知。
            if(dma_valid && dma_ready)dma_q<=DMA_WAIT; // 接受整行DMA。
            if(dma_q==DMA_WAIT && dma_done)begin dma_q<=DMA_EMPTY;prefetched_q<=1;end // 等实际提交。
            if(row_valid && row_ready)begin waiting_q<=1;if(state_q==BODY && phase_q==0)prefetched_q<=0;end // 一次只执行一条stage。
            if(finished)waiting_q<=0; // 写回和返回排空。
            case(state_q) // 阶段进度。
                IDLE:if(start)begin width_q<=9'(width4);height_q<=9'(height4);strip_index_q<=0;state_q<=BOUNDARY;end // 第一strip。
                BOUNDARY:if(boundary_ready)begin strip_start<=1;wave_q<=0;phase_q<=0;wave_slot_q<=0;v_next_q<=0;rgb_next_q<=0;rgb_source_slot_q<=0;dma_row<=0;dma_q<=DMA_OFFER;prefetched_q<=0;state_q<=BODY;end // 先清标签再开始DMA。
                BODY:if(!body_real || finished)begin // 真实行预热与逐层drain。
                    if(phase_q==1 && wave_q+1'b1<height_q)begin dma_row<=wave_q+1'b1;dma_q<=DMA_OFFER;end // V0之后C残差槽可复用。
                    if(phase_q!=7)phase_q<=phase_q+1'b1; // 下一Body stage。
                    else if(body_real)begin tail_row_q<=row_id;state_q<=REDUCE;end // X4已就绪，先排尾部。
                    else begin wave_q<=wave_q+1'b1;wave_slot_q<=wave_slot_q==2 ? 0 : wave_slot_q+1'b1;phase_q<=0;end // 尚无X4的预热轮。
                end // Body推进结束。
                REDUCE:if(finished)state_q<=HROW; // Reduce源行提交。
                HROW:if(finished)state_q<=VROW; // H源行提交。
                VROW:if(finished)state_q<=HEAD; // V工作槽提交。
                HEAD:if(finished)state_q<=RGB; // Head源行提交。
                RGB:if(!rgb_available || finished)begin // 顺序排空当前Head已齐依赖的RGB行。
                    if(rgb_available)rgb_next_q<=rgb_next_q+1'b1; // 完成真实RGB行。
                    else begin // 当前Head无更多已就绪RGB消费者。
                        v_next_q<=v_next_q+1'b1;rgb_source_slot_q<=rgb_source_slot_q==2 ? 0 : rgb_source_slot_q+1'b1; // 下一Head源行槽。
                        if(v_next_q==(ROW_W'(height_q)<<1)-1'b1)begin // 最后真实V/RGB已排空。
                            if(strip_e==width_q)begin state_q<=IDLE;done<=1;end // 整帧Body阶段完成。
                            else begin strip_index_q<=strip_index_q+1'b1;state_q<=BOUNDARY;end // 下一strip。
                        end else if((v_next_q>>1)<tail_row_q || tail_row_q==height_q-1'b1)state_q<=VROW; // 当前源的偶行也可计算。
                        else begin state_q<=BODY;wave_q<=wave_q+1'b1;wave_slot_q<=wave_slot_q==2 ? 0 : wave_slot_q+1'b1;phase_q<=0;end // 下一Body波前提供新H源行。
                    end // 当前源消费者结束。
                end // RGB推进结束。
                default:begin end // 保持。
            endcase // 固定阶段结束。
        end // 正常推进结束。
    end // 控制寄存器结束。
`ifdef SIM_ASSERT // 协议检查不增加综合硬件。
    always @(posedge clk)if(!reset)begin // 检查合法配置和已接受事务。
        if(start && start_ready && (width4<2 || width4>480 || height4<2 || height4>270))$fatal(1,"STRIP invalid dimensions"); // 真实张量支持范围。
        if(strip_start && COL_W'((rgb_hi-tail_base)<<2)>bank_rgb_width)$fatal(1,"STRIP RGB seam outside bank"); // 接缝组必须落在D保存区内。
        if(row_done && !waiting_q)$fatal(1,"STRIP unsolicited row_done"); // 完成须对应一条命令。
        if(dma_done && dma_q!=DMA_WAIT)$fatal(1,"STRIP unsolicited dma_done"); // 完成须对应DMA。
        if(row_valid && state_q==VROW && !v_available)$fatal(1,"STRIP V missing parent"); // H依赖必须齐全。
    end // 仿真检查结束。
`endif // 仿真条件结束。
endmodule // strip定序器结束。
