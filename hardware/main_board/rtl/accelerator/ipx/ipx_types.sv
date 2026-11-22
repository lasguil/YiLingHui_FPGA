// Configuration and token formats for the color-only IPX pipeline.
package ipx_types;
    typedef enum logic [1:0] {
        RGB_CURVE=2'd0,
        GRAY_PALETTE=2'd1,
        DUOTONE_DOT=2'd2,
        RGB_DOT=2'd3
    } color_mode_t;
    typedef struct packed {
        logic [31:0] dst,frame_id;
        logic [31:0] original_src;
        logic [15:0] dst_stride,original_stride;
        logic [10:0] width,height,dst_width,dst_height;
        logic [3:0] st_lo,st_hi;
        color_mode_t color;
        logic preserve;
        logic [9:0] saturation,saturation_out;
        logic [23:0] color_min,color_max;
        logic [8:0] alpha;
        logic ai_enable;
        logic [8:0] ai_alpha;
    } config_t;
    function automatic logic [10:0] stream_width(input config_t cfg);
        stream_width=cfg.dst_width+11'(cfg.st_lo)+11'(cfg.st_hi);
    endfunction
    typedef struct packed {
        logic [17:0] original;
        logic [3:0] pattern;
    } meta_t;
    function automatic logic [17:0] rgb888_to_u6(input logic [23:0] rgb);
        rgb888_to_u6={rgb[23:18],rgb[15:10],rgb[7:2]};
    endfunction
    function automatic logic [7:0] u6_to_u8(input logic [5:0] value);
        u6_to_u8={value,value[5:4]};
    endfunction
    function automatic logic [23:0] u6_to_rgb888(input logic [17:0] rgb);
        u6_to_rgb888={{rgb[17:12],rgb[17:16]}, {rgb[11:6],rgb[11:10]}, {rgb[5:0],rgb[5:4]}};
    endfunction
    function automatic logic [15:0] pack_rgb565(input logic [17:0] rgb);
        pack_rgb565={rgb[5:1],rgb[11:6],rgb[17:13]};
    endfunction
    function automatic logic [17:0] expand_rgb565(input logic [15:0] rgb);
        expand_rgb565={{rgb[4:0],rgb[4]},rgb[10:5],{rgb[15:11],rgb[15]}};
    endfunction
    function automatic logic [5:0] gray(input logic [17:0] rgb);
        logic [7:0] sum;
        begin sum={2'b0,rgb[5:0]}+{1'b0,rgb[11:6],1'b0}+{2'b0,rgb[17:12]}+8'd2;
            gray=sum[7:2];
        end
    endfunction
    function automatic logic [5:0] clip_u6(input logic signed [15:0] value);
        begin if(value<0)clip_u6=0;
            else if(value>63)clip_u6=63;
            else clip_u6=value[5:0];
        end
    endfunction
    function automatic logic [5:0] component(input logic [17:0] rgb,input logic [1:0] channel);
        begin case(channel)0:component=rgb[5:0];
                1:component=rgb[11:6];
                default:component=rgb[17:12];
            endcase end
    endfunction
    function automatic logic [3:0] bayer(input logic [1:0] x,y);
        begin bayer={x[0]^y[0],y[0],x[1]^y[1],y[1]};
        end
    endfunction
endpackage
