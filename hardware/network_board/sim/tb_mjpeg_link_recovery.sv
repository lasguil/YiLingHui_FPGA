`timescale 1ns/1ps
module tb_mjpeg_link_recovery #(
    parameter integer RESET_PACKETIZER_ON_LINK=1
);
    localparam integer W=32, H=16, JPEG_FIFO_AW=5, JPEG_FIFO_DEPTH=(1<<JPEG_FIFO_AW);
    localparam integer REFERENCE_MAX=4096;
    localparam integer DROP_NONE=0, DROP_HEADER=1, DROP_SCAN=2, DROP_EOI=3, DROP_FULL=4;

    reg proc_clk=0, net_clk=0;
    always #5 proc_clk=~proc_clk;
    always #7 net_clk=~net_clk;
    reg proc_reset_n=0, net_reset_n=0, net_stream_reset_n=0;
    wire net_begin;
    reg [23:0] src_data=0;
    reg src_valid=0, src_last=0, src_user=0;
    wire net_pop;
    wire src_ready, jpg_valid, jpg_last, jpg_ready, encoder_init_done;
    wire start_pulse, frame_active, link_abort;
    wire [7:0] jpg_byte;
    wire fifo_full, fifo_empty, fifo_write_empty;
    wire [8:0] fifo_data, net_pixel;
    wire net_error, net_busy, net_pixel_valid;
    wire source_overflow=1'b0, source_error=1'b0;

    mjpeg_top_glue_probe #(.REC_W(W),.REC_H(H),.FIFO_AW(JPEG_FIFO_AW)) glue(
        .proc_clk(proc_clk),.net_a_cmd_clk(net_clk),.rxc(net_clk),
        .proc_reset_n(proc_reset_n),.net_reset_n(net_reset_n),.net_stream_reset_n(net_stream_reset_n),
        .net_begin(net_begin),.mjpeg_rgb(src_data),.mjpeg_src_tvalid(src_valid),
        .mjpeg_src_tlast(src_last),.mjpeg_src_tuser(src_user),
        .mjpeg_source_overflow(source_overflow),.mjpeg_source_error(source_error),.net_pop(net_pop),
        .mjpeg_src_tready(src_ready),.mjpeg_jpg_valid(jpg_valid),.mjpeg_jpg_last(jpg_last),
        .mjpeg_jpg_byte(jpg_byte),.mjpeg_jpg_ready_o(jpg_ready),.encoder_init_done_o(encoder_init_done),
        .mjpeg_start_pulse(start_pulse),.mjpeg_frame_active(frame_active),
        .mjpeg_link_abort(link_abort),.mjpeg_fifo_full(fifo_full),.mjpeg_fifo_empty(fifo_empty),
        .mjpeg_fifo_write_empty(fifo_write_empty),.mjpeg_fifo_data(fifo_data),
        .net_error(net_error),.net_busy(net_busy),.net_pixel(net_pixel),.net_pixel_valid(net_pixel_valid)
    );

    // Real packetizer and a MAC-RAM handshake model. It can deliberately hold
    // the first packet request so the real top FIFO reaches full and stalls JPEG.
    wire [7:0] tx_data;
    wire tx_wr, tx_req, tx_busy;
    wire [15:0] tx_len, tx_port, cur_w, cur_h, cap_addr;
    wire [31:0] frame_cnt, pkt_cnt, drop_cnt;
    wire cap_pop, cap_rd_begin, cap_rd_end, cap_using;
    wire packetizer_reset_n=net_reset_n && ((RESET_PACKETIZER_ON_LINK==0) || net_stream_reset_n);
    assign net_begin=cap_rd_begin;
    assign net_pop=cap_pop;
    reg mac_send_end=0, tx_ram_req=0;
    reg hold_first_tx=0;
    integer hold_cycles=0;
    integer tx_state=0, tx_copy_count=0, tx_packet_offset=0, tx_delay=0;
    integer tx_payload_index=0, tx_payload_total=0, tx_completed_frames=0, tx_completed_packets=0;
    integer tx_packet_first=0, tx_packet_final=0;
    integer ref_count=0, tx_error_count=0;
    reg [7:0] reference [0:REFERENCE_MAX-1];

    vid_packet #(.JPEG_MODE(1),.WAIT_FRESH(1),.W(W),.H(H),.FPS(8'd255),
                 .PKT_MAX(16'd16),.CLK_HZ(27'd1000000)) packetizer(
        .clk(net_clk),.rst_n(packetizer_reset_n),.tx_data(tx_data),.tx_wr(tx_wr),.tx_len(tx_len),
        .tx_req(tx_req),.tx_port(tx_port),.tx_busy(tx_busy),.tx_ram_req(tx_ram_req),.mac_send_end(mac_send_end),
        .cfg_stream_en(1'b1),.cfg_test_src(2'd0),.frame_cnt(frame_cnt),.pkt_cnt(pkt_cnt),.drop_cnt(drop_cnt),
        .cur_w(cur_w),.cur_h(cur_h),.cap_addr(cap_addr),.cap_data({7'd0,fifo_data}),
        .cap_data_valid(!fifo_empty),.cap_last(fifo_data[8]),.cap_error(net_error),.cap_busy(net_busy),
        .cap_pop(cap_pop),.cap_valid(1'b1),.cap_present(1'b1),
        .cap_rd_begin(cap_rd_begin),.cap_rd_end(cap_rd_end),.cap_using(cap_using)
    );

    // Deterministic image source, one request per real packetizer cap_rd_begin.
    integer pixel_index=0, source_frame=0;
    reg source_running=0;
    always @* begin
        src_valid=source_running;
        src_user=source_running && (pixel_index==0);
        src_last=source_running && ((pixel_index%W)==W-1);
        src_data={8'(pixel_index*7+8'h21),8'(pixel_index*13+8'h31),8'(pixel_index*5+8'h91)};
    end
    always @(posedge proc_clk) begin
        if(!proc_reset_n) begin pixel_index<=0; source_frame<=0; source_running<=0; end
        else begin
            if(start_pulse && !source_running) begin pixel_index<=0; source_running<=1; end
            if(source_running && src_valid && src_ready) begin
                if(pixel_index==W*H-1) begin
                    source_running<=0;
                    source_frame<=source_frame+1;
                end else pixel_index<=pixel_index+1;
            end
        end
    end

    integer observed_jpeg_byte=0, observed_frames=0, last_frame_bytes=0;
    integer drop_mode=DROP_NONE, drop_target=0, drop_remaining=0;
    integer drop_count=0, mode_frame_bytes=0, full_seen=0, fifo_writes=0, output_stalls=0, full_stall_seen=0;
    integer eoi_stall_cycles=0;
    reg outage_active=0, eoi_pending_seen=0, eoi_checked_outage=0;
    reg [7:0] saved_reference [0:REFERENCE_MAX-1];
    integer saved_count=0;

    // Capture bytes accepted at the encoder/top boundary. The monitor observes
    // real output handshakes; it never forces or substitutes internal signals.
    always @(posedge proc_clk) begin
        if(!proc_reset_n) begin observed_jpeg_byte<=0; observed_frames<=0; mode_frame_bytes<=0; end
        else begin
            if(jpg_valid && jpg_ready) begin
                if(observed_jpeg_byte==0 && jpg_byte!==8'hff) $fatal(1,"JPEG did not begin with SOI FF");
                if(observed_jpeg_byte==1 && jpg_byte!==8'hd8) $fatal(1,"JPEG did not begin with SOI D8");
                if(observed_frames==0) begin
                    if(observed_jpeg_byte>=REFERENCE_MAX) $fatal(1,"reference JPEG exceeds scoreboard");
                    reference[observed_jpeg_byte]=jpg_byte;
                end
                observed_jpeg_byte<=observed_jpeg_byte+1;
                mode_frame_bytes<=mode_frame_bytes+1;
                if(jpg_last) begin
                    if(jpg_byte!==8'hd9) $fatal(1,"JPEG tlast did not mark EOI D9");
                    observed_frames<=observed_frames+1;
                    last_frame_bytes<=mode_frame_bytes+1;
                    observed_jpeg_byte<=0;
                    mode_frame_bytes<=0;
                end
            end
            if(fifo_full) full_seen<=1;
            if(jpg_valid && !jpg_ready) output_stalls<=output_stalls+1;
            if(fifo_full && jpg_valid && !jpg_ready) full_stall_seen<=1;
        end
    end

    // Exercise real FIFO reads through vid_packet. Verify packet headers and
    // every byte of each complete transmitted JPEG against the clean reference.
    always @(posedge net_clk) begin
        if(!net_reset_n) begin
            tx_state<=0; tx_ram_req<=0; mac_send_end<=0; tx_copy_count<=0;
            tx_packet_offset<=0; tx_delay<=0; tx_payload_index<=0; tx_payload_total<=0;
            tx_completed_frames<=0; tx_completed_packets<=0;
            tx_packet_first<=0; tx_packet_final<=0;
        end else if(!packetizer_reset_n) begin
            // Link reset cancels only the in-flight MAC packet transaction and
            // partial JPEG offset; complete-frame counters/reference survive.
            tx_state<=0; tx_ram_req<=0; mac_send_end<=0; tx_copy_count<=0;
            tx_packet_offset<=0; tx_delay<=0; tx_payload_index<=0;
            tx_packet_first<=0; tx_packet_final<=0;
        end else begin
            tx_ram_req<=0; mac_send_end<=0;
            case(tx_state)
                0: if(tx_req) begin
                    if(hold_first_tx && hold_cycles>0) hold_cycles<=hold_cycles-1;
                    else begin tx_ram_req<=1; tx_copy_count<=0; tx_packet_offset<=0; tx_state<=1; end
                end
                1: if(tx_wr) begin
                    if(tx_packet_offset<20) begin
                        case(tx_packet_offset)
                            0: if(tx_data!==8'h56) $fatal(1,"VID header magic[0]");
                            1: if(tx_data!==8'h49) $fatal(1,"VID header magic[1]");
                            2: if(tx_data!==8'd2) $fatal(1,"packet is not JPEG mode");
                            3: begin
                                tx_packet_first=tx_data[0]; tx_packet_final=tx_data[1];
                                if(tx_packet_first) tx_payload_index=0;
                            end
                            default: ;
                        endcase
                    end else begin
                        if(tx_payload_index>=REFERENCE_MAX || tx_payload_index>=observed_jpeg_byte && observed_frames==0)
                            $fatal(1,"transmitted payload exceeds known encoder output");
                        if(tx_data!==reference[tx_payload_index])
                            $fatal(1,"JPEG payload mismatch at %0d got=%02x expected=%02x",tx_payload_index,tx_data,reference[tx_payload_index]);
                        tx_payload_index<=tx_payload_index+1;
                    end
                    tx_packet_offset<=tx_packet_offset+1;
                    tx_copy_count<=tx_copy_count+1;
                    if(tx_copy_count+1==tx_len) begin tx_delay<=8; tx_state<=2; end
                end
                2: if(tx_delay==0) begin
                    mac_send_end<=1; tx_state<=0; tx_completed_packets<=tx_completed_packets+1;
                    if(tx_packet_final) begin
                        if(tx_payload_index!=saved_count) $fatal(1,"complete network JPEG bytes=%0d expected=%0d",tx_payload_index,saved_count);
                        if(tx_payload_index<2 || reference[tx_payload_index-2]!==8'hff || reference[tx_payload_index-1]!==8'hd9)
                            $fatal(1,"transmitted JPEG did not end at EOI");
                        tx_completed_frames<=tx_completed_frames+1;
                        tx_payload_total<=tx_payload_total+tx_payload_index;
                        tx_payload_index<=0;
                    end
                end else tx_delay<=tx_delay-1;
                default: tx_state<=0;
            endcase
        end
    end

    // Link outage trigger: header/scan/EOI byte offsets use a known clean JPEG
    // length discovered from the encoder, and DROP_FULL waits for true FIFO full.
    always @(negedge proc_clk) begin
        if(proc_reset_n && !outage_active && drop_mode!=DROP_NONE) begin
            if(drop_mode==DROP_FULL && fifo_full) begin
                outage_active=1; drop_remaining=drop_remaining; net_stream_reset_n=0; drop_count=drop_count+1;
            end else if(drop_mode!=DROP_FULL && mode_frame_bytes!=0) begin
                if(drop_mode==DROP_HEADER && mode_frame_bytes==12) begin
                    outage_active=1; net_stream_reset_n=0; drop_remaining=3; drop_count=drop_count+1;
                end else if(drop_mode==DROP_SCAN && mode_frame_bytes==drop_target) begin
                    outage_active=1; net_stream_reset_n=0; drop_remaining=3; drop_count=drop_count+1;
                end else if(drop_mode==DROP_EOI && saved_count>4 && mode_frame_bytes==drop_target) begin
                    if(!(jpg_valid && jpg_last && jpg_byte===8'hd9 && frame_active))
                        $fatal(1,"EOI outage did not catch pending final D9 before acceptance: valid=%b last=%b byte=%02x ready=%b active=%b count=%0d target=%0d",
                               jpg_valid,jpg_last,jpg_byte,jpg_ready,frame_active,mode_frame_bytes,drop_target);
                    eoi_pending_seen=1;
                    outage_active=1; net_stream_reset_n=0; drop_remaining=48; drop_count=drop_count+1;
                end
            end
        end
        if(outage_active) begin
            if(drop_remaining>0) drop_remaining=drop_remaining-1;
            else begin net_stream_reset_n=1; outage_active=0; drop_mode=DROP_NONE; end
        end
    end

    always @(posedge proc_clk) begin
        if(proc_reset_n && outage_active && drop_mode==DROP_EOI && !net_stream_reset_n) begin
            if(!(jpg_valid && jpg_last && jpg_byte===8'hd9 && frame_active && !jpg_ready))
                $fatal(1,"pending EOI D9 was not held under link-reset backpressure: valid=%b last=%b byte=%02x ready=%b active=%b",
                       jpg_valid,jpg_last,jpg_byte,jpg_ready,frame_active);
            eoi_stall_cycles<=eoi_stall_cycles+1;
            eoi_checked_outage<=1;
        end
    end

    integer required_recovered_frames=0;
    initial begin
        repeat(10) @(posedge proc_clk);
        proc_reset_n=1; net_reset_n=1; net_stream_reset_n=1;
        wait(encoder_init_done===1'b1);
        repeat(12) @(posedge net_clk);
        if(net_error!==1'b0 || net_busy!==1'b0) $fatal(1,"no-frame state must be idle without error: err=%b busy=%b",net_error,net_busy);
        // First uninterrupted frame establishes a byte-for-byte reference.
        wait(observed_frames==1);
        saved_count=last_frame_bytes;
        if(saved_count<625) $fatal(1,"baseline JPEG unexpectedly short: %0d",saved_count);
        $display("baseline JPEG complete: %0d bytes",saved_count);
        // One aborted frame per phase. Each must be drained before the packetizer
        // starts another encoder request; final two frames must transmit cleanly.
        drop_mode=DROP_HEADER; drop_target=12; drop_remaining=3;
        wait(drop_count==1); wait(!frame_active && !net_error && !net_busy);
        drop_mode=DROP_SCAN; drop_target=623+((saved_count-625)/2); drop_remaining=3;
        if(drop_target<=623 || drop_target>=saved_count-2) $fatal(1,"baseline too short to target scan phase: len=%0d target=%0d",saved_count,drop_target);
        wait(drop_count==2); wait(!frame_active && !net_error && !net_busy);
        drop_mode=DROP_EOI; drop_target=saved_count-1; drop_remaining=48;
        wait(drop_count==3); wait(!frame_active && !net_error && !net_busy);
        if(!eoi_pending_seen || !eoi_checked_outage || eoi_stall_cycles<10)
            $fatal(1,"EOI D9 was not held through link reset: pending=%0d held=%0d",eoi_pending_seen,eoi_stall_cycles);
        hold_first_tx=1; hold_cycles=5000;
        drop_mode=DROP_FULL; drop_remaining=20;
        wait(drop_count==4);
        if(!full_seen) $fatal(1,"full-FIFO outage did not observe full");
        if(output_stalls==0 || !full_stall_seen) $fatal(1,"full FIFO did not backpressure the real JPEG writer");
        required_recovered_frames=tx_completed_frames+3;
        hold_first_tx=0;
        wait(!frame_active && !net_error && !net_busy);
        wait(tx_completed_frames>=required_recovered_frames);
        if(tx_payload_total != saved_count*tx_completed_frames)
            $fatal(1,"transmitted complete JPEG byte total=%0d expected=%0d",tx_payload_total,saved_count*tx_completed_frames);
        $display("PASS: extracted top link/FIFO/ready/abort/status glue recovered after header/scan/EOI/full outages; packetizer_link_reset=%0d; %0d complete JPEG frames matched byte-for-byte (packetizer dropped %0d interrupted frames)",RESET_PACKETIZER_ON_LINK,tx_completed_frames,drop_cnt);
        $finish;
    end
    initial begin
        repeat(5000000) @(posedge proc_clk);
        $fatal(1,"timeout: observed=%0d active=%0b abort=%0b err=%0b busy=%0b fifo_full=%0b drops=%0d tx_frames=%0d",observed_frames,frame_active,link_abort,net_error,net_busy,fifo_full,drop_count,tx_completed_frames);
    end
endmodule
