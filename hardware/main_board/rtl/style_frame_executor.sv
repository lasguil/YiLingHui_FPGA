// One CPU-submitted frame. NPU owns its internal strip/row schedule;
// this unit starts the matching IPX tasks and grants each stream credit.
// All parameters are latched at START. No camera polling, boot or UI policy.
module style_frame_executor(
    input wire clk,reset,start,clear_done,
    input wire [31:0] original,npu_rgb,final_base,x0,rgb_bytes,
    input wire [15:0] visible_width,height,rgb_stride,x0_stride,
    output logic busy,done,fault,
    output logic op_valid,op_read,
    output logic [1:0] op_target,
    output logic [11:0] op_address,
    output logic [31:0] op_data,
    input wire op_ready,op_done,op_error,
    input wire [31:0] read_data
);
    import demo_bus_pkg::*;
    typedef enum logic [3:0]{IDLE,CHECK_OPTIONS,CHECK_MODEL,CHECK_TABLES,CONFIGURE,
        POST_CONFIG,NPU_START,RUN,WAIT_DRAIN,CLEAR_EVENTS,FAILED} state_t;
    state_t state;
    logic [31:0] original_q,rgb_q,final_q,x0_q,rgb_bytes_q;
    logic [15:0] visible_q,width_q,height_q,stride_q,x0_stride_q,x_q;
    logic n_finished,p_finished,poll_post,waiting;
    logic [4:0] step;
    wire [15:0] strip_width=(width_q-x_q>480)?16'd480:width_q-x_q;
    wire [7:0] seam_lo=x_q==0?8'd0:8'd8;
    wire [7:0] seam_hi=x_q+strip_width<width_q?8'd8:8'd0;
    wire [15:0] post_width=strip_width+{8'd0,seam_lo}+{8'd0,seam_hi};
    wire [31:0] offset={15'd0,x_q,1'b0};
    always_comb begin
        op_valid=!waiting;op_read=0;op_target=0;op_address=0;op_data=0;
        case(state)
            CHECK_OPTIONS:begin op_read=1;op_target=1;op_address=12'h028;end
            CHECK_MODEL:begin op_read=1;op_address=12'h004;end
            CHECK_TABLES:begin op_read=1;op_target=1;op_address=12'h05c;end
            CONFIGURE:case(step)
                0:begin op_target=2;op_address=12'h008;op_data=rgb_q;end
                1:begin op_target=2;op_address=12'h00c;op_data=rgb_q+rgb_bytes_q;end
                2:begin op_target=2;op_address=12'h000;op_data=2;end
                3:begin op_address=12'h00c;op_data=15;end
                4:begin op_address=12'h008;op_data=15;end
                5:begin op_address=12'h010;op_data={2'b0,height_q[15:2],2'b0,width_q[15:2]};end
                6:begin op_address=12'h014;op_data=original_q;end
                7:begin op_address=12'h018;op_data=rgb_q;end
                8:begin op_address=12'h01c;op_data=x0_q;end
                9:begin op_address=12'h020;op_data={16'd0,stride_q};end
                10:begin op_address=12'h024;op_data={16'd0,stride_q};end
                11:begin op_address=12'h028;op_data={16'd0,x0_stride_q};end
                12:begin op_target=1;op_address=12'h06c;op_data={16'd0,stride_q};end
                13:begin op_target=1;op_address=12'h01c;op_data={16'd0,stride_q};end
                14:begin op_target=1;op_address=12'h06c;op_data={16'd0,stride_q};end
                15:begin op_target=1;op_address=12'h008;op_data=12;end
                default:op_valid=0;
            endcase
            POST_CONFIG:begin
                op_target=1;
                case(step)
                    0:begin op_address=12'h04c;op_data={16'd0,seam_hi,seam_lo};end
                    1:begin op_address=12'h014;op_data=final_q+offset;end
                    2:begin op_address=12'h068;op_data=original_q+offset-{23'd0,seam_lo,1'b0};end
                    3:begin op_address=12'h020;op_data={height_q,post_width};end
                    4:begin op_address=12'h024;op_data={height_q,strip_width};end
                    5:begin op_address=12'h008;op_data=9;end
                    default:op_valid=0;
                endcase
            end
            NPU_START:begin op_address=0;op_data=1;end
            RUN:begin op_read=1;op_target=poll_post?1:0;op_address=poll_post?12'h00c:12'h008;end
            WAIT_DRAIN:begin op_read=1;op_target=2;op_address=12'h004;end
            CLEAR_EVENTS:begin op_address=12'h008;op_data=15;end
            default:op_valid=0;
        endcase
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            state<=IDLE;busy<=0;done<=0;fault<=0;waiting<=0;step<=0;
            original_q<=0;rgb_q<=0;final_q<=0;x0_q<=0;rgb_bytes_q<=0;
            visible_q<=0;width_q<=0;height_q<=0;stride_q<=0;x0_stride_q<=0;x_q<=0;
            n_finished<=0;p_finished<=0;poll_post<=0;
        end else begin
            if(clear_done)done<=0;
            if(op_valid&&op_ready)waiting<=1;
            if(op_done)waiting<=0;
            if(op_done && op_error)begin fault<=1;state<=FAILED;end
            else case(state)
                IDLE:if(start)begin
                    original_q<=original;rgb_q<=npu_rgb;final_q<=final_base;x0_q<=x0;rgb_bytes_q<=rgb_bytes;
                    visible_q<=visible_width;width_q<=visible_width==854?16'd856:visible_width;
                    height_q<=height;stride_q<=rgb_stride;x0_stride_q<=x0_stride;
                    x_q<=0;n_finished<=0;p_finished<=0;
                    poll_post<=0;busy<=1;done<=0;fault<=0;state<=CHECK_OPTIONS;
                end
                CHECK_OPTIONS:if(op_done)begin
                    // Color mode is a two-bit selector; all four values are valid.
                    if(read_data[8:6]!=0)begin fault<=1;state<=FAILED;end
                    else state<=CHECK_MODEL;
                end
                CHECK_MODEL:if(op_done)begin
                    if(!read_data[3])begin fault<=1;state<=FAILED;end
                    else state<=CHECK_TABLES;
                end
                CHECK_TABLES:if(op_done)begin
                    if(!read_data[0] || read_data[1])begin fault<=1;state<=FAILED;end
                    else begin step<=0;state<=CONFIGURE;end
                end
                CONFIGURE:if(op_done)begin
                    if(step==15)begin step<=0;state<=POST_CONFIG;end
                    else step<=step+1'b1;
                end
                POST_CONFIG:if(op_done)begin
                    if(step==5)begin
                        poll_post<=0;state<=(!n_finished && x_q==0)?NPU_START:RUN;
                    end else step<=step+1'b1;
                end
                NPU_START:if(op_done)state<=RUN;
                RUN:if(op_done)begin
                    poll_post<=!poll_post;
                    if(!poll_post)begin
                        if(read_data[3] || read_data[1])begin fault<=1;state<=FAILED;end
                        else if(read_data[0])begin
                            n_finished<=1;
                            
                        end
                    end else if(read_data[7:4]!=0)begin fault<=1;state<=FAILED;end
                    else if(read_data[1])begin
                        if(x_q+480<width_q)begin x_q<=x_q+480;step<=0;state<=POST_CONFIG;end
                        else p_finished<=1;
                    end
                    if(n_finished && p_finished)state<=WAIT_DRAIN;
                end
                WAIT_DRAIN:if(op_done && !read_data[0])state<=CLEAR_EVENTS;
                CLEAR_EVENTS:if(op_done)begin busy<=0;done<=1;state<=IDLE;end
                FAILED:begin busy<=0;end // Fault keeps ownership; CPU must not recycle its buffers.
                default:state<=IDLE;
            endcase
        end
    end
endmodule
