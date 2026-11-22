`timescale 1ns/1ps
module tb_gesture_async_fifo;
    localparam int DW=25, AW=5, DEPTH=(1<<AW), N=5000;
    logic arst=1;
    logic wclk=0,rclk=0;
    logic wr_en=0,rd_en=0;
    logic [DW-1:0] wr_data=0,rd_data;
    logic full,empty;
    logic [DW-1:0] expected[$];
    logic held_prev=0;
    logic [DW-1:0] held_data=0;
    integer accepted_writes=0,accepted_reads=0;
    logic [31:0] rng_w=32'hd34db33f,rng_r=32'h9e3779b9;
    logic run_random=0;

    always #3.5 wclk=~wclk;
    always #5.5 rclk=~rclk;

    gesture_async_fifo #(.DATA_W(DW),.ADDR_W(AW)) dut(
        .arst,.wclk,.wr_en,.wr_data,.full,.rclk,.rd_en,.rd_data,.empty);

    // Scoreboard uses accepted handshakes only. Reads may be held active while
    // empty and writes may be held while full to check under/overflow guards.
    always @(posedge wclk) begin
        if(!arst && wr_en && !full) begin
            expected.push_back(wr_data);
            accepted_writes=accepted_writes+1;
        end
    end
    always @(posedge rclk) begin
        logic [DW-1:0] exp;
        if(!arst && held_prev && !empty && rd_data!==held_data)
            $fatal(1,"FWFT head changed while consumer stalled");
        held_prev<=!arst && !empty && !rd_en;
        if(!arst) held_data<=rd_data;
        if(!arst && rd_en && !empty) begin
            if(expected.size()==0) $fatal(1,"read accepted before scoreboard write");
            exp=expected.pop_front();
            if(rd_data!==exp)
                $fatal(1,"FIFO data mismatch read=%0d got=%h expected=%h",accepted_reads,rd_data,exp);
            accepted_reads=accepted_reads+1;
        end
    end

    initial begin
        repeat(8) @(negedge wclk);
        arst=0;
        wait(!dut.wreset && !dut.rreset);

        // Fill to the exact depth, hold an extra write against full, then
        // drain continuously. This checks exact full capacity and FWFT head.
        for(integer i=0;i<DEPTH+4;i++) begin
            @(negedge wclk);wr_en=1;wr_data=25'h100000+i;
        end
        @(negedge wclk);wr_en=0;
        wait(full===1'b1);
        if(expected.size()!=DEPTH) $fatal(1,"full asserted at occupancy %0d, expected %0d",expected.size(),DEPTH);
        repeat(5) begin @(negedge wclk);wr_en=1;wr_data=25'h1fffff; end
        @(negedge wclk);wr_en=0;
        repeat(3) @(negedge rclk);
        if(empty || rd_data!==expected[0]) $fatal(1,"FWFT head invalid after fill");
        @(negedge rclk);rd_en=1;
        wait(expected.size()==0);
        repeat(5) @(negedge rclk);rd_en=0;
        wait(empty===1'b1);
        if(!empty) $fatal(1,"empty did not assert after drain");

        // Concurrent randomized producer/consumer at unrelated clock rates
        // exercises repeated wrap, arbitrary stalls, and FWFT hold semantics.
        run_random=1;
        fork
            begin : producer
                integer sent;
                sent=0;
                while(sent<N) begin
                    @(negedge wclk);
                    rng_w={rng_w[30:0],rng_w[31]^rng_w[21]^rng_w[1]^rng_w[0]};
                    wr_en=(rng_w[2:0]!=3'b000);
                    wr_data=25'(sent ^ 25'h13579b);
                    @(posedge wclk);
                    if(wr_en && !full) sent=sent+1;
                end
                @(negedge wclk);wr_en=0;
            end
            begin : consumer
                integer got;
                got=0;
                while(got<N) begin
                    @(negedge rclk);
                    rng_r={rng_r[30:0],rng_r[31]^rng_r[22]^rng_r[2]^rng_r[0]};
                    rd_en=(rng_r[1:0]!=2'b00);
                    @(posedge rclk);
                    if(rd_en && !empty) got=got+1;
                end
                @(negedge rclk);rd_en=0;
            end
        join
        wait(empty===1'b1);
        repeat(6) @(negedge rclk);
        if(expected.size()!=0) $fatal(1,"scoreboard not empty: %0d",expected.size());
        if(accepted_reads!=accepted_writes) $fatal(1,"handshake counts differ writes=%0d reads=%0d",accepted_writes,accepted_reads);

        // Coordinated asynchronous reset clears visibility and pointer state;
        // stale RAM contents must not leak through after reset.
        @(negedge wclk);wr_en=1;wr_data=25'h0123456;
        @(negedge wclk);wr_en=0;
        repeat(4) @(negedge rclk);
        arst=1;
        expected.delete();
        rd_en=1;wr_en=1;
        repeat(5) @(negedge rclk);
        if(!empty) $fatal(1,"FIFO not empty during reset");
        arst=0;rd_en=0;wr_en=0;
        repeat(8) @(negedge rclk);
        if(!empty)
            $fatal(1,"stale FIFO data visible after coordinated reset");

        $display("PASS: async FIFO exact full/depth, FWFT stability, randomized dual-clock wrap/backpressure, and reset recovery; writes=%0d reads=%0d",accepted_writes,accepted_reads);
        $finish;
    end
    initial begin #5_000_000;$fatal(1,"async FIFO regression timeout");end
endmodule
