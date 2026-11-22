// Control/status and single 768-byte RGB-plane table loader.
module ipx_regs #(parameter integer MAX_ROW_WIDTH=2048)(
    input wire csr_valid,csr_write,
    input wire [11:0] csr_address,
    input wire [31:0] csr_wdata,
    input wire [3:0] csr_wstrb,
    output logic csr_ready,csr_error,
    output wire [31:0] csr_rdata,
    input logic clk,reset,busy,done_event,
    input logic [3:0] error_code,
    input logic [31:0] cycles,input_pixels,output_pixels,read_beats,write_beats,input_stalls,output_stalls,
    output ipx_types::config_t shadow,
    output logic start,abort,
    output logic table_write,
    output logic [9:0] table_address,
    output logic [7:0] table_data,
    output wire table_valid,
    output logic irq,
    output logic table_dma_start,
    input logic table_byte_valid,
    output wire table_byte_ready,
    input logic [7:0] table_byte_data,
    input logic table_dma_finish,table_dma_error
);
    import ipx_types::*;
    logic irq_enable_q,done_q,loading_q,dma_loading_q;
    logic [9:0] index_q,loaded_q;
    logic [15:0] generation_q;
    logic [3:0] last_error_q;
    wire commit=csr_valid&&csr_write&&!csr_ready;
    wire accepted_start=commit&&csr_address[7:2]==6'h02&&csr_wstrb[0]&&csr_wdata[0]&&!busy&&table_valid;
    wire [31:0] byte_mask={{8{csr_wstrb[3]}},{8{csr_wstrb[2]}},{8{csr_wstrb[1]}},{8{csr_wstrb[0]}}};
    wire [31:0] options={22'b0,shadow.preserve,3'b0,shadow.color,4'b0};
    wire [31:0] checked_word=csr_wdata&byte_mask;
    logic [31:0] read_word;
    logic table_valid_q;
    assign irq=irq_enable_q&&done_q;
    assign csr_rdata=read_word;
    assign table_valid=table_valid_q;
    assign table_byte_ready=dma_loading_q&&busy;
    always_comb begin
        read_word=0;
        read_word=({32{csr_address[7:2]==6'h00}}&32'h49505821)|
            ({32{csr_address[7:2]==6'h01}}&32'h000005f1)|
            ({32{csr_address[7:2]==6'h02}}&{28'b0,irq_enable_q,3'b0})|
            ({32{csr_address[7:2]==6'h03}}&{24'b0,last_error_q,2'b0,done_q,busy})|
            ({32{csr_address[7:2]==6'h05}}&shadow.dst)|
            ({32{csr_address[7:2]==6'h07}}&{16'b0,shadow.dst_stride})|
            ({32{csr_address[7:2]==6'h08}}&{5'b0,shadow.height,5'b0,shadow.width})|
            ({32{csr_address[7:2]==6'h09}}&{5'b0,shadow.dst_height,5'b0,shadow.dst_width})|
            ({32{csr_address[7:2]==6'h0a}}&options)|
            ({32{csr_address[7:2]==6'h0b}}&{6'b0,shadow.saturation_out,6'b0,shadow.saturation})|
            ({32{csr_address[7:2]==6'h0c}}&{8'b0,shadow.color_min})|
            ({32{csr_address[7:2]==6'h0d}}&{8'b0,shadow.color_max})|
            ({32{csr_address[7:2]==6'h0e}}&{23'b0,shadow.alpha})|
            ({32{csr_address[7:2]==6'h13}}&{23'b0,shadow.st_hi,4'b0,shadow.st_lo})|
            ({32{csr_address[7:2]==6'h14}}&{11'b0,loaded_q,9'b0,loading_q})|
            ({32{csr_address[7:2]==6'h15}}&{22'b0,index_q})|
            ({32{csr_address[7:2]==6'h17}}&{generation_q,14'b0,loading_q,table_valid_q})|
            ({32{csr_address[7:2]==6'h18}}&shadow.frame_id)|
            ({32{csr_address[7:2]==6'h19}}&{5'b0,11'd1080,5'b0,11'(MAX_ROW_WIDTH<1920?MAX_ROW_WIDTH:1920)})|
            ({32{csr_address[7:2]==6'h1a}}&shadow.original_src)|
            ({32{csr_address[7:2]==6'h1b}}&{16'b0,shadow.original_stride})|
            ({32{csr_address[7:2]==6'h1c}}&{23'b0,shadow.ai_alpha})|
            ({32{csr_address[7:2]==6'h1d}}&{31'b0,shadow.ai_enable})|
            ({32{csr_address[7:2]==6'h20}}&cycles)|
            ({32{csr_address[7:2]==6'h21}}&input_pixels)|
            ({32{csr_address[7:2]==6'h22}}&output_pixels)|
            ({32{csr_address[7:2]==6'h23}}&read_beats)|
            ({32{csr_address[7:2]==6'h24}}&write_beats)|
            ({32{csr_address[7:2]==6'h25}}&input_stalls)|
            ({32{csr_address[7:2]==6'h26}}&output_stalls);
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            csr_ready<=0;csr_error<=0;shadow<='0;
            shadow.saturation<=256;shadow.saturation_out<=0;shadow.alpha<=256;shadow.ai_alpha<=256;
            shadow.color_max<=24'hffffff;table_valid_q<=0;loading_q<=0;dma_loading_q<=0;index_q<=0;loaded_q<=0;generation_q<=0;
            start<=0;abort<=0;irq_enable_q<=0;done_q<=0;last_error_q<=0;
            table_write<=0;table_address<=0;table_data<=0;table_dma_start<=0;
        end else begin
            start<=0;abort<=0;table_write<=0;table_dma_start<=0;csr_ready<=0;
            if(csr_valid&&!csr_ready)begin
                csr_ready<=1;
                csr_error<=!csr_write&&(csr_address[11:8]!=0||csr_address[1:0]!=0);
            end
            if(commit)begin
                csr_error<=0;
                if(csr_address[11:8]!=0||csr_address[1:0]!=0)csr_error<=1;
                else case(csr_address[7:2])
                    6'h02:if(csr_wstrb[0])begin
                        irq_enable_q<=csr_wdata[3];
                        if(csr_wdata[2])begin done_q<=0;last_error_q<=0;end
                        if(csr_wdata[1]&&(busy||dma_loading_q))abort<=1;
                        if(csr_wdata[0])begin
                            if(busy||!table_valid_q)csr_error<=1;
                            else begin start<=1;done_q<=0;last_error_q<=0;end
                        end
                    end
                    6'h05:for(int b=0;b<4;b++)if(csr_wstrb[b])shadow.dst[b*8+:8]<=csr_wdata[b*8+:8];
                    6'h07:if(checked_word[31:16]!=0)csr_error<=1;
                    else for(int b=0;b<2;b++)if(csr_wstrb[b])shadow.dst_stride[b*8+:8]<=csr_wdata[b*8+:8];
                    6'h08:if((checked_word&32'hf800f800)!=0)csr_error<=1;
                    else begin
                        if(csr_wstrb[0])shadow.width[7:0]<=csr_wdata[7:0];
                        if(csr_wstrb[1])shadow.width[10:8]<=csr_wdata[10:8];
                        if(csr_wstrb[2])shadow.height[7:0]<=csr_wdata[23:16];
                        if(csr_wstrb[3])shadow.height[10:8]<=csr_wdata[26:24];
                    end
                    6'h09:if((checked_word&32'hf800f800)!=0)csr_error<=1;
                    else begin
                        if(csr_wstrb[0])shadow.dst_width[7:0]<=csr_wdata[7:0];
                        if(csr_wstrb[1])shadow.dst_width[10:8]<=csr_wdata[10:8];
                        if(csr_wstrb[2])shadow.dst_height[7:0]<=csr_wdata[23:16];
                        if(csr_wstrb[3])shadow.dst_height[10:8]<=csr_wdata[26:24];
                    end
                    6'h0a:if((checked_word&32'hfffffdcf)!=0)csr_error<=1;
                    else begin
                        if(csr_wstrb[0])shadow.color<=color_mode_t'(csr_wdata[5:4]);
                        if(csr_wstrb[1])shadow.preserve<=csr_wdata[9];
                    end
                    6'h0b:if((checked_word&32'hfc00fc00)!=0)csr_error<=1;
                    else begin
                        if(csr_wstrb[0])shadow.saturation[7:0]<=csr_wdata[7:0];
                        if(csr_wstrb[1])shadow.saturation[9:8]<=csr_wdata[9:8];
                        if(csr_wstrb[2])shadow.saturation_out[7:0]<=csr_wdata[23:16];
                        if(csr_wstrb[3])shadow.saturation_out[9:8]<=csr_wdata[25:24];
                    end
                    6'h0c:for(int b=0;b<3;b++)if(csr_wstrb[b])shadow.color_min[b*8+:8]<=csr_wdata[b*8+:8];
                    6'h0d:for(int b=0;b<3;b++)if(csr_wstrb[b])shadow.color_max[b*8+:8]<=csr_wdata[b*8+:8];
                    6'h0e:if(checked_word[31:9]!=0)csr_error<=1;
                    else begin if(csr_wstrb[0])shadow.alpha[7:0]<=csr_wdata[7:0];if(csr_wstrb[1])shadow.alpha[8]<=csr_wdata[8];end
                    6'h13:if(checked_word[31:12]!=0||checked_word[7:4]!=0||checked_word[3:0]>8||checked_word[11:8]>8)csr_error<=1;
                    else begin if(csr_wstrb[0])shadow.st_lo<=csr_wdata[3:0];if(csr_wstrb[1])shadow.st_hi<=csr_wdata[11:8];end
                    6'h14:if(busy||dma_loading_q||csr_wstrb!=4'hf)csr_error<=1;
                    else if(csr_wdata[2])begin
                        if(loading_q||dma_loading_q||csr_wdata[31:3]!=0||csr_wdata[1:0]!=0||shadow.original_src[3:0]!=0||
                           shadow.original_src<32'h01000000||shadow.original_src>32'h01fffd00)csr_error<=1;
                        else begin
                            loading_q<=1;dma_loading_q<=1;index_q<=0;loaded_q<=0;table_valid_q<=0;
                            done_q<=0;last_error_q<=0;
                            table_dma_start<=1;
                        end
                    end else if(csr_wdata[0])begin
                        loading_q<=1;index_q<=0;loaded_q<=0;table_valid_q<=0;
                    end else if(csr_wdata[1])begin
                        if(!loading_q||loaded_q!=10'd768)csr_error<=1;
                        else begin loading_q<=0;table_valid_q<=1;generation_q<=generation_q+1'b1;end
                    end else csr_error<=1;
                    6'h15:csr_error<=1;
                    6'h16:if(busy||dma_loading_q||!loading_q||index_q!=loaded_q||loaded_q>=10'd768||!csr_wstrb[0])csr_error<=1;
                    else begin
                        table_write<=1;table_address<=index_q;table_data<=csr_wdata[7:0];
                        index_q<=index_q+1'b1;loaded_q<=loaded_q+1'b1;
                    end
                    6'h18:for(int b=0;b<4;b++)if(csr_wstrb[b])shadow.frame_id[b*8+:8]<=csr_wdata[b*8+:8];
                    6'h1a:for(int b=0;b<4;b++)if(csr_wstrb[b])shadow.original_src[b*8+:8]<=csr_wdata[b*8+:8];
                    6'h1b:if(checked_word[31:16]!=0)csr_error<=1;
                    else for(int b=0;b<2;b++)if(csr_wstrb[b])shadow.original_stride[b*8+:8]<=csr_wdata[b*8+:8];
                    6'h1c:if(checked_word[31:9]!=0)csr_error<=1;
                    else begin if(csr_wstrb[0])shadow.ai_alpha[7:0]<=csr_wdata[7:0];if(csr_wstrb[1])shadow.ai_alpha[8]<=csr_wdata[8];end
                    6'h1d:if(checked_word[31:1]!=0)csr_error<=1;else if(csr_wstrb[0])shadow.ai_enable<=csr_wdata[0];
                    default:csr_error<=1;
                endcase
            end
            if(table_byte_valid&&table_byte_ready)begin
                // DDR LUT assets store six-bit samples in the low bits; align
                // them to the common 8-bit CSR format consumed as [7:2] by
                // ipx_curve. Manual TABLE_DATA writes remain full 8-bit values.
                table_write<=1;table_address<=index_q;table_data<={table_byte_data[5:0],2'b00};
                index_q<=index_q+1'b1;loaded_q<=loaded_q+1'b1;
            end
            if(table_dma_error)begin loading_q<=0;dma_loading_q<=0;table_valid_q<=0;end
            else if(table_dma_finish)begin
                if(dma_loading_q&&loading_q&&({1'b0,loaded_q}+((table_byte_valid&&table_byte_ready)?11'd1:11'd0))==11'd768)begin
                    loading_q<=0;dma_loading_q<=0;table_valid_q<=1;generation_q<=generation_q+1'b1;
                end else begin loading_q<=0;dma_loading_q<=0;table_valid_q<=0;end
            end
            if(done_event&&!accepted_start)begin done_q<=1;last_error_q<=error_code;end
        end
    end
endmodule
