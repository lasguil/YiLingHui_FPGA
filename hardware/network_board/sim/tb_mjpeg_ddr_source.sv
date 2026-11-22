`timescale 1ns/1ps
module tb_mjpeg_ddr_source #(
    parameter int SW=96, SH=48,
    parameter bit JPEG=1'b0, NETWORK=1'b0, IMAGE=1'b0,
    parameter bit OUTPUT_BACKPRESSURE=1'b0,
    parameter int CAPTURE_FIFO_AW=11, JPEG_FIFO_AW=13,
    parameter bit AUTO_INPUT=1'b0, INPUT_720P=1'b0,
    parameter int FLAT_EVERY=0, FRAME_TARGET=3,
    parameter int MAC_STALL_CYCLES=0, ALLOW_DROPS=0,
    parameter int NET_PACE_HZ=25_000_000, NET_FPS=30
);
    import demo_bus_pkg::*;
    localparam int OW=SW*2/3,OH=SH*2/3,FB=OW*OH*3;
    localparam int IW=INPUT_720P?OW:SW, IH=INPUT_720P?OH:SH;
    localparam int HB=INPUT_720P?IW*370/1280:SW*280/1920, VB=SH*45/1080+2;
    localparam logic [31:0] BASE0=32'h03400000,BASE1=32'h03800000;
    logic clk=0,pclk=0,reset=1,vs=0,de=0,manual_request=0,manual_ready=0;
    wire ready,init_done,network_request;
    wire request=NETWORK ? network_request : manual_request;
    wire [31:0] transmitted;
    wire [31:0] network_drops;
    wire output_overflow_observed;
    wire network_fifo_full;
    wire jpg_ready = !NETWORK || !network_fifo_full;
    if(!NETWORK)begin assign network_manual_request=0;assign transmitted=0;
        assign network_drops=0;assign output_overflow_observed=0;assign network_fifo_full=0;end
    int jpeg_frames=0;
    string jpeg_prefix="tmp/ddr_mjpeg_frame";
    initial void'($value$plusargs("JPEG_PREFIX=%s",jpeg_prefix));
    always #2.778 clk=~clk;
    always #(INPUT_720P?6.734:3.367) pclk=~pclk;
    logic [7:0] r=0,g=0,b=0;
    logic [23:0] source_image[0:SW*SH-1];
    string image_hex="tmp/mjpeg_noise_rgb.hex";
    initial begin
        void'($value$plusargs("IMAGE_HEX=%s",image_hex));
        if(IMAGE)$readmemh(image_hex,source_image);
    end
    logic [23:0] data;
    logic valid,last,sof,overflow,error,toggle,available;
    axi_req_t req,source_req;axi_rsp_t rsp,source_rsp;
    if(NETWORK)begin:g_bus_load
        axi_req_t peers[5];axi_rsp_t replies[5];
        int writer_state=0,writer_beat=0;
        always_comb begin
            for(int i=0;i<5;i++)peers[i]='0;
            peers[4]=source_req;
            peers[0].awaddr=32'h03000000;peers[0].awlen=15;
            peers[0].awsize=4;peers[0].awburst=1;peers[0].awvalid=writer_state==0&&!reset;
            peers[0].wstrb=16'hffff;peers[0].wlast=writer_beat==15;
            peers[0].wvalid=writer_state==1;peers[0].bready=writer_state==2;
        end
        assign source_rsp=replies[4];
        demo_axi_merge #(.CLIENTS(5)) bus_merge(.clk(clk),.reset(reset),.ddr_ready(!reset),
            .display_urgent(1'b0),.capture_urgent(peers[0].awvalid),
            .req(peers),.rsp(replies),.mem_req(req),.mem_rsp(rsp),.idle());
        always @(posedge clk)if(!reset)case(writer_state)
            0:if(replies[0].awready)begin writer_beat<=0;writer_state<=1;end
            1:if(replies[0].wready)begin
                if(writer_beat==15)writer_state<=2;else writer_beat<=writer_beat+1;
            end
            2:if(replies[0].bvalid)writer_state<=0;
        endcase
    end else begin assign req=source_req;assign source_rsp=rsp;end
    mjpeg_ddr_source #(.SRC_W(SW),.SRC_H(SH),.FIFO_ADDR_W(CAPTURE_FIFO_AW),.AUTO_INPUT_MODE(AUTO_INPUT)) dut(
        .pclk(pclk),.proc_clk(clk),.reset,.request,
        .hdmi_vs(vs),.hdmi_de(de),.hdmi_r(r),.hdmi_g(g),.hdmi_b(b),
        .tdata(data),.tvalid(valid),.tready(ready),.tlast(last),.tuser(sof),
        .overflow_sticky(overflow),.source_error_sticky(error),
        .frame_done_toggle(toggle),.frame_available(available),.axi_req(source_req),.axi_rsp(source_rsp));
    if(JPEG)begin:g_jpeg
        wire [4:0] awaddr,araddr;
        wire awvalid,awready,wvalid,wready,bvalid,bready,arvalid,arready,rvalid,rready;
        wire [31:0] wdata,rdata;
        wire [3:0] wstrb;
        wire [1:0] bresp,rresp;
        wire jpg_valid,jpg_last;
        wire [7:0] jpg_byte;
        axi_init init_encoder(.clk(clk),.rst_n(!reset),
            .m_axi_awaddr(awaddr),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
            .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
            .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
            .m_axi_araddr(araddr),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
            .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rvalid),.m_axi_rready(rready),
            .quality_req(1'b0),.quality_value(7'd75),.quality_busy(),.quality_done(),.init_done(init_done));
`ifdef CODEC_MAPPED
        codec_probe encoder(
`else
        mjpegzero_enc_top #(.IMG_WIDTH(OW),.IMG_HEIGHT(OH),.RGB_INPUT(1),.LITE_QUALITY(75),
                            .OUTPUT_BACKPRESSURE(OUTPUT_BACKPRESSURE)) encoder(
`endif
            .clk(clk),.rst_n(!reset),.s_axis_vid_tdata(data),.s_axis_vid_tvalid(valid),
            .s_axis_vid_tready(ready),.s_axis_vid_tlast(last),.s_axis_vid_tuser(sof),
            .m_axis_jpg_tvalid(jpg_valid),.m_axis_jpg_tdata(jpg_byte),.m_axis_jpg_tlast(jpg_last),
            .m_axis_jpg_tready(jpg_ready),
            .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
            .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
            .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
            .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
            .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready));
        int fd=0,jpeg_bytes=0,jpeg_total_bytes=0;
        logic [7:0] jpeg_expected[0:5_999_999];
        always @(posedge clk)if(!reset&&jpg_valid&&jpg_ready)begin
            if(jpeg_bytes>=6_000_000)$fatal(1,"encoded frame exceeds test byte scoreboard");
            jpeg_expected[jpeg_total_bytes]=jpg_byte;
            jpeg_total_bytes++;
            if(fd==0)fd=$fopen($sformatf("%s_%0d.jpg",jpeg_prefix,jpeg_frames),"wb");
            $fwrite(fd,"%c",jpg_byte);jpeg_bytes++;
            if(jpg_last)begin
                $fclose(fd);fd=0;
                $display("JPEG frame %0d: %0d bytes",jpeg_frames,jpeg_bytes);
                jpeg_frames++;jpeg_bytes=0;
            end
        end
        if(NETWORK)begin:g_network
            logic nclk=0;
            always #20 nclk=~nclk;
            logic begin_frame,pop,end_frame;
            logic toggle_req=0;
            logic [2:0] req_sync=0;
            logic active=0,output_overflow=0,frame_error=0;
            logic [1:0] active_sync=0,error_sync=0;
            logic [8:0] fifo_data;
            logic fifo_full,fifo_empty,fifo_write_empty;
            assign network_fifo_full=fifo_full;
            wire [7:0] tx_data;
            wire tx_wr,tx_req,tx_busy;
            wire [15:0] tx_len,tx_port,unused_w,unused_h,unused_addr;
            wire [31:0] pkt_count,drop_count;
            logic ram_req=0,send_end=0;
            int tx_state=0,copied=0,delay_end=0,writes=0,reads=0,max_fill=0;
            int tx_packet_offset=0,jpeg_tx_compared=0;
            int inject_stall=MAC_STALL_CYCLES;
            int stall_left=0;
            logic tx_req_prev=0;
            assign network_drops=drop_count;
            assign output_overflow_observed=output_overflow;
            assign network_request=req_sync[2]^req_sync[1];
            always @(posedge clk)begin
                if(reset)begin req_sync<=0;active<=0;output_overflow<=0;frame_error<=0;end
                else begin
                    req_sync<={req_sync[1:0],toggle_req};
                    if(network_request)active<=1;
                    else if(jpg_valid&&jpg_ready&&jpg_last)active<=0;
                    if(!active && fifo_write_empty)frame_error<=0;
                    if(jpg_valid)begin
                        if(jpg_ready)writes++;
                        if(writes-reads>max_fill)max_fill=writes-reads;
                        if(fifo_full)begin
                            output_overflow<=1;
                            if(!OUTPUT_BACKPRESSURE)begin
                                frame_error<=1;
                                if(!ALLOW_DROPS)$fatal(1,"encoded JPEG FIFO overflow: fill=%0d capacity=%0d",writes-reads,1<<JPEG_FIFO_AW);
                            end
                        end
                    end
                end
            end
            gesture_async_fifo #(.DATA_W(9),.ADDR_W(JPEG_FIFO_AW)) output_fifo(
                .arst(reset),.wclk(clk),.wr_en(OUTPUT_BACKPRESSURE ? (jpg_valid&&jpg_ready) : jpg_valid),
                .wr_data({jpg_last,jpg_byte}),
                .full(fifo_full),.write_empty(fifo_write_empty),.rclk(nclk),.rd_en(pop),.rd_data(fifo_data),.empty(fifo_empty));
            vid_packet #(.JPEG_MODE(1),.WAIT_FRESH(1),.W(OW),.H(OH),.FPS(NET_FPS),.CLK_HZ(NET_PACE_HZ)) packetizer(
                .clk(nclk),.rst_n(!reset),.tx_data(tx_data),.tx_wr(tx_wr),.tx_len(tx_len),
                .tx_req(tx_req),.tx_port(tx_port),.tx_busy(tx_busy),.tx_ram_req(ram_req),.mac_send_end(send_end),
                .cfg_stream_en(1'b1),.cfg_test_src(2'd0),.frame_cnt(transmitted),.pkt_cnt(pkt_count),.drop_cnt(drop_count),
                .cur_w(unused_w),.cur_h(unused_h),.cap_addr(unused_addr),.cap_data({7'd0,fifo_data}),
                .cap_data_valid(!fifo_empty),.cap_last(fifo_data[8]),.cap_error(error_sync[1]),.cap_busy(active_sync[1]),
                .cap_pop(pop),.cap_valid(1'b1),.cap_present(available),.cap_rd_begin(begin_frame),.cap_rd_end(end_frame),.cap_using());
            always @(posedge nclk)begin
                if(reset)begin toggle_req<=0;active_sync<=0;error_sync<=0;ram_req<=0;send_end<=0;end
                else begin
                    if(begin_frame)toggle_req<=!toggle_req;
                    active_sync<={active_sync[0],active};error_sync<={error_sync[0],frame_error};
                    if(pop&&!fifo_empty)reads++;
                    send_end<=0;ram_req<=0;
                    if(tx_req && !tx_req_prev && inject_stall>0)begin
                        stall_left=(inject_stall>25000)?25000:inject_stall;
                        inject_stall=inject_stall-stall_left;
                    end
                    tx_req_prev<=tx_req;
                    case(tx_state)
                        0:if(tx_req)begin
                            if(stall_left>0)stall_left--;
                            else begin ram_req<=1;copied=0;tx_packet_offset=0;tx_state=1;end
                        end
                        1:if(tx_wr)begin
                            if(tx_packet_offset>=20)begin
                                if(jpeg_tx_compared>=jpeg_total_bytes)
                                    $fatal(1,"network transmitted JPEG beyond accepted encoder bytes (%0d)",jpeg_tx_compared);
                                if(tx_data!==jpeg_expected[jpeg_tx_compared])
                                    $fatal(1,"JPEG payload mismatch at byte %0d: tx=%02x encoder=%02x",
                                           jpeg_tx_compared,tx_data,jpeg_expected[jpeg_tx_compared]);
                                jpeg_tx_compared++;
                            end
                            tx_packet_offset++;
                            copied++;
                            if(copied==int'(tx_len))begin delay_end=int'(tx_len)+100;tx_state=2;end
                        end
                        2:if(delay_end==0)begin send_end<=1;tx_state=0;end else delay_end--;
                    endcase
                    if(drop_count!=0 && !ALLOW_DROPS)$fatal(1,"packetizer dropped JPEG frame");
                    if(end_frame)$display("network frame done, max JPEG FIFO fill=%0d bytes",max_fill);
                end
            end
        end
    end else begin
        assign ready=manual_ready;
        assign init_done=1'b1;
    end
    byte mem[0:2*FB-1];
    function automatic int index_for(input logic [31:0] addr);
        if(addr>=BASE1) return FB+int'(addr-BASE1);
        return int'(addr-BASE0);
    endfunction
    logic wa=0,ra=0,bv=0;
    int wl=0,rl=0,delay_b=0,cycle=0;
    logic [31:0] waddr=0,raddr=0;
    wire signed [31:0] write_base_index=index_for(waddr);
    // The memory-backed response is sampled every non-reset clock through
    // cycle; this avoids putting the multi-megabyte DDR model in an implicit
    // always_comb sensitivity set while still observing same-edge NBA writes.
    always @(wa or bv or cycle or ra or rl or raddr or delay_b) begin
        rsp='0;
        rsp.awready=!wa&&!bv&&(cycle%7<5);
        rsp.wready=wa&&(cycle%11!=3);
        rsp.bvalid=bv&&delay_b==0;
        rsp.arready=!ra&&(cycle%9<6);
        rsp.rvalid=ra;rsp.rlast=rl==1;
        if(ra)for(int i=0;i<16;i++)rsp.rdata[8*i+:8]=mem[index_for(raddr)+i];
    end
    logic aw_stalled=0,ar_stalled=0;
    logic [31:0] awheld,arheld;
    logic [7:0] awlenheld,arlenheld;
    always @(posedge clk)if(!reset)begin
        cycle<=cycle+1;
        if(aw_stalled&&(!req.awvalid||req.awaddr!=awheld||req.awlen!=awlenheld))
            $fatal(1,"AW payload changed while stalled");
        if(ar_stalled&&(!req.arvalid||req.araddr!=arheld||req.arlen!=arlenheld))
            $fatal(1,"AR payload changed while stalled");
        aw_stalled<=req.awvalid&&!rsp.awready;awheld<=req.awaddr;awlenheld<=req.awlen;
        ar_stalled<=req.arvalid&&!rsp.arready;arheld<=req.araddr;arlenheld<=req.arlen;
        if(delay_b>0)delay_b<=delay_b-1;
        if(req.awvalid&&rsp.awready)begin
            if(int'(req.awaddr[11:0])+(int'(req.awlen)+1)*16>4096)$fatal(1,"write crosses 4KiB");
            wa<=1;wl<=int'(req.awlen)+1;waddr<=req.awaddr;
        end
        if(req.wvalid&&rsp.wready)begin
            if(req.wlast!=(wl==1))$fatal(1,"bad WLAST");
            if(waddr>=BASE0)begin
                if(write_base_index<0||write_base_index+15>=2*FB)$fatal(1,"capture outside frame banks");
                for(int i=0;i<16;i++)mem[write_base_index+i]<=req.wdata[8*i+:8];
            end else if(waddr<32'h03000000||waddr>=32'h03000100)$fatal(1,"unexpected peer address");
            waddr<=waddr+16;wl<=wl-1;
            if(wl==1)begin wa<=0;bv<=1;delay_b<=4;end
        end
        if(req.bready&&rsp.bvalid)bv<=0;
        if(req.arvalid&&rsp.arready)begin
            if(int'(req.araddr[11:0])+(int'(req.arlen)+1)*16>4096)$fatal(1,"read crosses 4KiB");
            ra<=1;rl<=int'(req.arlen)+1;raddr<=req.araddr;
        end
        if(req.rready&&rsp.rvalid)begin
            raddr<=raddr+16;rl<=rl-1;if(rl==1)ra<=0;
        end
    end
    initial begin
        wait(!reset);
        for(int fid=1;fid<256;fid++)begin
            @(negedge pclk);vs=1;de=0;
            repeat(4)@(negedge pclk);vs=0;
            for(int y=0;y<IH;y++)begin
                for(int x=0;x<IW;x++)begin
                    de=1;
                    if(IMAGE && FLAT_EVERY>0 && fid%FLAT_EVERY==0)begin r=250;g=252;b=254;end
                    else if(IMAGE)begin r=source_image[y*SW+x][23:16];g=source_image[y*SW+x][15:8];b=source_image[y*SW+x][7:0];end
                    else begin r=8'(x+fid);g=8'(y^fid);b=8'(x+y+fid);end
                    @(negedge pclk);
                end
                de=0;repeat(HB)@(negedge pclk);
            end
            repeat(VB*(SW+HB))@(negedge pclk);
        end
    end
    int received=0,finished=0,chosen_id=0,first_id=0;
    logic stalled=0;
    logic [25:0] held_stream;
    always @(posedge clk)if(!reset)begin
        if(stalled && {sof,last,data}!==held_stream)$fatal(1,"video changed under backpressure");
        stalled<=valid&&!ready;held_stream<={sof,last,data};
        if(valid&&ready)begin
            automatic int x=received%OW,y=received/OW;
            automatic int sx=INPUT_720P?x:x/2*3+x%2,sy=INPUT_720P?y:y/2*3+y%2;
            if(received==0)begin chosen_id=int'(data[23:16]);if(finished==0)first_id=chosen_id;end
            if(data!==(IMAGE ? (FLAT_EVERY>0 && chosen_id==250 ? 24'hfafcfe : source_image[sy*SW+sx]) : {8'(sx+chosen_id),8'(sy^chosen_id),8'(sx+sy+chosen_id)}))
                $fatal(1,"torn/wrong RGB pixel=%0d got=%h frame=%0d",received,data,chosen_id);
            if(sof!=(received==0)||last!=(x==OW-1))$fatal(1,"incorrect SOF/EOL");
            received++;
            if(received==OW*OH)begin received=0;finished++;end
        end
        if(error)$fatal(1,"DDR reader error");
    end
    initial begin
        repeat(20)@(negedge clk);reset=0;
        wait(available&&init_done);
        if(NETWORK)begin
            wait(transmitted>=FRAME_TARGET);
            if(overflow)$fatal(1,"capture pixel FIFO overflow during network encoding");
            if(OUTPUT_BACKPRESSURE && MAC_STALL_CYCLES>=100000)begin
                if(!output_overflow_observed)$fatal(1,"configured MAC stall did not exercise output FIFO backpressure");
                if(network_drops!=0)$fatal(1,"backpressure mode dropped %0d JPEG frames",network_drops);
            end
            if(ALLOW_DROPS && (!output_overflow_observed || network_drops!=1))
                $fatal(1,"fault injection did not exercise overflow and recovery");
            $display("PASS: %0d live DDR -> 720p JPEG -> paced network frames, dropped=%0d",FRAME_TARGET,network_drops);
            $finish;
        end
        @(negedge clk);manual_request=1;@(negedge clk);manual_request=0;
        // Hold the selected frame across multiple HDMI publications. Capture
        // must skip a locked bank, then recover after the reader releases it.
        repeat((SW+HB)*SH*3)@(negedge clk);
        while(finished<1)begin @(negedge clk);manual_ready=(cycle%13<10);end
        manual_ready=0;
        repeat((SW+HB)*SH*2)@(negedge clk);
        manual_request=1;@(negedge clk);manual_request=0;
        while(finished<2)begin @(negedge clk);manual_ready=(cycle%17<13);end
        if(JPEG)wait(jpeg_frames==2);
        if(!IMAGE && chosen_id==first_id)$fatal(1,"capture did not refresh after releasing lock");
        if(overflow)$fatal(1,"pixel FIFO overflow at 148.5MHz source / 180MHz writer");
        $display("PASS: %0dx%0d DDR RGB888, pixel-exact 2/3 sampling, stalls, slot ownership, fresh frames",OW,OH);
        $finish;
    end
    initial begin #250_000_000;$fatal(1,"DDR MJPEG source timeout");end
    initial if(JPEG && $test$plusargs("FIRST_JPEG"))begin
        wait(jpeg_frames==1);
        $display("PASS: first reference JPEG completed");
        $finish;
    end
endmodule
