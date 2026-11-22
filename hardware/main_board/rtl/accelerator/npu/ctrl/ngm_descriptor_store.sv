// 协议契约：RGB四像素使用前12车道，主表保留原16车道编码；未使用车道不提交。
// 协议契约：固定17层模型的组合查询，无时钟、复位、寄存器或查询握手。
// layer_id为0..16时desc_valid=1；其余层号输出全零，调用方不得启动运算或权重装载。
// layer_id改变后等待组合稳定再采样；已接受的行配置由行引擎保存，预取层号由调度器另行管理。
// weight_base/param_base单位为40位项，必须配套使用quant/descriptor_package/weight_table40.hex。
// 主表权重先按层、批、段排列，每段39项；参数区从1989起，每批20项，共2509有效项。
// 主表补零至2560项；运行期只装N=slots×batches个权重槽及两参数槽，共39×N+40项。
// 装载顺序：前min(N,2)个权重槽、两参数槽、剩余权重槽；valid/ready接受，支持容量暂停。
// 单批层第二参数槽可读到后续层数据，但本层不会寻址；不得将其作为本层有效参数。
// ReLU/残差使能随参数槽装载；动态行列、strip范围和环槽由sequencer管理，不在此重复保存。
// 由quant/build_descriptor_package.py生成；修改布局须同步生成镜像和manifest，禁止独立改基址。
module ngm_descriptor_store ( // 固定模型最小描述符。
    input logic [4:0] layer_id, // 查询层号。
    output logic desc_valid, // 当前层号有效。
    output logic [2:0] kind, // 0为1×1，1为编码/解码，2为Body，3为Head，4为RGB。
    output logic [1:0] slots, batches, // 每批段数及每点批数，均为实际计数。
    output logic [2:0] point_group, // 一组空间点数，仅1、4。
    output logic [11:0] weight_base, param_base // 主表两个起始项地址。
); // 接口结束。
    always_comb begin // 固定常量译码，不构造运行时地址运算。
        desc_valid=1'b1; // 合法分支均有效。
        {kind,slots,batches,point_group,weight_base,param_base}='0; // 确定默认值，避免锁存。
        case (layer_id) // 逐层固定形状和真实镜像基址。
            5'd0: {kind,slots,batches,point_group,weight_base,param_base}={3'd0,2'd1,2'd1,3'd1,12'd0,12'd1989}; // stem层。
            5'd1: {kind,slots,batches,point_group,weight_base,param_base}={3'd1,2'd1,2'd1,3'd1,12'd39,12'd2009}; // enc.hconv层。
            5'd2: {kind,slots,batches,point_group,weight_base,param_base}={3'd1,2'd1,2'd1,3'd1,12'd78,12'd2029}; // enc.vconv层。
            5'd3: {kind,slots,batches,point_group,weight_base,param_base}={3'd0,2'd3,2'd2,3'd1,12'd117,12'd2049}; // down层。
            5'd4: {kind,slots,batches,point_group,weight_base,param_base}={3'd2,2'd2,2'd2,3'd1,12'd351,12'd2089}; // body.0.hconv层。
            5'd5: {kind,slots,batches,point_group,weight_base,param_base}={3'd2,2'd2,2'd2,3'd1,12'd507,12'd2129}; // body.0.vconv层。
            5'd6: {kind,slots,batches,point_group,weight_base,param_base}={3'd2,2'd2,2'd2,3'd1,12'd663,12'd2169}; // body.1.hconv层。
            5'd7: {kind,slots,batches,point_group,weight_base,param_base}={3'd2,2'd2,2'd2,3'd1,12'd819,12'd2209}; // body.1.vconv层。
            5'd8: {kind,slots,batches,point_group,weight_base,param_base}={3'd2,2'd2,2'd2,3'd1,12'd975,12'd2249}; // body.2.hconv层。
            5'd9: {kind,slots,batches,point_group,weight_base,param_base}={3'd2,2'd2,2'd2,3'd1,12'd1131,12'd2289}; // body.2.vconv层。
            5'd10: {kind,slots,batches,point_group,weight_base,param_base}={3'd2,2'd2,2'd2,3'd1,12'd1287,12'd2329}; // body.3.hconv层。
            5'd11: {kind,slots,batches,point_group,weight_base,param_base}={3'd2,2'd2,2'd2,3'd1,12'd1443,12'd2369}; // body.3.vconv层。
            5'd12: {kind,slots,batches,point_group,weight_base,param_base}={3'd0,2'd3,2'd1,3'd1,12'd1599,12'd2409}; // reduce层。
            5'd13: {kind,slots,batches,point_group,weight_base,param_base}={3'd1,2'd1,2'd1,3'd1,12'd1716,12'd2429}; // dec.hconv层。
            5'd14: {kind,slots,batches,point_group,weight_base,param_base}={3'd1,2'd1,2'd1,3'd1,12'd1755,12'd2449}; // dec.vconv层。
            5'd15: {kind,slots,batches,point_group,weight_base,param_base}={3'd3,2'd2,2'd1,3'd4,12'd1794,12'd2469}; // head层。
            5'd16: {kind,slots,batches,point_group,weight_base,param_base}={3'd4,2'd3,2'd1,3'd4,12'd1872,12'd2489}; // rgb层。
            default: desc_valid=1'b0; // 非法层无效且字段全零。
        endcase // 层译码结束。
    end // 组合查询结束。
endmodule // 描述符模块结束。
