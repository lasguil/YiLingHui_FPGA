`timescale 1ns/1ps
module tb_udp_dest_persist;
    localparam [31:0] LOCAL_IP = 32'hc0a80002;
    localparam [47:0] LOCAL_MAC = 48'h000a3501fec0;
    localparam [31:0] DEFAULT_IP = 32'hc0a80003;
    localparam [31:0] TEST_IP = 32'hc0a80064;
    localparam [15:0] TEST_PORT = 16'd60123;

    reg clk=0,board_reset_n=0,e_rst_n=0;
    always #5 clk=~clk;
    reg rx_valid=0,tx_ram_req=0,arp_send_end=0,udp_mac_send_end=0;
    reg [15:0] rx_len=20;
    reg [7:0] rx_payload[0:11];
    wire [10:0] rx_addr;
    wire [7:0] rx_data=rx_payload[rx_addr];
    wire [31:0] cfg_dest_ip;
    wire [15:0] dest_port;
    wire [7:0] tx_data;
    wire tx_wr,tx_req,arp_req,tx_busy,dbg_arp_ok;
    wire [15:0] tx_len;
    wire [15:0] cfg_w,cfg_h,cfg_pkt;
    wire [7:0] cfg_fps;
    wire cfg_en;
    wire [1:0] cfg_src;
    wire [31:0] cfg_a,cfg_b,cfg_c,cfg_d,rxpkts,txpkts;
    wire a_cmd_valid;
    wire [31:0] a_cmd_token;
    wire [7:0] a_cmd_type,a_cmd_length;
    wire [431:0] a_cmd_payload;
    wire [7:0] mac_tx_data;
    wire mac_data_valid,mac_send_end,udp_payload_end,udp_ram_req,mac_not_exist;
    wire [7:0] udp_rx_byte;
    wire [10:0] udp_rx_addr;
    wire [15:0] udp_rx_len;
    wire udp_rx_valid;
    wire [31:0] zero32=0;
    wire [11:0] zero12=0;
    integer tx_count=0;
    reg [7:0] tx_bytes[0:127];
    reg [15:0] seq=16'd7;
    reg arp_request_req=0;

    udp_regs #(.TICK_1S(27'd1000),.PERSIST_DEST(1)) dut(
        .clk(clk),.rst_n(e_rst_n),.cfg_reset_n(board_reset_n),
        .tx_data(tx_data),.tx_wr(tx_wr),.tx_len(tx_len),.tx_req(tx_req),
        .arp_req(arp_req),.dest_port(dest_port),.tx_busy(tx_busy),.tx_ram_req(tx_ram_req),
        .arp_send_end(arp_send_end),.mac_send_end(udp_mac_send_end),
        .arp_found(1'b0),.mac_not_exist(1'b1),.rx_data(rx_data),.rx_addr(rx_addr),
        .rx_len(rx_len),.rx_valid(rx_valid),.link_speed(2'b01),.link_up(1'b1),
        .src5v(1'b0),.pll_lock(1'b1),.rxc_alive(1'b1),.ddr_ready(1'b1),
        .board_status(6'd0),.default_dest_ip_addr(DEFAULT_IP),
        .cfg_w(cfg_w),.cfg_h(cfg_h),.cfg_fps(cfg_fps),.cfg_stream_en(cfg_en),
        .cfg_pkt_size(cfg_pkt),.cfg_test_src(cfg_src),.cfg_dest_ip(cfg_dest_ip),
        .cfg_a_effect(cfg_a),.cfg_a_strength(cfg_b),.cfg_a_style(cfg_c),.cfg_a_freeze(cfg_d),
        .a_cmd_valid(a_cmd_valid),.a_cmd_ready(1'b1),.a_cmd_token(a_cmd_token),
        .a_cmd_type(a_cmd_type),.a_cmd_length(a_cmd_length),.a_cmd_payload(a_cmd_payload),
        .a_status_valid(1'b0),.a_status_data(64'd0),.hd_frame_valid(1'b0),
        .hd_cap_using(1'b0),.hd_cap_on(1'b0),.hd_src_w(12'd0),.hd_src_h(12'd0),
        .hd_frame_cnt(zero32),.stat_frame_cnt(zero32),.stat_pkt_cnt(zero32),
        .stat_tx_err(zero32),.dbg_rx_pkts(rxpkts),.dbg_tx_pkts(txpkts),.dbg_arp_ok(dbg_arp_ok)
    );

    mac_top net(
      .udp_tx_pending(1'b0),
        .gmii_tx_clk(clk),.gmii_rx_clk(clk),.rst_n(e_rst_n),.tx_accept_ready(1'b1),
        .source_mac_addr(LOCAL_MAC),.TTL(8'd64),.source_ip_addr(LOCAL_IP),
        .destination_ip_addr(cfg_dest_ip),.udp_send_source_port(16'd40000),
        .udp_send_destination_port(dest_port),.ram_wr_data(8'd0),.ram_wr_en(1'b0),
        .udp_ram_data_req(udp_ram_req),.udp_send_data_length(16'd0),.udp_tx_req(1'b0),
        .arp_request_req(arp_request_req),.mac_data_valid(mac_data_valid),
        .mac_send_end(mac_send_end),.udp_payload_end(udp_payload_end),.mac_tx_data(mac_tx_data),
        .rx_dv(1'b0),.mac_rx_datain(8'd0),.udp_rec_ram_rdata(udp_rx_byte),
        .udp_rec_ram_read_addr(udp_rx_addr),.udp_rec_data_length(udp_rx_len),
        .udp_rec_data_valid(udp_rx_valid),.arp_found(),.mac_not_exist(mac_not_exist)
    );

    always @(negedge clk) if(e_rst_n && mac_data_valid && tx_count<128) begin
        tx_bytes[tx_count]=mac_tx_data;
        tx_count=tx_count+1;
    end

    task automatic control_write(input [15:0] addr,input [31:0] value);
        begin
            rx_payload[0]=8'h43; rx_payload[1]=8'h54; rx_payload[2]=8'h01; rx_payload[3]=8'h01;
            rx_payload[4]=seq[15:8]; rx_payload[5]=seq[7:0]; seq=seq+1;
            rx_payload[6]=addr[15:8]; rx_payload[7]=addr[7:0];
            rx_payload[8]=value[31:24]; rx_payload[9]=value[23:16];
            rx_payload[10]=value[15:8]; rx_payload[11]=value[7:0];
            @(negedge clk); rx_valid=1;
            @(negedge clk); rx_valid=0;
            repeat(40) @(negedge clk);
        end
    endtask

    initial begin
        repeat(5) @(negedge clk);
        board_reset_n=1; e_rst_n=1;
        repeat(3) @(negedge clk);
        if(cfg_dest_ip!==DEFAULT_IP || dest_port!==16'd5000)
            $fatal(1,"bad board-reset defaults: IP=%h port=%0d",cfg_dest_ip,dest_port);

        // Program destination IP and UDP control port through the actual RX parser.
        control_write(16'h0014,TEST_IP);
        control_write(16'h0018,{16'd0,TEST_PORT});
        if(cfg_dest_ip!==TEST_IP || dest_port!==TEST_PORT)
            $fatal(1,"configuration writes did not stick: IP=%h port=%0d",cfg_dest_ip,dest_port);

        // A PHY/link reset drops e_rst_n but leaves the board reset asserted high.
        e_rst_n=0; repeat(4) @(negedge clk); e_rst_n=1; repeat(4) @(negedge clk);
        if(cfg_dest_ip!==TEST_IP || dest_port!==TEST_PORT)
            $fatal(1,"link reset lost configured destination: IP=%h port=%0d",cfg_dest_ip,dest_port);
        if(net.destination_ip_addr!==TEST_IP || net.mac_tx0.ip0.destination_ip_addr!==TEST_IP)
            $fatal(1,"persistent IP did not reach MAC TX endpoint");

        // New MAC reset means ARP is unresolved; request must target the persisted peer.
        arp_request_req=1; @(negedge clk); arp_request_req=0;
        wait(mac_send_end); repeat(3) @(negedge clk);
        if(tx_count<50) $fatal(1,"ARP request output too short (%0d bytes)",tx_count);
        if(tx_bytes[46]!==TEST_IP[31:24] || tx_bytes[47]!==TEST_IP[23:16] ||
           tx_bytes[48]!==TEST_IP[15:8] || tx_bytes[49]!==TEST_IP[7:0])
            $fatal(1,"ARP target did not use persisted peer IP");

        // A full board reset clears both persistent destination registers.
        e_rst_n=0; board_reset_n=0; repeat(4) @(negedge clk);
        if(cfg_dest_ip!==DEFAULT_IP || dest_port!==16'd5000)
            $fatal(1,"board reset did not restore destination defaults: IP=%h port=%0d",cfg_dest_ip,dest_port);
        board_reset_n=1; e_rst_n=1;
        $display("PASS: destination IP/port survive link reset, ARP uses persisted IP, board reset restores defaults");
        $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
