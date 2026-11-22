// AI前混合：M=O+round((N-O)*ai_alpha/256)，三个通道串行共用一颗DSP。
// 仅部分强度使用此四拍级；端点由DMA选择单源，直接旁路。
// 输出被窗口虚拟边界/像素化重放阻塞时保持，窗口仍可独立推进。
module ipx_ai_mix(
    input logic clk,clear,run,step,
    input logic [1:0] phase,
    input wire ipx_types::config_t cfg,
    input logic in_valid,
    output logic in_ready,
    input logic [17:0] in_data,in_original,
    output logic out_valid,
    input logic out_ready,
    output logic [17:0] out_data
);
    import ipx_types::*;
    wire enabled=cfg.ai_enable&&cfg.ai_alpha!=0&&cfg.ai_alpha!=256;
    logic slot_q,valid_q;
    logic [17:0] source_q,original_q,data_q;
    logic [11:0] partial_q;
    wire take=in_valid&&in_ready;
    wire [17:0] source=phase==0?in_data:source_q;
    wire [17:0] original=phase==0?in_original:original_q;
    wire signed [6:0] difference=$signed({1'b0,component(source,phase)})
                                -$signed({1'b0,component(original,phase)});
    wire signed [28:0] product;
    wire signed [7:0] rounded=($signed(product[15:0])+16'sd128)>>>8;
    wire [1:0] channel=phase-2'd1;
    wire signed [7:0] mixed=rounded+$signed({2'b0,component(original_q,channel)});
    wire multiply=run&&step&&enabled&&(phase==0?take:(phase<3&&slot_q));

    assign in_ready=enabled ? run&&step&&phase==0&&(!valid_q||out_ready) : out_ready;
    assign out_valid=enabled ? valid_q : in_valid;
    assign out_data=enabled ? data_q : in_data;
    ipx_mult u_mix(.clk(clk),.enable(multiply),
        .value({{12{difference[6]}},difference}),
        .coefficient({1'b0,cfg.ai_alpha}),.product(product));

    always_ff @(posedge clk)begin
        if(clear)begin slot_q<=0;valid_q<=0;end
        else if(step&&enabled)begin
            if(phase==0)begin
                slot_q<=take;
                if(out_ready)valid_q<=0;
                if(take)begin source_q<=in_data;original_q<=in_original;end
            end
            if(slot_q&&phase==1)partial_q[5:0]<=clip_u6(mixed);
            if(slot_q&&phase==2)partial_q[11:6]<=clip_u6(mixed);
            if(slot_q&&phase==3)begin data_q<={clip_u6(mixed),partial_q};valid_q<=1;end
        end
    end
endmodule
