// Passive ISP-green observer: exact 8x8 means, quantised after averaging.
// Eight rotating column sums, six-cycle division; no frame RAM or DSP.
module wave_roi_stats #(parameter W0=1920,H0=1080,W1=1280,H1=720,W2=854,H2=480)(
    input wire clk,rst_n,enable,in_vs,in_de,input wire [7:0] in_green,
    input wire [1:0] mode,output reg frame_start,block_valid,
    output reg [5:0] block_index,block_mean
);
    reg p_vs,p_de,vs_d,opened;
    reg [7:0] p_green;
    reg [10:0] x,frame_width,crop_width;
    reg [7:0] cell_x,cell_y,cell_width,cell_height;
    reg [2:0] column;
    reg [3:0] row;
    reg [17:0] denominator;
    reg [22:0] accumulator;
    wire [22:0] previous_row;
    wire take=enable&&opened&&p_de&&x<crop_width&&row<8;
    wire last_column_pixel=cell_x==cell_width-1'b1;
    wire last_block_row=cell_y==cell_height-1'b1;
    wire [22:0] base=cell_x!=0?accumulator:cell_y==0?23'd0:previous_row;
    wire [22:0] added=base+{15'd0,p_green};
    genvar b;
    generate for(b=0;b<23;b=b+1)begin: column_sums
        EFX_SRL8 #(.INIT(8'hff)) sum_chain(.D(~added[b]),.A(3'd0),.CLK(clk),
            .CE(take&&last_column_pixel),.Q(previous_row[b]),.Q7());
    end endgenerate
    reg divide_busy;
    reg [22:0] remainder,divisor;
    reg [5:0] quotient,tag;
    reg [2:0] bit_index;
    wire subtract=remainder>=divisor;
    // floor(sum/(4*pixels)) == floor(mean(green8)) >> 2.
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            p_vs<=0;p_de<=0;p_green<=0;vs_d<=0;opened<=0;
            x<=0;frame_width<=W0;crop_width<=(W0/8)*8;
            cell_x<=0;cell_y<=0;cell_width<=W0/8;cell_height<=H0/8;
            column<=0;row<=0;denominator<=4*(W0/8)*(H0/8);accumulator<=0;
            frame_start<=0;block_valid<=0;block_index<=0;block_mean<=0;
            divide_busy<=0;remainder<=0;divisor<=0;quotient<=0;tag<=0;bit_index<=0;
        end else begin
            p_vs<=in_vs;p_de<=in_de;p_green<=in_green;vs_d<=p_vs;
            frame_start<=0;block_valid<=0;
            if(!enable)begin
                opened<=0;divide_busy<=0;x<=0;cell_x<=0;cell_y<=0;column<=0;row<=0;
            end else if(p_vs&&!vs_d)begin
                frame_start<=1;opened<=1;divide_busy<=0;
                x<=0;cell_x<=0;cell_y<=0;column<=0;row<=0;accumulator<=0;
                case(mode)
                    1:begin frame_width<=W1;crop_width<=(W1/8)*8;cell_width<=W1/8;cell_height<=H1/8;denominator<=4*(W1/8)*(H1/8);end
                    2:begin frame_width<=W2;crop_width<=(W2/8)*8;cell_width<=W2/8;cell_height<=H2/8;denominator<=4*(W2/8)*(H2/8);end
                    default:begin frame_width<=W0;crop_width<=(W0/8)*8;cell_width<=W0/8;cell_height<=H0/8;denominator<=4*(W0/8)*(H0/8);end
                endcase
            end else begin
                if(divide_busy)begin
                    if(subtract)remainder<=remainder-divisor;
                    quotient[bit_index]<=subtract;divisor<=divisor>>1;
                    if(bit_index==0)begin
                        divide_busy<=0;block_valid<=1;block_index<=tag;
                        block_mean<={quotient[5:1],subtract};
                    end else bit_index<=bit_index-1'b1;
                end
                if(take)begin
                    accumulator<=added;
                    if(last_column_pixel)begin
                        cell_x<=0;column<=column+1'b1;
                        if(last_block_row)begin
                            remainder<=added;divisor<={denominator,5'd0};
                            quotient<=0;bit_index<=5;tag<={row[2:0],column};divide_busy<=1;
                        end
                    end else cell_x<=cell_x+1'b1;
                end
                if(opened&&p_de)begin
                    if(x==frame_width-1'b1)begin
                        x<=0;cell_x<=0;column<=0;
                        if(last_block_row)begin
                            cell_y<=0;row<=row+1'b1;if(row==7)opened<=0;
                        end else cell_y<=cell_y+1'b1;
                    end else x<=x+1'b1;
                end
            end
        end
    end
endmodule
