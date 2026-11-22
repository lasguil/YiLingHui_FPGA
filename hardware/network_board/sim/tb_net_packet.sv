`timescale 1ns/1ps
module tb_net_packet;
    reg clk=0;always #20 clk=~clk;
    reg rst_n=0;
    wire [7:0] data;wire wr,req,busy;
    wire [15:0] len,port,addr;
    wire [31:0] frames,packets,drops;
    wire [15:0] width,height;
    reg [1:0] source=0;
    reg available=1,cap_busy=0,cap_error=0,check_payload=1;
    wire pop,begin_frame,end_frame,using_capture;
    integer cycles=0,pixel_index=0,packet_index=0,byte_index=0,total_pixels=0;
    reg [7:0] bytes[0:255];
    integer payload_file;
    initial payload_file=$fopen("build/net_packet_payloads.hex","w");
    wire pixel_valid=cap_busy && (cycles%7!=0);
    wire [15:0] pixel=16'ha500+16'(pixel_index);
    vid_packet #(.W(7),.H(5),.FPS(100),.CLK_HZ(1000000),.PKT_MAX(16)) dut(
      .clk,.rst_n,.tx_data(data),.tx_wr(wr),.tx_len(len),.tx_req(req),.tx_port(port),.tx_busy(busy),
      .tx_ram_req(req),.mac_send_end(!wr && busy && !req),.cfg_stream_en(1'b1),.cfg_test_src(source),
      .frame_cnt(frames),.pkt_cnt(packets),.drop_cnt(drops),.cur_w(width),.cur_h(height),
      .cap_addr(addr),.cap_data(pixel),.cap_valid(available),.cap_present(available),.cap_rd_begin(begin_frame),
      .cap_rd_end(end_frame),.cap_using(using_capture),.cap_data_valid(pixel_valid),.cap_pop(pop),
      .cap_error(cap_error),.cap_busy(cap_busy));
    always @(posedge clk)begin
        cycles<=cycles+1;
        if(begin_frame)cap_busy<=1;
        if(pop)begin pixel_index<=pixel_index+1;total_pixels<=total_pixels+1;end
        if(end_frame)cap_busy<=0;
    end
    always @(negedge clk)if(rst_n && wr && check_payload)begin
        integer n,offset,expected_len;reg [15:0] expected_pixel;
        bytes[byte_index]=data;
        byte_index=byte_index+1;
        if(byte_index==len)begin
            offset=packet_index*16;
            expected_len=packet_index==4 ? 26:36;
            if(len!=expected_len || bytes[0]!=8'h56 || bytes[1]!=8'h49 || bytes[2]!=1)
                $fatal(1,"VI header/length mismatch");
            if(bytes[3]!=(packet_index==0 ? 1:packet_index==4 ? 2:0))$fatal(1,"SOF/EOF flags");
            if({bytes[8],bytes[9]}!=packet_index || {bytes[10],bytes[11]}!=5 ||
               {bytes[12],bytes[13],bytes[14],bytes[15]}!=offset)$fatal(1,"VI offsets/counts");
            for(n=20;n<len;n=n+2)begin
                expected_pixel=16'ha500+16'((offset+n-20)/2);
                if({bytes[n+1],bytes[n]}!==expected_pixel)$fatal(1,"DDR source mismatch packet %0d byte %0d",packet_index,n);
            end
            for(n=0;n<len;n=n+1)$fwrite(payload_file,"%02x",bytes[n]);
            $fwrite(payload_file,"\n");
            packet_index=packet_index+1;byte_index=0;
            // Source controls change during transmission: the current frame must stay atomic.
            if(packet_index==2)begin source=1;available=0;end
        end
    end
    initial begin
        repeat(8)@(negedge clk);rst_n=1;
        wait(frames==1);@(negedge clk);
        if(packet_index!=5||total_pixels!=35||drops!=0)$fatal(1,"frame accounting mismatch");
        check_payload=0;source=0;available=1;
        wait(begin_frame);wait(pixel_index>=39);@(negedge clk);cap_error=1;
        wait(end_frame);repeat(10)@(negedge clk);
        if(drops!=1 || cap_busy || frames!=1 || dut.st!=0)$fatal(1,"failed frame was not aborted/released");
        $fclose(payload_file);
        $display("PASS: VI headers, RGB565 byte order, backpressure, frame source latch, final partial packet, AXI-error frame abort");
        $finish;
    end
    initial begin #10_000_000;$fatal(1,"packet timeout");end
endmodule
