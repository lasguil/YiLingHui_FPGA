`timescale 1ns/1ps
module tb_jpeg_vid_packet;
    parameter GAP=0;
    integer cycles=0,first_submit=-1;
    reg observed_idle_wait=0;
    reg clk=0, rst_n=0;
    always #20 clk=~clk;

    localparam integer JPEG_LEN=1455;
    reg [7:0] jpeg [0:JPEG_LEN-1];
    integer src_idx=0;
    wire [15:0] cap_data={7'd0,(src_idx==JPEG_LEN-1),jpeg[src_idx]};
    wire cap_data_valid=(src_idx<JPEG_LEN);
    wire cap_pop;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)src_idx<=0;
        else if(cap_pop)src_idx<=src_idx+1;

    wire [7:0] tx_data;
    wire tx_wr,tx_req;
    wire [15:0] tx_len;
    wire [15:0] tx_port;
    wire tx_busy;
    wire [31:0] frame_cnt,pkt_cnt,drop_cnt;
    wire [15:0] cur_w,cur_h,cap_addr;
    wire cap_rd_begin,cap_rd_end,cap_using;
    reg tx_req_d=0, mac_send_end=0;
    wire tx_ram_req=tx_req;
    reg [7:0] captured [0:2047];
    integer byte_count=0, packets=0, packet_base[0:1], packet_size[0:1];
    integer cur_packet=0;

    vid_packet #(.JPEG_MODE(1),.PACKET_PACING(1),.W(16'd1280),.H(16'd720),.FPS(8'd255),
                 .PKT_MAX(16'd1452),.CLK_HZ(27'd25500),.WAIT_FRESH(1)) dut(
        .clk(clk),.rst_n(rst_n),.tx_data(tx_data),.tx_wr(tx_wr),.tx_len(tx_len),
        .tx_req(tx_req),.tx_port(tx_port),.tx_busy(tx_busy),.tx_ram_req(tx_ram_req),
        .mac_send_end(mac_send_end),.cfg_stream_en(1'b1),.cfg_packet_gap(16'(GAP)),.cfg_test_src(2'd0),
        .frame_cnt(frame_cnt),.pkt_cnt(pkt_cnt),.drop_cnt(drop_cnt),
        .cur_w(cur_w),.cur_h(cur_h),.cap_addr(cap_addr),.cap_data(cap_data),
        .cap_data_valid(cap_data_valid),.cap_last(cap_data[8]),.cap_error(1'b0),
        .cap_busy(1'b0),.cap_pop(cap_pop),.cap_valid(1'b1),.cap_present(1'b1),
        .cap_rd_begin(cap_rd_begin),.cap_rd_end(cap_rd_end),.cap_using(cap_using));

    always @(posedge clk) begin
        cycles<=cycles+1;
        if(rst_n&&GAP>0&&dut.paced_admission.remaining_cycles!=0&&dut.packet_ready&&dut.ts==0)begin
            if(tx_req||tx_busy||dut.watchdog!=0)$fatal(1,"spacing claims or times out MAC ownership");
            observed_idle_wait<=1;
        end
        mac_send_end <= 1'b0;
        tx_req_d <= tx_req;
        if(tx_req && !tx_req_d) begin
            if(first_submit<0)first_submit=cycles;
            else if(cycles-first_submit<GAP)$fatal(1,"packet admitted before configured interval");
            if(packets>1)$fatal(1,"unexpected extra packet");
            packet_base[packets]=byte_count;
            packet_size[packets]=tx_len;
            cur_packet=packets;
            packets=packets+1;
        end
        if(tx_wr) begin
            captured[byte_count]=tx_data;
            byte_count=byte_count+1;
            if(byte_count-packet_base[cur_packet]==packet_size[cur_packet])
                mac_send_end <= 1'b1;
        end
    end

    integer i;
    initial begin
        for(i=0;i<JPEG_LEN;i=i+1)jpeg[i]=i[7:0];
        jpeg[0]=8'hff;jpeg[1]=8'hd8;
        jpeg[JPEG_LEN-2]=8'hff;jpeg[JPEG_LEN-1]=8'hd9;
        repeat(8)@(posedge clk);rst_n=1;
        wait(frame_cnt==1);
        if(packets!=2 || byte_count!=1495)$fatal(1,"packet count/length %0d/%0d",packets,byte_count);
        if(GAP>2000&&!observed_idle_wait)$fatal(1,"did not exercise free-MAC spacing wait");
        if(packet_size[0]!=1472 || packet_size[1]!=23)$fatal(1,"packet sizes %0d/%0d",packet_size[0],packet_size[1]);
        if(captured[2]!=8'd2 || captured[3]!=8'h01)$fatal(1,"first JPEG header version/flags %02x/%02x",captured[2],captured[3]);
        if(captured[10]!=8'hff || captured[11]!=8'hff)$fatal(1,"JPEG packet total sentinel missing");
        if(captured[12]!=0 || captured[13]!=0 || captured[14]!=0 || captured[15]!=0)$fatal(1,"first byte offset wrong");
        if(captured[packet_base[1]+2]!=8'd2 || captured[packet_base[1]+3]!=8'h02)$fatal(1,"last JPEG header version/flags wrong");
        if(captured[packet_base[1]+8]!=0 || captured[packet_base[1]+9]!=1)$fatal(1,"last packet index wrong");
        if(captured[packet_base[1]+12]!=0 || captured[packet_base[1]+13]!=0 ||
           captured[packet_base[1]+14]!=8'h05 || captured[packet_base[1]+15]!=8'hac)
            $fatal(1,"last packet byte offset wrong");
        if(captured[20]!=8'hff || captured[21]!=8'hd8 ||
           captured[packet_base[1]+20]!=jpeg[JPEG_LEN-3] ||
           captured[packet_base[1]+22]!=8'hd9)$fatal(1,"JPEG payload bytes corrupted");
        for(i=0;i<JPEG_LEN;i=i+1)
            if(captured[i<1452?20+i:packet_base[1]+20+i-1452]!==jpeg[i])$fatal(1,"JPEG byte %0d changed",i);
        $display("PASS: spacing GAP=%0d cycles preserves all JPEG bytes and leaves MAC unclaimed while waiting",GAP);
        $display("PASS: JPEG v2 frame split into 1452+3 bytes; SOF/EOF, offsets, sentinel, payload preserved");
        $finish;
    end
    initial begin #100000000; $fatal(1,"timeout"); end
endmodule
