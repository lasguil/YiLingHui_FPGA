`timescale 1ns/1ps
module tb_keep_rgb;
    import ipx_types::*;
    logic clk=0,clear=1,step=0,in_valid=0;
    always #5 clk=~clk;
    logic [1:0] phase=0;
    config_t cfg;
    meta_t meta,out_meta;
    logic [17:0] rgb,result;
    logic valid;
    ipx_saturation dut(.clk,.clear,.step,.phase,.cfg,.in_valid,.in_data(rgb),
        .in_meta(meta),.out_valid(valid),.out_data(result),.out_meta);
    task automatic check(input logic [17:0] sample,input logic [17:0] expected);
        logic [17:0] held;
        begin
            @(negedge clk);rgb=sample;meta.original=sample;meta.pattern=4'h9;in_valid=1;step=1;
            for(integer i=0;i<4;i++)begin
                phase=2'(i);@(posedge clk);#1;
                if(i==3)begin
                    if(!valid||result!==expected||out_meta!==meta)
                        $fatal(1,"keep mismatch sample=%h result=%h expected=%h",sample,result,expected);
                end
                @(negedge clk);
                // Freeze each DSP phase, including the return/publish phase.
                held=result;step=0;@(posedge clk);#1;
                if(result!==held)$fatal(1,"stall changed output");
                @(negedge clk);step=1;
            end
            step=0;
        end
    endtask
    logic [17:0] sample;
    logic [23:0] expanded;
    logic inside_box;
    logic [5:0] luminance;
    initial begin
        cfg='0;meta='0;rgb=0;
        repeat(3)@(negedge clk);clear=0;
        cfg.preserve=1;cfg.saturation=512;
        cfg.saturation_out=512; // Retired CSR must not restore outside color.
        for(integer preset=0;preset<3;preset++)begin
            case(preset)
                0:begin cfg.color_min=24'h000080;cfg.color_max=24'h9191ff;end
                1:begin cfg.color_min=24'h003700;cfg.color_max=24'h78ff4b;end
                2:begin cfg.color_min=24'h640000;cfg.color_max=24'hffb9a0;end
            endcase
            for(integer n=0;n<120;n++)begin
                sample=18'($random);expanded=u6_to_rgb888(sample);luminance=gray(sample);
                inside_box=1;
                for(integer channel=0;channel<3;channel++)
                    if(expanded[channel*8+:8]<cfg.color_min[channel*8+:8]||
                       expanded[channel*8+:8]>cfg.color_max[channel*8+:8])inside_box=0;
                check(sample,inside_box?sample:{luminance,luminance,luminance});
            end
        end
        cfg.preserve=0;cfg.saturation=256;
        check(18'h12345,18'h12345); // Ordinary saturation remains independent.
        $display("PASS RGB keep: 360 samples, fixed zero outside, phase stalls and normal saturation");
        $finish;
    end
endmodule
