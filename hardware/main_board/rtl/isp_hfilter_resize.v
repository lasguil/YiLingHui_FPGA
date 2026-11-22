// RGB10 [1,2,1]/4 before CCM/Gamma, shared by 720p and 854x480.
// Two pixel-history registers per channel; no added line RAM or DSP.
// Pixel counters advance on DE only, preserving short holes and the
// existing ISP's delayed two right-edge pixels.
module isp_hfilter_resize #(parameter WIDTH=1920,HEIGHT=1080)(
    input wire clk,rst_n,in_vs,in_de,
    input wire [1:0] mode,input wire [29:0] in_rgb,
    output reg out_vs,out_de,output reg [29:0] out_rgb
);
    reg vs_d,pad_pending;
    wire frame_start=in_vs && !vs_d;
    reg [10:0] x,y,sx,sy;
    reg [9:0] xr;
    reg [1:0] xp3,yp3,yp4;
    reg [29:0] prev1,prev2;
    wire [10:0] xr_next={1'b0,xr}+11'd212;
    // The filter is centered on x-1. Incoming phases 1/0 correspond
    // to the original sampled source positions 0/2 in each group of 3.
    wire sample720=in_de && x!=0 && xp3!=2 && yp3!=1 && y<HEIGHT;
    wire sample480=in_de && x==sx+11'd1 && y==sy && y<HEIGHT;
    wire filter_valid=(mode==1) ? (sample720 || pad_pending) : sample480;
    wire [29:0] left=(x==1 && !pad_pending) ? prev1 : prev2;
    wire [29:0] right=pad_pending ? prev1 : in_rgb;
    wire [29:0] filtered;
    genvar c;
    generate for(c=0;c<3;c=c+1)begin: channel
        wire [11:0] sum={2'b0,left[c*10+:10]}+
                        {1'b0,prev1[c*10+:10],1'b0}+
                        {2'b0,right[c*10+:10]}+12'd2;
        assign filtered[c*10+:10]=sum[11:2];
    end endgenerate
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            vs_d<=0;out_vs<=0;out_de<=0;out_rgb<=0;
            x<=0;y<=0;sx<=1;sy<=1;xr<=106;xp3<=0;yp3<=0;yp4<=0;
            prev1<=0;prev2<=0;pad_pending<=0;
        end else begin
            vs_d<=in_vs;out_vs<=in_vs;out_de<=0;pad_pending<=0;
            if(frame_start)begin
                x<=0;y<=0;sx<=1;sy<=1;xr<=106;
                xp3<=0;yp3<=0;yp4<=0;prev1<=0;prev2<=0;pad_pending<=0;
            end else begin
                // A right-edge flush may coincide with next row's x=0:
                // that input has no filtered output, so both can proceed.
                if(mode==0)begin out_de<=in_de;out_rgb<=in_rgb;end
                else begin out_de<=filter_valid;out_rgb<=filtered;end
                if(in_de)begin
                    prev1<=in_rgb;prev2<=prev1;
                    if(mode==2 && sample480)begin
                        sx<=sx+((xr_next>=854) ? 11'd3 : 11'd2);
                        xr<=(xr_next>=854) ? xr_next-11'd854 : xr_next;
                    end
                    if(x==WIDTH-1)begin
                        pad_pending<=mode==1 && yp3!=1 && y<HEIGHT;
                        x<=0;y<=y+11'd1;xp3<=0;
                        yp3<=(yp3==2) ? 2'd0 : yp3+2'd1;
                        sx<=1;xr<=106;
                        if(y==sy)begin
                            sy<=sy+((yp4==3) ? 11'd3 : 11'd2);
                            yp4<=yp4+2'd1;
                        end
                    end else begin
                        x<=x+11'd1;xp3<=(xp3==2) ? 2'd0 : xp3+2'd1;
                    end
                end
            end
        end
    end
endmodule
