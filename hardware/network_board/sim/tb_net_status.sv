`timescale 1ns/1ps
module tb_net_status;
    reg clk=0;always #20 clk=~clk;
    reg rst_n=0;
    udp_regs #(.DEF_W(320),.DEF_H(180),.DEF_FPS(60),.FIXED_VIDEO(1)) dut(.clk,.rst_n,
      .link_speed(2'b01),.link_up(1'b1),.src5v(1'b1),.pll_lock(1'b1),.rxc_alive(1'b1),
      .ddr_ready(1'b1),.board_status(6'h3f),
      .hd_frame_valid(1'b1),.hd_cap_using(1'b1),.hd_cap_on(1'b0),
      .hd_src_w(12'd1920),.hd_src_h(12'd1080),.hd_frame_cnt(32'd17),
      .rx_valid(1'b0),.rx_data(8'd0),.rx_len(16'd0),.tx_ram_req(1'b0),
      .mac_send_end(1'b0),.arp_found(1'b0),.mac_not_exist(1'b1),
      .stat_frame_cnt(32'd0),.stat_pkt_cnt(32'd0),.stat_tx_err(32'd0));
    initial begin
        repeat(3)@(negedge clk);rst_n=1;@(negedge clk);
        if(dut.reg_read(16'h0038)!==32'hc7800438)$fatal(1,"HDMI width/height/status bit layout");
        if(dut.reg_read(16'h002c)!==32'h0000005f)$fatal(1,"DDR/link status bit layout");
        if(dut.reg_read(16'h0040)!==32'h0000003f)$fatal(1,"board diagnostics");
        if(dut.reg_read(16'h003c)!==17)$fatal(1,"capture sequence");
        if(dut.reg_read(16'h0044)!==0)$fatal(1,"spacing must default disabled");
        dut.reg_write(16'h0044,32'd12500);@(negedge clk);
        if(dut.reg_read(16'h0044)!==12500)$fatal(1,"spacing write/readback");
        dut.reg_write(16'h0044,32'hffff_ffff);@(negedge clk);
        if(dut.reg_read(16'h0044)!==65535)$fatal(1,"spacing must saturate");
        dut.reg_write(16'h0044,32'd0);@(negedge clk);
        if(dut.reg_read(16'h0044)!==0)$fatal(1,"spacing disable");
        dut.reg_write(16'h0004,32'h02d00500);
        dut.reg_write(16'h0008,32'd120);
        dut.reg_write(16'h0010,32'd128);
        @(negedge clk);
        if(dut.reg_read(16'h0004)!=={16'd180,16'd320} || dut.reg_read(16'h0008)!==60 || dut.reg_read(16'h0010)!==1472)
            $fatal(1,"fixed profile CSR lied about actual geometry/fps/packet size");
        $display("PASS: fixed-profile mode/fps/payload writes preserve actual hardware readback");
        $display("PASS: network status register bit layout and DDR diagnostics");$finish;
    end
endmodule
