// 协议契约：单套权重与参数SRL；提交建立模八读锚点，装完权重槽后锚点减一，读槽语义不变。
// 流显式携带槽号及40位组号；权重仅装有效槽，每槽39项；参数固定两槽各20项。
// valid与ready共同接受；暂停时槽号、组号及数据保持，组号必须从0严格递增，全部装完下一拍才允许commit。
// weights_live在旧层最后一次issue取走权重后清零；容量不足只暂停后续装载。
// 参数预取在commit后8拍才放行；bias、quant、resid锚点分别延迟6/7/8拍。
// 复位只清控制；首次commit前输出无意义，禁止issue；SRL数据保持正式镜像取反编码。
module ngm_weight_slots( // 单套上下文存储，寄存装载位置与读锚点。
 input logic clk,reset,commit,weights_live, // 时钟、复位、提交及旧权重存活。
 input logic [2:0] next_count,read_addr,stream_slot, // 有效槽数、读槽及装载槽。
 input logic [5:0] stream_pair, // 权重0..38，参数0..19。
 input logic stream_param,stream_valid,bias_batch,quant_batch, // 流类型、有效及消费批。
 input logic [39:0] stream_data, // 正式镜像的逐位取反编码。
 output wire stream_ready, // 容量与参数尾部回压。
 output wire [1535:0] read_context, // 当前层权重。
 output wire [785:0] param_context // 延迟消费参数。
); // 端口结束。
 logic [5:0] param_progress; // 当前槽已接受的组数，严格按组号递增。
 logic [2:0] weight_anchor_q,weight_shift_anchor_q,p_end,current_count,current_param_end; // 完整槽累计数及当前层锚点。
 logic [2:0] p_history[0:7]; // 参数锚点延迟。
 logic [3:0] age; // 距最近提交拍数，到8饱和。
 wire accept=stream_valid && stream_ready; // 唯一移位事件。
 wire [2:0] weight_base=weight_anchor_q+read_addr; // 当前完整槽与读槽的公共地址。
 wire [2:0] shifted_weight_base=weight_shift_anchor_q+read_addr; // 已移位与未移位两地址共用，逐组只选择，不串接减法。 // 提交与整槽移位沿维护模八锚点，只与当前读槽做一次三位加法。
 wire [2:0] bias_base=p_history[5]-p_end-3'd2+{2'd0,bias_batch}; // 偏置公共地址。
 wire [2:0] quant_base=p_history[6]-p_end-3'd2+{2'd0,quant_batch}; // 量化公共地址。
 wire [2:0] resid_base=p_history[7]-p_end-3'd2+{2'd0,quant_batch}; // 残差公共地址。
 assign stream_ready=stream_param ? age>=8 : (!weights_live || ({1'b0,stream_slot}+{1'b0,current_count}<4'd8)); // 容量约束。
 always_ff @(posedge clk) begin // 公共锚点控制。
  if(reset)begin // 控制复位。
   weight_anchor_q<=0;weight_shift_anchor_q<=7;p_end<=0;current_count<=0;current_param_end<=0;age<=8;param_progress<=0; // 首次预装允许。
   for(int k=0;k<8;k++)p_history[k]<=0; // 清参数延迟。
  end else begin // 正常更新。
   if(accept && !stream_param)begin // 权重组进度。
    if(stream_pair==38)begin weight_anchor_q<=weight_anchor_q-1'b1;weight_shift_anchor_q<=weight_shift_anchor_q-1'b1;end // 完整槽结束。
   end // 权重进度结束。
   if(accept && stream_param)begin // 参数组进度。
    if(stream_pair==19)begin p_end<=p_end+1'b1;param_progress<=0;end // 完整参数槽结束。
    else param_progress<=stream_pair+1'b1; // 参数已移位前缀。
   end // 参数进度结束。
   if(commit)begin weight_anchor_q<=-next_count;weight_shift_anchor_q<=-next_count-3'd1;current_count<=next_count;current_param_end<=p_end;age<=0;end // 正式提交。
   else if(age<8)age<=age+1'b1; // 等尾部排空。
   p_history[0]<=current_param_end; // 提交沿仍取旧层，与正式bank延迟一致。
   for(int k=1;k<8;k++)p_history[k]<=p_history[k-1]; // 字段消费延迟。
  end // 更新结束。
 end // 公共控制结束。
 for(genvar g=0;g<39;g++)begin:g_weight // 每40位一组。
  wire hit=accept && !stream_param && stream_pair==g; // 两字同拍移位。
  wire shifted; // 本组是否已被当前未完成槽推入，直接寄存该位，不由全局进度比较译码。
  if(g<38)begin:g_partial // 末组一旦移位整槽即完成，不需要部分移位标记。
   logic shifted_q; // 本组的一个窄状态位。
   always_ff @(posedge clk)begin // 与实际SRL移位沿同时更新。
    if(reset)shifted_q<=0; // 首次装载未开始。
    else if(accept && !stream_param)begin // 参数装载不能改变权重位置。
     if(stream_pair==38)shifted_q<=0; // 完整槽进入公共锚点，清部分标记。
     else if(hit)shifted_q<=1; // 本组已移动一格。
    end // 权重移位结束。
   end // 本组状态结束。
   assign shifted=shifted_q; // 读选择直接来自本组寄存器。
  end else begin:g_last // 末组没有部分历史。
   assign shifted=0; // 始终使用完整槽锚点。
  end // 部分标记生成结束。
  wire [2:0] address=shifted ? shifted_weight_base : weight_base; // 两个公共地址的三位选择。
  for(genvar b=0;b<40 && g*40+b<1536;b++)begin:g_bit // 固定数据连线。
   EFX_SRL8 u_srl(.D(stream_data[b]),.A(address),.CLK(clk),.CE(hit),.Q(read_context[g*40+b]),.Q7()); // 单套链。
  end // 比特结束。
 end // 权重结束。
 for(genvar g=0;g<20;g++)begin:g_parameter // 参数20组。
  wire hit=accept && stream_param && stream_pair==g; // 本组参数移位。
  for(genvar b=0;b<40 && g*40+b<786;b++)begin:g_bit // 分字段消费。
   localparam int BIT=g*40+b; // 固定位号。
   wire [2:0] base=BIT<384 ? bias_base : BIT<785 ? quant_base : resid_base; // 生成期固定字段连线。
   wire [2:0] address=base-3'(param_progress>g); // 本组只做一步位置补偿。
   EFX_SRL8 u_srl(.D(stream_data[b]),.A(address),.CLK(clk),.CE(hit),.Q(param_context[BIT]),.Q7()); // 无宽bank选择。
  end // 比特结束。
 end // 参数结束。
`ifdef SIM_ASSERT // 装载协议检查不进入硬件。
 logic [5:0] weight_progress; // 权重装载顺序只在仿真检查，硬件按每组一位位置记录。
 always_ff @(posedge clk)begin // 仿真顺序参考，不进入综合。
  if(reset)weight_progress<=0; // 首组位置。
  else if(accept && !stream_param)weight_progress<=stream_pair==38 ? 0 : stream_pair+1'b1; // 严格递增，末组回零。
 end // 仿真参考结束。
 always @(posedge clk)if(!reset)begin // 检查外部明确约束。
  if(accept && stream_pair!=(stream_param ? param_progress : weight_progress))$fatal(1,"SINGLE unordered group"); // 不允许跳组。
  if(accept && stream_param && (stream_pair>19 || stream_slot>1))$fatal(1,"SINGLE parameter range"); // 参数范围。
  if(accept && !stream_param && (stream_pair>38 || stream_slot>5))$fatal(1,"SINGLE weight range"); // 权重范围。
  if(commit && (accept || weight_progress!=0 || param_progress!=0 || next_count<1 || next_count>6))$fatal(1,"SINGLE invalid commit"); // 不接受半槽提交。
 end // 仿真约束结束。
`endif // 仿真开关结束。
endmodule // 单套上下文存储结束。
