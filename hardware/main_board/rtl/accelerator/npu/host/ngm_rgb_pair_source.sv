// 4..128 little endian RGB565 pixels per row; pairs never cross AXI words.
// D holds the top word under backpressure. Only the bottom word is buffered.
module ngm_rgb_pair_source(
    input logic clk,reset,abort,segment_start,
    input logic reflect_480, // 856x480 processing shape carries 854 real columns.
    input logic [9:0] segment_x,
    input logic [6:0] segment_pairs,
    output logic req_valid,input logic req_ready,
    output logic [4:0] req_word,
    input logic rsp_valid,output logic rsp_ready,
    input logic [127:0] rsp_data,
    input logic bottom_valid,output logic bottom_ready,
    input logic [127:0] bottom_data,
    input logic [15:0] bottom_keep,
    output logic pair_valid,input logic pair_ready,
    output logic [9:0] pair_x,
    output logic [127:0] pair_data,
    output logic segment_consumed
);
    logic active_q,pending_q;
    logic [6:0] left_q;
    logic [1:0] top_pair_q;
    logic [4:0] bottom_count_q;
    logic [127:0] bottom_q;
    logic [31:0] top_pair,bottom_pair;
    logic [4:0] incoming_count;
    wire take=pair_valid&&pair_ready;
    assign req_valid=active_q&&!pending_q&&!abort;
    assign bottom_ready=active_q&&!abort&&rsp_valid&&bottom_count_q==0&&pair_ready;
    assign pair_valid=active_q&&!abort&&rsp_valid&&(bottom_count_q!=0||bottom_valid);
    assign rsp_ready=!abort&&take&&(left_q==1||top_pair_q==3);
    // Expand RGB565 by bit replication, then the model's unchanged >>1.
    function automatic [23:0] quantize(input logic [15:0] p);
        quantize={{1'b0,p[4:0],p[4:3]},
                  {1'b0,p[10:5],p[10]},
                  {1'b0,p[15:11],p[15:14]}};
    endfunction
    logic [23:0] t0,t1,b0,b1;
    always_comb begin
        case(top_pair_q)
            0:top_pair=rsp_data[31:0];1:top_pair=rsp_data[63:32];
            2:top_pair=rsp_data[95:64];3:top_pair=rsp_data[127:96];
        endcase
        // reflect (no repeated edge): 854 <- 852, 855 <- 851.
        // Both source pixels are already in the final top AXI word.
        if(reflect_480&&pair_x==427)top_pair={rsp_data[63:48],rsp_data[79:64]};
        bottom_pair=bottom_count_q!=0?bottom_q[31:0]:bottom_data[31:0];
        case(bottom_keep)
            16'hffff:incoming_count=16;16'h00ff:incoming_count=8;
            default:incoming_count=0;
        endcase
        t0=quantize(top_pair[15:0]);t1=quantize(top_pair[31:16]);
        b0=quantize(bottom_pair[15:0]);b1=quantize(bottom_pair[31:16]);
        pair_data=0;
        for(int c=0;c<3;c++)begin
            pair_data[(c*4+0)*8+:8]=t0[c*8+:8];
            pair_data[(c*4+1)*8+:8]=t1[c*8+:8];
            pair_data[(c*4+2)*8+:8]=b0[c*8+:8];
            pair_data[(c*4+3)*8+:8]=b1[c*8+:8];
        end
    end
    always_ff @(posedge clk)begin
        if(reset||abort)begin
            active_q<=0;pending_q<=0;left_q<=0;req_word<=0;pair_x<=0;
            top_pair_q<=0;bottom_count_q<=0;segment_consumed<=0;
        end else begin
            segment_consumed<=0;
            if(segment_start)begin
                active_q<=1;pending_q<=0;left_q<=segment_pairs;pair_x<=segment_x;
                req_word<=0;top_pair_q<=0;bottom_count_q<=0;
            end else begin
                if(req_valid&&req_ready)pending_q<=1;
                if(take)begin
                    left_q<=left_q-1'b1;pair_x<=pair_x+1'b1;
                    top_pair_q<=top_pair_q+1'b1;
                    if(top_pair_q==3)begin pending_q<=0;req_word<=req_word+1'b1;end
                    if(bottom_count_q!=0)begin
                        bottom_q<={32'b0,bottom_q[127:32]};bottom_count_q<=bottom_count_q-5'd4;
                    end else begin
                        // Replace hidden padding at the final word's first pair;
                        // reuse bottom_q, so no new data register or line buffer.
                        bottom_q<={32'b0,
                            (reflect_480&&pair_x==424 ? {bottom_data[63:48],bottom_data[79:64]} : bottom_data[127:96]),
                            bottom_data[95:32]};bottom_count_q<=incoming_count-5'd4;
                    end
                    if(left_q==1)begin active_q<=0;pending_q<=0;bottom_count_q<=0;segment_consumed<=1;end
                end
            end
        end
    end
`ifdef SIM_ASSERT
    always @(posedge clk)if(!reset&&!abort)begin
        if(segment_start&&(active_q||segment_pairs<2||segment_pairs>64||segment_pairs[0]))$fatal(1,"RGB pair invalid segment");
        if(bottom_valid&&bottom_ready&&incoming_count==0)$fatal(1,"RGB pair invalid bottom keep");
        if(req_valid&&req_ready&&req_word>=16)$fatal(1,"RGB pair upper word overflow");
    end
`endif
endmodule
