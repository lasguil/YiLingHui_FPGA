function automatic [9:0] isp_clip10;
    input signed [31:0] x;
    begin
        if (x < 0)
            isp_clip10 = 10'd0;
        else if (x > 32'sd1023)
            isp_clip10 = 10'd1023;
        else
            isp_clip10 = x[9:0];
    end
endfunction

function automatic [7:0] isp_clip8;
    input signed [31:0] x;
    begin
        if (x < 0)
            isp_clip8 = 8'd0;
        else if (x > 32'sd255)
            isp_clip8 = 8'd255;
        else
            isp_clip8 = x[7:0];
    end
endfunction

function automatic [15:0] isp_clip_gain;
    input [31:0] x;
    begin
        if (x < `ISP_GAIN_MIN)
            isp_clip_gain = `ISP_GAIN_MIN;
        else if (x > `ISP_GAIN_MAX)
            isp_clip_gain = `ISP_GAIN_MAX;
        else
            isp_clip_gain = x[15:0];
    end
endfunction
