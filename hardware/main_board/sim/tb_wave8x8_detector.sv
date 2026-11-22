`timescale 1ns/1ps
module tb_wave8x8_detector;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,enable=1,frame_start=0,block_valid=0;
    reg [5:0] block_index=0,block_mean=0;
    wire event_valid,event_dir,decision_done,right_toggle,left_toggle;
    wave_pulse_detector dut(.clk,.rst_n,.enable,.frame_start,.block_valid,.mode_60(1'b0),
        .block_index,.block_mean,.event_valid,.event_dir,.decision_done,
        .event_toggle(right_toggle),.left_toggle,.debug_state(),.debug_changed());
    string file_path;integer fd,code,value,frame_number=0,events=0;
    integer expected[0:12];integer pixels[0:63];integer i,waited;
    reg old_right=0,old_left=0;
    initial begin
        if(!$value$plusargs("VECTORS=%s",file_path))$fatal(1,"missing VECTORS");
        fd=$fopen(file_path,"r");if(!fd)$fatal(1,"cannot open vectors");
        repeat(5)@(negedge clk);rst_n=1;
        while(!$feof(fd))begin
            code=$fscanf(fd,"%d",pixels[0]);
            if(code==1)begin
                for(i=1;i<64;i=i+1)if($fscanf(fd,"%d",pixels[i])!=1)$fatal(1,"short blocks");
                for(i=0;i<13;i=i+1)if($fscanf(fd,"%d",expected[i])!=1)$fatal(1,"short expectation");
                frame_start=1;@(negedge clk);frame_start=0;
                for(i=0;i<64;i=i+1)begin
                    block_valid=1;block_index=6'(i);block_mean=6'(pixels[i]);@(negedge clk);
                    block_valid=0;repeat(i%3)@(negedge clk);
                end
                waited=0;
                while(!decision_done&&waited<300)begin @(negedge clk);waited++;end
                if(!decision_done)$fatal(1,"decision timeout frame %0d",frame_number);
                if(event_valid!==(expected[0]!=0)||(event_valid&&event_dir!==(expected[0]==2)))
                    $fatal(1,"event frame %0d got %0d/%0d expected %0d",frame_number,event_valid,event_dir,expected[0]);
                if(frame_number>0)begin
                    if(dut.area!==expected[1]||dut.maximum_fill!==expected[2]||dut.threshold!==expected[3]||
                       (expected[1]>=2&&dut.centroid!==expected[4]))
                        $fatal(1,"arithmetic frame %0d area %0d/%0d fill %0d/%0d tau %0d/%0d cx %0d/%0d",frame_number,
                            dut.area,expected[1],dut.maximum_fill,expected[2],dut.threshold,expected[3],dut.centroid,expected[4]);
                    if(dut.active!==expected[5]||dut.blocked!==expected[6]||dut.reference_x!==expected[7]||
                       dut.peak_area!==expected[8]||dut.peak_fill!==expected[9]||dut.episode_frames!==expected[10]||
                       dut.gap!==expected[11]||dut.cooldown!==expected[12])$fatal(1,"FSM mismatch frame %0d",frame_number);
                end
                if(event_valid)begin events++;$display("EVENT frame=%0d direction=%s",frame_number,event_dir?"RIGHT":"LEFT");end
                if((right_toggle!=old_right)!==(event_valid&&event_dir)||
                   (left_toggle!=old_left)!==(event_valid&&!event_dir))$fatal(1,"direction toggle mismatch");
                old_right=right_toggle;old_left=left_toggle;
                @(negedge clk);if(event_valid)$fatal(1,"event is not a one-cycle pulse");
                frame_number++;
            end
        end
        // Aborted collection / capture disable must rewarm without toggling.
        frame_start=1;@(negedge clk);frame_start=0;block_valid=1;block_index=0;block_mean=63;
        @(negedge clk);block_valid=0;enable=0;repeat(4)@(negedge clk);enable=1;
        if(dut.have_previous||right_toggle!=old_right||left_toggle!=old_left)$fatal(1,"disable emitted or retained partial baseline");
        $display("PASS WAVE GOLDEN frames=%0d events=%0d %s",frame_number,events,file_path);$finish;
    end
    initial begin #100000000;$fatal(1,"global timeout");end
endmodule
