`timescale 1ns/1ps
module tb_arp_cache_refresh;
  reg clk=0, rst_n=0;
  always #5 clk=~clk;
  reg arp_rx_req=0, arp_reply_ack=0;
  reg [7:0] arp_rx_data=0;
  reg [31:0] destination_ip=32'hc0a80003;
  reg [47:0] ethernet_mac=48'h280c50a00d11;
  reg tx_active=0;
  wire arp_rx_end, arp_reply_req, arp_found;
  wire [31:0] src_ip;
  wire [47:0] src_mac, dest_mac;
  wire mac_not_exist;
  localparam [31:0] LOCAL_IP=32'hc0a80002;
  localparam [47:0] LOCAL_MAC=48'h000a3501fec0;
  integer i;
  reg [7:0] frame[0:45];
  integer saw_found=0;
  always @(posedge clk) if(rst_n && arp_found) saw_found=1;

  arp_rx dut_rx(.clk(clk),.rst_n(rst_n),.local_ip_addr(LOCAL_IP),
    .local_mac_addr(LOCAL_MAC),.expected_peer_ip_addr(destination_ip),
    .ethernet_source_mac_addr(ethernet_mac),.arp_rx_data(arp_rx_data),
    .arp_rx_req(arp_rx_req),.arp_rx_end(arp_rx_end),.arp_reply_ack(arp_reply_ack),
    .arp_reply_req(arp_reply_req),.arp_rec_source_ip_addr(src_ip),
    .arp_rec_source_mac_addr(src_mac),.arp_found(arp_found));
  arp_cache #(.CACHE_TIMEOUT_CYCLES(30'd2000)) dut_cache(
    .clk(clk),.rst_n(rst_n),.arp_found(arp_found),
    .tx_in_progress(tx_active),
    .arp_rec_source_ip_addr(src_ip),.arp_rec_source_mac_addr(src_mac),
    .destination_ip_addr(destination_ip),.destination_mac_addr(dest_mac),
    .mac_not_exist(mac_not_exist));

  task automatic build_frame(input [15:0] op,input [31:0] sip,
                             input [47:0] smac,input [31:0] tip,
                             input [47:0] tmac,input bit valid_format);
    begin
      for (integer j=0;j<46;j=j+1) frame[j]=0;
      frame[0]=valid_format?8'h00:8'h01; frame[1]=8'h01;
      frame[2]=8'h08; frame[3]=8'h00; frame[4]=8'h06; frame[5]=8'h04;
      frame[6]=op[15:8]; frame[7]=op[7:0];
      for(integer j=0;j<6;j=j+1) frame[8+j]=smac[47-j*8 -: 8];
      for(integer j=0;j<4;j=j+1) frame[14+j]=sip[31-j*8 -: 8];
      for(integer j=0;j<6;j=j+1) frame[18+j]=tmac[47-j*8 -: 8];
      for(integer j=0;j<4;j=j+1) frame[24+j]=tip[31-j*8 -: 8];
    end
  endtask

  task automatic send_arp;
    begin
      saw_found=0;
      @(negedge clk); arp_rx_req=1;
      @(negedge clk); arp_rx_req=0;
      for(integer j=0;j<46;j=j+1) begin
        arp_rx_data=frame[j];
        @(negedge clk);
      end
      arp_rx_data=0;
      repeat(60) @(negedge clk);
    end
  endtask

  initial begin
    repeat(3) @(negedge clk); rst_n=1;
    repeat(2) @(negedge clk);
    if(!mac_not_exist || dest_mac!==48'hff_ff_ff_ff_ff_ff)
      $fatal(1,"cache must power up invalid");

    build_frame(16'h0001,32'hc0a80003,48'h280c50a00d11,LOCAL_IP,48'h0,1);
    ethernet_mac=48'h280c50a00d11;
    send_arp(); repeat(2) @(negedge clk);
    if(!arp_reply_req || !saw_found)
      $fatal(1,"expected peer request was not recognized (req=%b saw_found=%0d)",arp_reply_req,saw_found);
    repeat(2) @(negedge clk);
    if(mac_not_exist || dest_mac!==48'h280c50a00d11)
      $fatal(1,"expected peer request did not populate cache mac=%h missing=%b",dest_mac,mac_not_exist);

    @(negedge clk); arp_reply_ack=1; @(negedge clk); arp_reply_ack=0;
    build_frame(16'h0001,32'hc0a80064,48'h001122334455,LOCAL_IP,48'h0,1);
    ethernet_mac=48'h001122334455;
    send_arp(); repeat(2) @(negedge clk);
    if(saw_found || mac_not_exist || dest_mac!==48'h280c50a00d11)
      $fatal(1,"unrelated ARP request contaminated destination cache");

    @(negedge clk); arp_reply_ack=1; @(negedge clk); arp_reply_ack=0;
    build_frame(16'h0002,32'hc0a80003,48'h281122334466,LOCAL_IP,LOCAL_MAC,1);
    ethernet_mac=48'h281122334466;
    send_arp(); repeat(2) @(negedge clk);
    if(!saw_found || mac_not_exist || dest_mac!==48'h281122334466)
      $fatal(1,"matching reply did not refresh cache");

    @(negedge clk); arp_reply_ack=1; @(negedge clk); arp_reply_ack=0;
    build_frame(16'h0001,32'hc0a80003,48'h280c50a00d11,LOCAL_IP,48'h0,0);
    ethernet_mac=48'h280c50a00d11;
    send_arp(); repeat(2) @(negedge clk);
    if(saw_found || arp_reply_req || mac_not_exist || dest_mac!==48'h281122334466)
      $fatal(1,"malformed ARP affected reply/cache state");

    tx_active=1;
    repeat(2010) @(negedge clk);
    if(!mac_not_exist || dest_mac!==48'h281122334466)
      $fatal(1,"expiry must block new frames while preserving active-frame MAC bytes");
    tx_active=0; repeat(2) @(negedge clk);
    if(!mac_not_exist || dest_mac!==48'hff_ff_ff_ff_ff_ff)
      $fatal(1,"cache did not expire back to unresolved state");

    destination_ip=32'hc0a80064;
    repeat(2) @(negedge clk);
    if(!mac_not_exist || dest_mac!==48'hff_ff_ff_ff_ff_ff)
      $fatal(1,"changing destination IP must invalidate one-entry lookup");
    $display("PASS: invalid reset, targeted request learning, unrelated request rejection, reply refresh, malformed rejection, lease expiry, destination change");
    $finish;
  end
endmodule
