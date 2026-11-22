// 协议契约：接实际issue_batch_last、issue_batch及真实issue_x，不根据窗口预取拍猜测结果拍。
// C32每点仅在低批末issue发一个读请求；C16每相邻两像素仅在偶像素issue发一个整字请求。
// 残差在issue后第八拍消费，最终结果第九拍输出；C请求仍延迟七拍，D请求仍延迟六拍。
// C整字保持到下一次读：Body两批间隔两拍，Encoder相邻像素间隔一拍，不新增256位残差缓存。
// layer_id/stage_row保持到整行结果及本请求流水排空；row sequencer原有DRAIN必须覆盖此约定。
// skip_req为结果对齐的固定时隙，ready必须为一；无延期重试队列，错过时隙即protocol_error。
// Decoder延迟六拍，D同步读后再保存一拍，返回在同一个八拍结果沿；C仍延迟七拍。
// 地址延迟的最后一拍用COL_W位寄存器隔开SRL动态抽头与bank地址运算；总延迟不变，无宽数据缓存。
module ngm_residual_schedule #( // C/D残差共用的窄地址延迟。
    parameter int unsigned ROW_W=11,COL_W=11 // 与行引擎真实坐标一致。
)( // 时序接口开始。
    input logic clk,reset, // 安全工作复位。
    input logic [4:0] layer_id, // 当前保持的实际层。
    input logic [ROW_W-1:0] stage_row, // 当前结果行，直到排空保持。
    input logic issue_batch_last,issue_batch, // 实际批末issue及低高批。
    input logic [COL_W-1:0] issue_x, // 实际issue的真实像素列。
    output logic skip_req_valid, // 七拍后的C请求或六拍后的D请求。
    input logic skip_req_ready, // 本拍对应bank读口可用，禁止仅按平均带宽判断。
    output logic [ROW_W-1:0] skip_req_row, // 保持的当前结果行。
    output logic [COL_W-1:0] skip_req_x, // 与当前层所需延迟一致的真实列。
    output logic protocol_error // 错过请求时隙保持错误到复位。
); // 窄调度接口结束。
    wire front=layer_id==5'd2; // Encoder的C16残差。
    wire body=layer_id==5'd5 || layer_id==5'd7 || layer_id==5'd9 || layer_id==5'd11; // Body的C32残差。
    wire decoder=layer_id==5'd14; // D的C16残差，每个最近邻像素对只读取一次。
    wire wanted=issue_batch_last && (((front || decoder) && !issue_x[0]) || (body && !issue_batch)); // 每个物理字只读一次。
    logic [6:0] valid_q;wire [COL_W-1:0] delayed_raw; // 只为地址延迟付出窄控制资源。
    logic [COL_W-1:0] delayed_x_q; // 最后一拍列号寄存，隔开层译码到RAM读写冲突检查的组合链。
    for(genvar b=0;b<COL_W;b++)begin:g_column // 显式原语，禁止推断七级列号触发器数组。
        EFX_SRL8 u_delay(.D(issue_x[b]),.A(decoder ? 3'd3 : 3'd2),.CLK(clk),.CE(1'b1),.Q(delayed_raw[b]),.Q7()); // 先延迟五/六拍，再由出口寄存补足六/七拍。
    end // 逐位地址延迟结束。
    always_ff @(posedge clk)delayed_x_q<=~delayed_raw; // 数据无复位，已有有效流水屏蔽未装入的地址。
    assign skip_req_x=delayed_x_q;assign skip_req_row=stage_row; // 已寄存真实列，不重存行号。
    assign skip_req_valid=(decoder ? valid_q[5] : valid_q[6]) && !reset; // 与下一沿的同步RAM读对齐。
    always_ff @(posedge clk)begin // 七位控制流水及错误保持。
        if(reset)begin valid_q<=0;protocol_error<=0;end // 无效地址数据无需复位。
        else begin // 按实际issue逐拍走，与计算暂停同步。
            valid_q<={valid_q[5:0],wanted}; // 后续issue可停，已发结果仍按八拍返回。
            if(skip_req_valid && !skip_req_ready)protocol_error<=1; // 结果流水不可等，必须暴露失配。
        end // 非复位路径结束。
    end // 窄寄存器结束。
`ifdef SIM_ASSERT // 不为非法调度添加数据队列。
    always @(posedge clk)if(!reset && skip_req_valid && !skip_req_ready)$fatal(1,"RESIDUAL missed read slot"); // 测试须用阻塞读口反例证伪。
`endif // 默认回归使能。
endmodule // 实际结果拍残差调度结束。
