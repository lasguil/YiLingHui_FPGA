`timescale 1ns/1ps
module tb_mac_rx_arp_integration;
  reg clk=0, rst_n=0, rx_dv=0;
  reg [7:0] rx_data=0;
  always #5 clk=~clk;
  localparam [31:0] LOCAL_IP=32'hc0a80002;
  localparam [47:0] LOCAL_MAC=48'h000a3501fec0;
  reg [31:0] peer_ip=32'hc0a80003;
  wire arp_reply_req, arp_found, mac_not_exist;
  wire [31:0] src_ip;
  wire [47:0] src_mac, dest_mac;
  wire [7:0] udp_data, mac_dataout;
  wire [15:0] udp_len, upper_len, ip_len;
  wire udp_valid, icmp_req, icmp_error;
  reg [10:0] udp_addr=0;
  reg arp_reply_ack=0;
  reg [7:0] frame[0:71];
  integer found_count=0, reply_count=0;
  integer i;

  mac_rx_top rx(
    .clk(clk),.rst_n(rst_n),.rx_dv(rx_dv),.mac_rx_datain(rx_data),
    .local_ip_addr(LOCAL_IP),.local_mac_addr(LOCAL_MAC),
    .expected_peer_ip_addr(peer_ip),.arp_reply_ack(arp_reply_ack),
    .arp_reply_req(arp_reply_req),.arp_rec_source_ip_addr(src_ip),
    .arp_rec_source_mac_addr(src_mac),.udp_rec_ram_rdata(udp_data),
    .udp_rec_ram_read_addr(udp_addr),.udp_rec_data_length(udp_len),
    .udp_rec_data_valid(udp_valid),.mac_rx_dataout(mac_dataout),
    .upper_layer_data_length(upper_len),.ip_total_data_length(ip_len),
    .icmp_rx_req(icmp_req),.icmp_rev_error(icmp_error),.arp_found(arp_found)
  );
  arp_cache #(.CACHE_TIMEOUT_CYCLES(30'd3000)) cache(
    .clk(clk),.rst_n(rst_n),.arp_found(arp_found),
    .tx_in_progress(1'b0),
    .arp_rec_source_ip_addr(src_ip),.arp_rec_source_mac_addr(src_mac),
    .destination_ip_addr(peer_ip),.destination_mac_addr(dest_mac),
    .mac_not_exist(mac_not_exist)
  );
  always @(posedge clk) if(rst_n) begin
    if(arp_found) found_count<=found_count+1;
    if(arp_reply_req) reply_count<=reply_count+1;
  end

  function [31:0] eth_crc32(input integer count);
    integer n,b;
    reg [31:0] c;
    begin
      c=32'hffff_ffff;
      for(n=8;n<count;n=n+1) begin
        c=c^frame[n];
        for(b=0;b<8;b=b+1) c=(c>>1)^(c[0]?32'hedb88320:32'd0);
      end
      eth_crc32=~c;
    end
  endfunction

  task put_mac(input integer p,input [47:0] m);
    integer k; begin for(k=0;k<6;k=k+1) frame[p+k]=m[47-k*8 -:8]; end
  endtask
  task put_ip(input integer p,input [31:0] a);
    begin frame[p]=a[31:24]; frame[p+1]=a[23:16]; frame[p+2]=a[15:8]; frame[p+3]=a[7:0]; end
  endtask
  task make_arp(input [15:0] op,input [31:0] sip,input [47:0] smac,
                input [31:0] tip,input [47:0] tmac);
    reg [31:0] crc;
    integer k;
    begin
      for(k=0;k<72;k=k+1) frame[k]=0;
      for(k=0;k<7;k=k+1) frame[k]=8'h55;
      frame[7]=8'hd5;
      put_mac(8,48'hff_ff_ff_ff_ff_ff); put_mac(14,smac);
      frame[20]=8'h08; frame[21]=8'h06;
      frame[22]=0; frame[23]=1; frame[24]=8'h08; frame[25]=0;
      frame[26]=6; frame[27]=4; frame[28]=op[15:8]; frame[29]=op[7:0];
      put_mac(30,smac); put_ip(36,sip); put_mac(40,tmac); put_ip(46,tip);
      // Pad the 14-byte Ethernet header + 46-byte ARP payload to 60 bytes.
      crc=eth_crc32(68);
      frame[68]=crc[7:0]; frame[69]=crc[15:8]; frame[70]=crc[23:16]; frame[71]=crc[31:24];
    end
  endtask
  task send_frame;
    integer k; begin
      @(negedge clk); rx_dv=1;
      for(k=0;k<72;k=k+1) begin rx_data=frame[k]; @(negedge clk); end
      rx_dv=0; rx_data=0; repeat(120) @(negedge clk);
    end
  endtask

  initial begin
    repeat(4) @(negedge clk); rst_n=1; repeat(3) @(negedge clk);
    if(!mac_not_exist || dest_mac!==48'hff_ff_ff_ff_ff_ff) $fatal(1,"initial cache not invalid");
    make_arp(16'h0001,32'hc0a80003,48'h280c50a00d11,LOCAL_IP,48'd0);
    send_frame(); repeat(3) @(negedge clk);
    if(found_count!=1 || reply_count==0) $fatal(1,"real Ethernet ARP request not parsed: found=%0d reply=%0d",found_count,reply_count);
    if(src_ip!==peer_ip || src_mac!==48'h280c50a00d11) $fatal(1,"MAC RX header/parser byte alignment wrong src=%h mac=%h",src_ip,src_mac);
    if(mac_not_exist || dest_mac!==48'h280c50a00d11) $fatal(1,"cache did not learn MAC RX parsed source");

    // An addressed reply must refresh the same peer mapping through the same byte-level path.
    make_arp(16'h0002,32'hc0a80003,48'h281122334466,LOCAL_IP,LOCAL_MAC);
    send_frame(); repeat(3) @(negedge clk);
    if(found_count!=2 || dest_mac!==48'h281122334466) $fatal(1,"real Ethernet reply failed cache refresh");
    $display("PASS: MAC RX preamble/header/ARP byte timing, source-MAC association, request/reply cache learning");
    $finish;
  end
endmodule
