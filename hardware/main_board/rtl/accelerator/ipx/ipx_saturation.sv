// 协议契约：R/G/B在p0/p1/p2发射一颗DSP，p1/p2/p3收回，输出valid在p3提交。
module ipx_saturation( // 一个乘法器供三个通道共用，绝不跨流水级共用。
    input logic clk,clear,step, // 数据和元数据共用暂停。
    input logic [1:0] phase, // 四拍相位。
    input wire ipx_types::config_t cfg, // 任务固定系数与选区。
    input logic in_valid, // 空间结果有效。
    input logic [17:0] in_data, // 空间处理后的RGB。
    input wire ipx_types::meta_t in_meta, // 混合原值和图案。
    output logic out_valid, // 完整RGB有效。
    output logic [17:0] out_data, // 饱和度处理结果。
    output ipx_types::meta_t out_meta // 原中心保持不变。
); // 接口结束。
    import ipx_types::*; // 定点灰度与裁剪。
    logic [11:0] partial_q; // 返回R/G暂存，p3一次发布完整RGB。
    wire [5:0] luminance=gray(in_data); // 只计算一次当前像素灰度。
    wire [23:0] compare_rgb=u6_to_rgb888(in_data); // 接线扩展仅恢复像素域，不量化公开边界。
    wire inside_box=compare_rgb[7:0]>=cfg.color_min[7:0]&&compare_rgb[7:0]<=cfg.color_max[7:0]&&compare_rgb[15:8]>=cfg.color_min[15:8]&&compare_rgb[15:8]<=cfg.color_max[15:8]&&compare_rgb[23:16]>=cfg.color_min[23:16]&&compare_rgb[23:16]<=cfg.color_max[23:16]; // 原8位RGB长方体语义。
    wire [9:0] coefficient=cfg.color==1||cfg.color==2 ? 10'd256 : cfg.preserve ? (inside_box?10'd256:10'd0) : cfg.saturation; // 配色/灰度网点保留输入亮度。
    wire signed [6:0] difference=$signed({1'b0,component(in_data,phase)})-$signed({1'b0,luminance}); // U6通道差-63..63，signed7。
    wire signed [28:0] product; // 一拍DSP乘积。
    wire signed [7:0] rounded=($signed(product[15:0])+16'sd128)>>>8; // -32256..32256加偏置后算术右移为-126..126。
    wire signed [8:0] value=rounded+$signed({3'b0,luminance}); // 明确为-126..189，裁剪前保留符号和越界值。
    ipx_mult u_mult(.clk(clk),.enable(step&&phase<3),.value({{12{difference[6]}},difference}), // 一颗DSP。
        .coefficient(coefficient),.product(product)); // 一颗DSP。
    always_ff @(posedge clk)begin // 数据无复位，valid隔离旧任务。
        if(clear)out_valid<=0; // 新任务不携带旧像素。
        else if(step)begin // 公共相位保证乘法与原值对齐。
            if(phase==1)partial_q[5:0]<=clip_u6(value); // p1收R，显式字节CE。
            if(phase==2)partial_q[11:6]<=clip_u6(value); // p2收G。
            if(phase==3)begin out_data<={clip_u6(value),partial_q}; // p3收B并发布，灰度输入不读半更新像素。
                out_valid<=in_valid; // p3收B并发布，灰度输入不读半更新像素。
                out_meta<=in_meta; // p3收B并发布，灰度输入不读半更新像素。
            end // p3收B并发布，灰度输入不读半更新像素。
        end // 推进结束。
    end // 寄存器结束。
endmodule // 饱和度结束。
