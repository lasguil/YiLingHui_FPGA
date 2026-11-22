// RGB565/VI packet producer and independent MAC submitter.
// One synchronous packet RAM is reused only after the last byte was copied to
// MAC RAM. Preparing the next packet overlaps the previous MAC/PHY transmission.
// Metadata stays owned by the arbiter until qualified internal MAC completion.
`timescale 1ns/1ps
module vid_packet #(
    parameter [15:0] W=16'd320,H=16'd240,
    parameter [7:0] FPS=8'd30,
    parameter [15:0] PKT_MAX=16'd1452,PORT=16'd5001,
    parameter [26:0] CLK_HZ=27'd25_000_000,
    parameter WAIT_FRESH=0,
    parameter JPEG_MODE=0,
    parameter CHECK_PEER=0,
    parameter PACKET_PACING=0
)(
    input wire clk,rst_n,
    output reg [7:0] tx_data,
    output reg tx_wr,
    output reg [15:0] tx_len,
    output reg tx_req,
    output wire [15:0] tx_port,
    output wire tx_busy,
    input wire tx_ram_req,mac_send_end,
    input wire cfg_stream_en,
    input wire peer_ready,
    input wire [15:0] cfg_packet_gap,
    input wire [1:0] cfg_test_src,
    output reg [31:0] frame_cnt,pkt_cnt,drop_cnt,
    output wire [15:0] cur_w,cur_h,cap_addr,
    input wire [15:0] cap_data,
    input wire cap_data_valid,cap_last,cap_error,cap_busy,
    output wire cap_pop,
    input wire cap_valid,cap_present,
    output reg cap_rd_begin,cap_rd_end,
    output wire cap_using
);
    localparam [31:0] FRAME_BYTES=32'(W)*32'(H)*2;
    localparam [15:0] PKT_TOTAL=16'((FRAME_BYTES+PKT_MAX-1)/PKT_MAX);
    localparam [31:0] FRAME_CYC=CLK_HZ/FPS;
    localparam S_IDLE=0,S_HDR=1,S_FILL=2,S_READY=3,S_NEXT=4,S_FINISH=5,
               S_JPEG_HDR=6,S_ABORT=7;
    localparam T_IDLE=0,T_REQ=1,T_COPY=2,T_DRAIN=3,T_FAILED=4;
    reg [2:0] st,ts;
    reg [31:0] pace,sent_bytes,fid,ts_us;
    reg [15:0] pix_idx,pkt_idx,x,y,bx,by,pixel_hold,packet_len,tx_cnt,jpeg_payload_len;
    reg [31:0] pix_lin;
    reg [4:0] hcnt;
    reg [6:0] us_div;
    reg phase,cap_use,packet_ready,copy_done,tx_failed,jpeg_last_packet;
    reg [15:0] watchdog;
    wire [31:0] remain=FRAME_BYTES-sent_bytes;
    wire [31:0] capacity=remain<PKT_MAX?remain:PKT_MAX;
    wire tx_idle=ts==T_IDLE;
    wire arp_wait=CHECK_PEER&&ts==T_REQ&&!peer_ready;
    wire packet_admission_ready;
    generate if(PACKET_PACING)begin : paced_admission
        reg [15:0] remaining_cycles;
        always @(posedge clk or negedge rst_n)
            if(!rst_n)remaining_cycles<=0;
            else if(ts==T_REQ&&tx_ram_req)remaining_cycles<=cfg_packet_gap;
            else if(remaining_cycles!=0)remaining_cycles<=remaining_cycles-1'b1;
        assign packet_admission_ready=remaining_cycles==0;
    end else begin : unpaced_admission
        assign packet_admission_ready=1'b1;
    end endgenerate
    wire can_start=JPEG_MODE ? (!cap_busy&&!cap_error) : (!WAIT_FRESH || cfg_test_src!=0 || !cap_present || (cap_valid&&!cap_busy));
    wire [15:0] barcol=x<W/8 ? 16'hffff:x<W/8*2?16'hffe0:x<W/8*3?16'h07ff:
        x<W/8*4?16'h07e0:x<W/8*5?16'hf81f:x<W/8*6?16'hf800:x<W/8*7?16'h001f:16'h0000;
    wire in_box=x>=bx&&x<bx+32&&y>=by&&y<by+32;
    wire [15:0] src_pixel=cap_use?cap_data:(in_box?16'hffff:barcol);
    assign tx_port=PORT;
    assign tx_busy=ts!=T_IDLE;
    assign cur_w=W;assign cur_h=H;
    assign cap_using=cap_use;
    assign cap_addr=pix_lin[15:0]; // retained legacy port; DDR consumes cap_pop
    assign cap_pop=cap_use&&cap_data_valid&&
        (JPEG_MODE ? ((st==S_FILL&&pix_idx<PKT_MAX)||st==S_ABORT)
                   : ((st==S_FILL&&!phase&&pix_idx*2<capacity)||st==S_ABORT));

    (* syn_ramstyle="block_ram" *) reg [7:0] pktbuf[0:2047];
    reg we;
    reg [10:0] wa,ra_q;
    reg [7:0] wd;
    wire [10:0] ra=ts==T_COPY?11'(tx_cnt+1'b1):11'd0;
    wire [7:0] q=pktbuf[ra_q];
    always @(posedge clk) begin
        if(we)pktbuf[wa]<=wd;
        ra_q<=ra;
    end
    always @* begin
        we=0;wa=0;wd=0;
        if(((st==S_HDR&&!JPEG_MODE)||st==S_JPEG_HDR) && !(cap_use&&cap_error))begin
            we=1;wa={6'd0,hcnt};
            case(hcnt)
                0:wd=8'h56;1:wd=8'h49;2:wd=JPEG_MODE?8'd2:8'd1;
                3:wd={6'd0,(JPEG_MODE?jpeg_last_packet:pkt_idx==PKT_TOTAL-1),pkt_idx==0};
                4:wd=fid[31:24];5:wd=fid[23:16];6:wd=fid[15:8];7:wd=fid[7:0];
                8:wd=pkt_idx[15:8];9:wd=pkt_idx[7:0];
                10:wd=JPEG_MODE?8'hff:PKT_TOTAL[15:8];11:wd=JPEG_MODE?8'hff:PKT_TOTAL[7:0];
                12:wd=sent_bytes[31:24];13:wd=sent_bytes[23:16];14:wd=sent_bytes[15:8];15:wd=sent_bytes[7:0];
                16:wd=ts_us[31:24];17:wd=ts_us[23:16];18:wd=ts_us[15:8];19:wd=ts_us[7:0];
                default:wd=0;
            endcase
        end else if(JPEG_MODE && st==S_FILL && cap_data_valid && pix_idx<PKT_MAX && !(cap_use&&cap_error))begin
            we=1;wa=11'(20+pix_idx);wd=cap_data[7:0];
        end else if(st==S_FILL && pix_idx*2<capacity && !(cap_use&&cap_error))begin
            we=!JPEG_MODE&&(phase||!cap_use||cap_data_valid);
            wa=11'(20+pix_idx*2+phase);
            wd=phase?pixel_hold[15:8]:src_pixel[7:0];
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin us_div<=0;ts_us<=0;end
        else if(us_div==CLK_HZ/1_000_000-1)begin us_div<=0;ts_us<=ts_us+1'b1;end
        else us_div<=us_div+1'b1;
    end
    // Saturate deadlines: an overrun never silently divides the configured fps.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)pace<=0;
        else if(!cfg_stream_en || (st==S_IDLE&&pace>=FRAME_CYC&&can_start))pace<=0;
        else if(pace<FRAME_CYC)pace<=pace+1'b1;
    end
    // MAC-side transaction. No timeout is part of normal pacing.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            ts<=T_IDLE;tx_data<=0;tx_wr<=0;tx_len<=0;tx_req<=0;
            tx_cnt<=0;copy_done<=0;watchdog<=0;tx_failed<=0;
        end else begin
            tx_wr<=0;copy_done<=0;
            // Waiting for route discovery is not a failed MAC transaction.
            // Also covers expiry between packet preparation and arbitration.
            if(ts==T_IDLE||arp_wait)watchdog<=0;
            else if(watchdog!=16'hffff)watchdog<=watchdog+1'b1;
            case(ts)
                // Wait before claiming any MAC metadata; control packets and
                // ARP remain free to use the sender during video spacing.
                T_IDLE:if(packet_ready&&packet_admission_ready)begin tx_len<=packet_len;tx_req<=1;ts<=T_REQ;end
                T_REQ:if(tx_ram_req)begin tx_req<=0;tx_cnt<=0;ts<=T_COPY;end
                T_COPY:begin
                    tx_wr<=1;tx_data<=q;
                    if(tx_cnt==tx_len-1)begin copy_done<=1;ts<=T_DRAIN;end
                    else tx_cnt<=tx_cnt+1'b1;
                end
                T_DRAIN:if(mac_send_end)ts<=T_IDLE;
                default:begin tx_req<=0;end
            endcase
            // Never cut off an accepted continuous RAM write on watchdog expiry.
            if(watchdog==16'hfffe && ts!=T_COPY&&!arp_wait)begin ts<=T_FAILED;tx_req<=0;tx_failed<=1;end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            st<=S_IDLE;cap_use<=0;pix_idx<=0;pkt_idx<=0;sent_bytes<=0;fid<=0;
            x<=0;y<=0;bx<=0;by<=0;phase<=0;hcnt<=0;pix_lin<=0;pixel_hold<=0;
            packet_len<=0;packet_ready<=0;cap_rd_begin<=0;cap_rd_end<=0;
            jpeg_payload_len<=0;jpeg_last_packet<=0;
            frame_cnt<=0;pkt_cnt<=0;drop_cnt<=0;
        end else begin
            cap_rd_begin<=0;cap_rd_end<=0;
            if((cap_use&&cap_error&&(st==S_HDR||st==S_FILL||st==S_JPEG_HDR||st==S_NEXT)) ||
               (tx_failed && st!=S_IDLE && st!=S_ABORT))begin
                cap_rd_end<=cap_use;packet_ready<=0;phase<=0;
                fid<=fid+1'b1;drop_cnt<=drop_cnt+1'b1;st<=S_ABORT;
            end else case(st)
                // A reset can leave an active producer with orphaned JPEG bytes.
                // Drain that failed epoch without issuing another encoder start.
                S_IDLE:if(JPEG_MODE&&cap_error)begin
                    cap_use<=1'b1;packet_ready<=0;st<=S_ABORT;
                end else if(cfg_stream_en&&pace>=FRAME_CYC&&can_start&&!tx_failed)begin
                    sent_bytes<=0;pix_idx<=0;pkt_idx<=0;x<=0;y<=0;hcnt<=0;pix_lin<=0;
                    cap_use<=JPEG_MODE || (cfg_test_src==0&&cap_valid&&!cap_busy);
                    cap_rd_begin<=JPEG_MODE || (cfg_test_src==0&&cap_valid&&!cap_busy);
                    jpeg_payload_len<=0;jpeg_last_packet<=0;
                    st<=JPEG_MODE?S_FILL:S_HDR;
                end
                S_HDR:if(!JPEG_MODE && hcnt==19)begin hcnt<=0;pix_idx<=0;st<=S_FILL;end else hcnt<=hcnt+1'b1;
                S_FILL:if(JPEG_MODE)begin
                    if(cap_data_valid && pix_idx<PKT_MAX)begin
                        pix_idx<=pix_idx+1'b1;
                        if(cap_last || pix_idx==PKT_MAX-1)begin
                            jpeg_payload_len<=pix_idx+1'b1;
                            jpeg_last_packet<=cap_last;
                            hcnt<=0;st<=S_JPEG_HDR;
                        end
                    end
                end else if(pix_idx*2>=capacity)begin
                    packet_len<=16'(20+pix_idx*2);packet_ready<=1;st<=S_READY;
                end else if(!phase&&(!cap_use||cap_data_valid))begin pixel_hold<=src_pixel;phase<=1;end
                else if(phase)begin
                    phase<=0;pix_idx<=pix_idx+1'b1;pix_lin<=pix_lin+1'b1;
                    if(x==W-1)begin x<=0;y<=y==H-1?16'd0:y+1'b1;end else x<=x+1'b1;
                end
                S_JPEG_HDR:if(hcnt==19)begin
                    hcnt<=0;packet_len<=20+jpeg_payload_len;packet_ready<=1;st<=S_READY;
                end else hcnt<=hcnt+1'b1;
                S_READY:if(copy_done)begin
                    packet_ready<=0;sent_bytes<=sent_bytes+packet_len-20;pkt_cnt<=pkt_cnt+1'b1;
                    if(JPEG_MODE)begin
                        if(jpeg_last_packet)begin cap_rd_end<=cap_use;st<=S_FINISH;end
                        else begin pkt_idx<=pkt_idx+1'b1;pix_idx<=0;jpeg_payload_len<=0;
                            jpeg_last_packet<=0;st<=S_FILL;end
                    end else st<=S_NEXT;
                end
                S_NEXT:if(!JPEG_MODE && sent_bytes>=FRAME_BYTES)begin cap_rd_end<=cap_use;st<=S_FINISH;end
                else begin pkt_idx<=pkt_idx+1'b1;pix_idx<=0;hcnt<=0;st<=S_HDR;end
                S_FINISH:if(tx_idle)begin
                    fid<=fid+1'b1;frame_cnt<=frame_cnt+1'b1;st<=S_IDLE;
                    bx <= (bx + 16'd3 >= W - 16'd32) ? 16'd0 : bx + 16'd3;
                    by <= (by + 16'd2 >= H - 16'd32) ? 16'd0 : by + 16'd2;
                end
                // FWFT empty can briefly assert between prefetched bytes.
                // JPEG cap_error clears only after the producer confirms the
                // whole failed frame has drained, so do not exit on a bubble.
                S_ABORT:if(!cap_busy&&!cap_data_valid&&(!JPEG_MODE||!cap_error)&&(tx_idle||tx_failed))begin cap_use<=0;st<=S_IDLE;end
                default:st<=S_IDLE;
            endcase
        end
    end
endmodule
