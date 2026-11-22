// 固定模型的读路由：只给 bank 控制器送逻辑坐标、客户类型及竖向 reflect 行槽。
// 各 bank 已实现物理地址、行有效性及边缘读，本模块不重复这些地址运算。
// Decoder-V先按真实扩展行reflect，再以源行奇偶选H槽0/2；RGB的req_slot是Head源行三槽号。
// RGB相邻两条逻辑行共用一槽；内部偶行上抽头取前源槽，奇行下抽头取后源槽，帧边界共用中心槽。
// Down 的两条前端源行用 req_subread=0/1 分两拍请求；Body-H 使用 C 的整行重放命令。
// req_row/req_x通常为真实坐标；Stem的req_row是Stem行号、req_x是输入上行段DDR拍号0..23。
// Stem供数客户端负责原始RGB成窗；这里仅提供复用D空闲尾区的原字读路由，不能直连逻辑win_req。
module ngm_addr_map #(                                         // 读路由参数。
    parameter int unsigned ROW_W=11,                            // 真实行号位宽。
    parameter int unsigned COL_W=11                             // 真实列号位宽。
)(                                                              // 端口开始。
    input logic req_valid,                                      // 当前有一组逻辑读请求。
    input logic [4:0] layer_id,                                 // 固定模型层号 0..16。
    input logic [ROW_W-1:0] req_row,                             // 当前输出中心行。
    input logic [COL_W-1:0] req_x,                               // 当前输出组首列。
    input logic [1:0] req_slot,                                  // 调度给出的中心行三行环槽。
    input logic [ROW_W-1:0] src_height,                          // 此层输入张量高度。
    input logic [COL_W-1:0] src_width,                           // 此层输入张量宽度。
    input logic req_subread,                                    // Down 选源行，Head 选组内第一个或第二个字。
    output logic [1:0] ab_valid,                                // A/B 各自的请求有效。
    output logic ab_front,                                      // A/B 读前端编码器行。
    output logic ab_ring,                                       // Body-H/V 当前行环。
    output logic [ROW_W-1:0] ab_row,                             // A/B 竖向中心真实行。
    output logic [COL_W-1:0] ab_x,                               // A/B 请求列。
    output logic ab_last_row,                                   // A/B 当前行为末行。
    output logic c_valid,                                       // C 单字读有效。
    output logic [1:0] c_kind,                                  // C：0=residual、1=Tail、2=前端。
    output logic [1:0] c_body,                                  // C 的 Xb 槽。
    output logic [ROW_W-1:0] c_row,                              // C 请求真实行。
    output logic [COL_W-1:0] c_x,                                // C 请求真实列。
    output logic c_replay,                                      // Body-H 由 C 整行重放供数。
    output logic [1:0] c_replay_body,                           // 重放目标 X1/X2/X3。
    output logic d_valid,                                       // D 单次窗口或字请求有效。
    output logic [2:0] d_kind,                                  // D读客户：0=H、1=V、2=RGB、3=X0、4=FRONT、5=HEAD。
    output logic [ROW_W-1:0] d_row,                              // D 中心真实行。
    output logic [COL_W-1:0] d_x,                                // D 输入像素列或 RGB 组首列。
    output logic [COL_W-1:0] d_width,                            // RGB 输入行实际宽度。
    output logic [2:0][ROW_W-1:0] d_tap_row,                     // D 竖向三抽头真实行。
    output logic [2:0][1:0] d_tap_slot,                          // D 三抽头物理行槽。
    output logic map_error                                     // 未知层或非法源尺寸。
);                                                              // 端口结束。
    logic [ROW_W-1:0] tap_top, tap_bottom;                      // 逐层 reflect 的上下行。
    logic [1:0] slot_prev, slot_next;                           // 环槽的相邻编号。
    assign tap_top=req_row==0 ? ROW_W'(1) : req_row-1'b1;      // 顶边 -1 映到 +1。
    assign tap_bottom=req_row==src_height-1'b1 ? req_row-1'b1 : req_row+1'b1; // 底边 +1 映到 -1。
    assign d_tap_row[0]=tap_top;                                // 上抽头真实行。
    assign d_tap_row[1]=req_row;                                 // 中抽头真实行。
    assign d_tap_row[2]=tap_bottom;                             // 下抽头真实行。
    assign slot_prev=req_slot==2'd0 ? 2'd2 : req_slot-1'b1;    // 前一环槽，无宽取模。
    assign slot_next=req_slot==2'd2 ? 2'd0 : req_slot+1'b1;    // 后一环槽，无宽取模。
    assign d_tap_slot[0]=layer_id==14 ? {tap_top[1],1'b0} : layer_id==16 ? // V源行奇偶直接选低高两槽。
        ((!req_row[0] && req_row!=0) ? slot_prev : req_slot) : req_row==0 ? slot_next : slot_prev; // RGB先reflect再共享。
    assign d_tap_slot[1]=layer_id==14 ? {req_row[1],1'b0} : req_slot; // V仅两个H源槽，其他层取调度中心槽。
    assign d_tap_slot[2]=layer_id==14 ? {tap_bottom[1],1'b0} : layer_id==16 ? // 底抽头真实源行。
        ((req_row[0] && req_row!=src_height-1'b1) ? slot_next : req_slot) : req_row==src_height-1'b1 ? slot_prev : slot_next; // RGB底边共用中心源槽。
    always_comb begin                                           // 层到读客户的唯一译码。
        ab_valid=2'b00;                                         // 默认不读 A/B。
        ab_front=1'b0;                                          // 默认 Body 行环。
        ab_ring=1'b0;                                           // 默认本片第零行环。
        ab_row=req_row;                                         // A/B 读中心行。
        ab_x=req_x;                                             // A/B 读当前列。
        ab_last_row=req_row==src_height-1'b1;                  // 边缘 reflect 所需末行标记。
        c_valid=1'b0;                                           // 默认不读 C。
        c_kind=2'd0;                                            // 默认 C residual 客户。
        c_body=2'd0;                                            // 默认 X0 槽。
        c_row=req_row;                                          // C 读当前行。
        c_x=req_x;                                              // C 读当前列。
        c_replay=1'b0;                                          // 默认不启动重放。
        c_replay_body=2'd0;                                     // 默认重放槽零。
        d_valid=1'b0;                                           // 默认不读 D。
        d_kind=3'd0;                                            // 默认 H 客户。
        d_row=req_row;                                          // D 读中心行。
        d_x=req_x;                                              // D 读当前列。
        d_width=src_width;                                      // RGB 宽度直通。
        map_error=1'b0;                                         // 默认映射有效。
        case (layer_id)                                         // 固定模型 17 个层号。
            5'd0: begin                                        // Stem 输入来自帧流 PixelUnshuffle。
                d_valid=req_valid;d_kind=3'd6;                   // Stem供数客户按段内拍号读取D原有空闲尾区，不是像素窗口请求。
            end                                                 // Stem 源选择结束。
            5'd1: begin                                        // Encoder-H 读 C 前端输入行。
                c_valid=req_valid;                              // 当前列直接读 C。
                c_kind=2'd2;                                    // C 前端客户。
            end                                                 // Encoder-H 结束。
            5'd2: begin                                        // Encoder-V读取A/B三抽头，C残差由独立实际issue路径定时读取。
                ab_valid={2{req_valid}};                        // A/B 各取本片所属抽头。
                ab_front=1'b1;                                  // A/B 前端 C16 行。
            end                                                 // Encoder-V 结束。
            5'd3: begin                                        // Down 从 D 的两条前端行分拍取数。
                d_valid=req_valid;                              // 每拍读一个双像素整字。
                d_kind=3'd4;                                    // D 前端客户。
                d_row=ROW_W'((req_row<<1)+req_subread);         // PixelUnshuffle 的上/下源行。
                d_x=COL_W'(req_x<<1);                           // 横向双像素首列。
            end                                                 // Down 结束。
            5'd4: begin                                        // Body0-H 从 D 预取的 X0 读数。
                d_valid=req_valid;                              // X0 逐字读。
                d_kind=3'd3;                                    // D X0 客户。
            end                                                 // Body0-H 结束。
            5'd6,5'd8,5'd10: begin                             // Body1/2/3-H 从 C 自动整行重放。
                c_replay=req_valid;                             // 上游仅在行首发一次重放命令。
                c_replay_body=layer_id==5'd6 ? 2'd1 : layer_id==5'd8 ? 2'd2 : 2'd3; // 目标 X 槽。
            end                                                 // Body-H 重放结束。
            5'd5,5'd7,5'd9,5'd11: begin                        // 四个 Body-V 读 A 或 B 三行环。
                ab_valid[layer_id<=5'd7 ? 0 : 1]=req_valid;    // Body0/1 在 A，Body2/3 在 B。
                ab_ring=(layer_id==5'd7 || layer_id==5'd11);   // 每片第二个 Body 选环一。
            end                                                 // Body-V 结束。
            5'd12: begin                                       // Reduce 读取 X4 尾部行。
                c_valid=req_valid;                              // 从 C 逐字读。
                c_kind=2'd1;                                    // Tail 客户。
                c_body=2'd3;                                    // X4 与 X3 共用物理槽。
            end                                                 // Reduce 结束。
            5'd13: begin                                       // Decoder-H 从 D RES 读 C16。
                d_valid=req_valid;                              // 单像素半字由 D 选。
                d_kind=3'd0;                                    // D H 输入客户。
            end                                                 // Decoder-H 结束。
            5'd14: begin                                       // Decoder-V 从 D 读 H 三行及 RES。
                d_valid=req_valid;                              // 一次请求装相邻两个像素。
                d_kind=3'd1;                                    // D V 窗口客户。
            end                                                 // Decoder-V 结束。
            5'd15: begin                                       // Head 读 Decoder-V 输出行。
                d_valid=req_valid;                              // 每字两个 C16 像素。
                d_kind=3'd5;                                    // D Head 客户。
                d_x=req_x+COL_W'({req_subread,1'b0});          // 一组四点分两次读两个整字。
            end                                                 // Head 结束。
            5'd16: begin                                       // RGB 读 D 的 C4 三行窗口。
                d_valid=req_valid;                              // 一组五像素。
                d_kind=3'd2;                                    // D RGB 客户。
            end                                                 // RGB 结束。
            default: map_error=req_valid;                       // 非模型层号报错。
        endcase                                                 // 层读路由结束。
        if (req_valid && (src_height<ROW_W'(2) || src_width==0)) map_error=1'b1; // 三抽头需要合法张量尺寸。
    end                                                         // 读路由组合结束。
endmodule                                                       // 地址映射器结束。
