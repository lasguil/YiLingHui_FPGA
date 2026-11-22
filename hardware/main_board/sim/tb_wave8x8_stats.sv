`timescale 1ns/1ps
module tb_wave8x8_stats;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,enable=1,in_vs=0,in_de=0;
    reg [7:0] in_green=0;reg [1:0] mode=0;
    wire frame_start,block_valid;wire [5:0] block_index,block_mean;
    wave_roi_stats dut(.*);
    integer sums[0:63];integer expected[0:63];integer received=0;
    integer x,y,i,k,bw,bh,selected_mode,w,h,pattern;
    reg checking=0;
    always @(negedge clk)if(block_valid&&checking)begin
        if(block_index!==received||block_mean!==expected[received])
            $fatal(1,"statistics mode=%0d block=%0d/%0d mean=%0d/%0d",mode,block_index,received,block_mean,expected[received]);
        received++;
    end
    task automatic run_frame(input integer test_mode,input integer width,height,white);
        integer xx,yy,idx,v;
        begin
            bw=width/8;bh=height/8;
            for(idx=0;idx<64;idx++)begin sums[idx]=0;expected[idx]=0;end
            // Build exact independent sums BEFORE transmitting any pixels.
            for(yy=0;yy<height;yy++)for(xx=0;xx<width;xx++)begin
                v=white?255:((yy/bh)*29+(xx/bw)*19+(xx%11)*3+(yy%7)*5)%256;
                if(xx<8*bw&&yy<8*bh)sums[(yy/bh)*8+xx/bw]+=v;
            end
            for(idx=0;idx<64;idx++)expected[idx]=sums[idx]/(4*bw*bh);
            received=0;checking=1;mode=2'(test_mode);in_vs=1;in_de=0;
            repeat(12)@(negedge clk);in_vs=0;
            for(yy=0;yy<height;yy++)begin
                for(xx=0;xx<width;xx++)begin
                    in_de=1;in_green=8'(white?255:((yy/bh)*29+(xx/bw)*19+(xx%11)*3+(yy%7)*5)%256);
                    @(negedge clk);
                    if(xx%127==31)begin in_de=0;@(negedge clk);end
                end
                in_de=0;repeat(3)@(negedge clk);
            end
            repeat(20)@(negedge clk);
            if(received!=64)$fatal(1,"missing blocks %0d",received);
            checking=0;$display("PASS WAVE STATS mode=%0d %0dx%0d white=%0d 64 exact means",test_mode,width,height,white);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst_n=1;
        run_frame(0,1920,1080,0);run_frame(0,1920,1080,1);
        run_frame(1,1280,720,0);run_frame(2,854,480,0);
        enable=0;repeat(3)@(negedge clk);if(block_valid)$fatal(1,"disabled frontend emits");
        $display("PASS WAVE FRONTEND all camera modes, DE holes, exact crop/quantisation, restart");$finish;
    end
    initial begin #1000000000;$fatal(1,"global timeout");end
endmodule
