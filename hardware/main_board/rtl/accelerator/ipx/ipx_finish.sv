// FX intensity blend is a four-phase envelope around the color-only effect.
module ipx_finish(
    input logic clk,clear,step,
    input logic [1:0] phase,
    input wire ipx_types::config_t cfg,
    input logic in_valid,
    input logic [17:0] in_data,
    input wire ipx_types::meta_t in_meta,
    output logic out_valid,
    output logic [17:0] out_data
);
    import ipx_types::*;
    logic [11:0] partial_q;
    wire [5:0] effect_component=component(in_data,phase);
    wire signed [6:0] difference=$signed({1'b0,effect_component})-$signed({1'b0,component(in_meta.original,phase)});
    wire signed [28:0] product;
    wire signed [7:0] rounded=($signed(product[15:0])+16'sd128)>>>8;
    wire [1:0] returned_channel=phase-2'd1;
    wire signed [7:0] mixed=rounded+$signed({2'b0,component(in_meta.original,returned_channel)});
    ipx_mult u_mix(.clk(clk),.enable(step&&phase<3),.value({{12{difference[6]}},difference}),
        .coefficient({1'b0,cfg.alpha}),.product(product));
    always_ff @(posedge clk)begin
        if(clear)out_valid<=0;
        else if(step)begin
            if(phase==1)partial_q[5:0]<=clip_u6(mixed);
            if(phase==2)partial_q[11:6]<=clip_u6(mixed);
            if(phase==3)begin
                out_data<={clip_u6(mixed),partial_q};
                out_valid<=in_valid;
            end
        end
    end
endmodule
