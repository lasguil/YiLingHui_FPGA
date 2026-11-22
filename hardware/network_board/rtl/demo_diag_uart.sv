// Temporary bring-up transport. Independent of the CPU and DDR clock/reset.
// 115200/8N1: "DDR " + 16 hex digits + CRLF, one sampled word per interval.
module demo_diag_uart #(
    parameter integer BIT_CLOCKS=1302, // 150MHz / 115200
    parameter integer PERIOD_BITS=25
)(
    input wire clk,rst_n,
    input wire [63:0] status_async,
    output reg tx
);
    (* async_reg="true" *) reg [63:0] status_meta,status_sync;
    reg [63:0] snapshot;
    reg [PERIOD_BITS-1:0] interval;
    reg [10:0] bit_timer;
    reg [9:0] shift;
    reg [3:0] bits_left;
    reg [4:0] char_index;
    reg sending;
    reg [7:0] character;
    wire [3:0] nibble=snapshot[63:60];
    always @* begin
        case(char_index)
            0:character="D";
            1:character="D";
            2:character="R";
            3:character=" ";
            20:character=8'h0d;
            21:character=8'h0a;
            default:character=nibble<10 ? (8'h30+{4'd0,nibble}) : (8'h37+{4'd0,nibble});
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            status_meta<=0;status_sync<=0;snapshot<=0;interval<=0;
            bit_timer<=0;shift<=10'h3ff;bits_left<=0;char_index<=0;
            sending<=0;tx<=1;
        end else begin
            status_meta<=status_async;status_sync<=status_meta;
            interval<=interval+1'b1;
            if(!sending && (&interval)) begin
                snapshot<=status_sync;char_index<=0;sending<=1;
            end
            if(bits_left!=0) begin
                if(bit_timer==0) begin
                    bit_timer<=BIT_CLOCKS-1;
                    if(bits_left==1) begin bits_left<=0;tx<=1;end
                    else begin
                        tx<=shift[1];shift<={1'b1,shift[9:1]};
                        bits_left<=bits_left-1'b1;
                    end
                end else bit_timer<=bit_timer-1'b1;
            end else if(sending) begin
                shift<={1'b1,character,1'b0};tx<=0;
                bits_left<=10;bit_timer<=BIT_CLOCKS-1;
                if(char_index>=4 && char_index<20)snapshot<={snapshot[59:0],4'd0};
                if(char_index==21)sending<=0;
                else char_index<=char_index+1'b1;
            end
        end
    end
endmodule
