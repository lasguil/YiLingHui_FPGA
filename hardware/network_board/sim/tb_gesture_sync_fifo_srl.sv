`timescale 1ns/1ps

module gesture_sync_fifo_pair_check #(
    parameter int REGISTER_BITS = 48,
    parameter int DATA_W = 128,
    parameter int ADDR_W = 5
) (
    input logic clk,
    input logic reset,
    output logic done
);
    logic random_reset = 0;
    wire fifo_reset = reset | random_reset;
    localparam int DEPTH = 1 << ADDR_W;
    logic wr_en = 0;
    logic rd_en = 0;
    logic [DATA_W-1:0] wr_data = '0;
    wire full_ref, empty_ref, full_srl, empty_srl;
    wire [ADDR_W:0] count_ref, count_srl;
    wire [DATA_W-1:0] rd_ref, rd_srl;
    logic [DATA_W-1:0] expected [0:65535];
    int head = 0, tail = 0, model_count = 0;
    int cycle = 0;

    gesture_sync_fifo_baseline #(.DATA_W(DATA_W), .ADDR_W(ADDR_W), .REGISTER_BITS(REGISTER_BITS)) u_ref (
        .clk, .reset(fifo_reset), .wr_en, .wr_data, .full(full_ref), .rd_en, .rd_data(rd_ref), .empty(empty_ref), .count(count_ref)
    );
    gesture_sync_fifo #(.DATA_W(DATA_W), .ADDR_W(ADDR_W), .REGISTER_BITS(REGISTER_BITS)) u_srl (
        .clk, .reset(fifo_reset), .wr_en, .wr_data, .full(full_srl), .rd_en, .rd_data(rd_srl), .empty(empty_srl), .count(count_srl)
    );

    always @(posedge clk) begin : scoreboard
        logic accept_write, accept_read;
        if (fifo_reset) begin
            model_count = 0;
            head = 0;
            tail = 0;
        end else begin
            if (count_ref !== count_srl || full_ref !== full_srl || empty_ref !== empty_srl)
                $fatal(1, "REGISTER_BITS=%0d cycle=%0d flags/count differ ref=%0d/%b/%b srl=%0d/%b/%b",
                    REGISTER_BITS, cycle, count_ref, full_ref, empty_ref, count_srl, full_srl, empty_srl);
            if (model_count != 0 && rd_en) begin
                if (rd_ref !== expected[head] || rd_srl !== expected[head])
                    $fatal(1, "REGISTER_BITS=%0d cycle=%0d data mismatch", REGISTER_BITS, cycle);
            end
            accept_write = wr_en && (model_count != DEPTH);
            accept_read = rd_en && (model_count != 0);
            if (accept_write) begin
                expected[tail] = wr_data;
                tail = tail + 1;
            end
            if (accept_read) begin
                head = head + 1;
            end
            case ({accept_write, accept_read})
                2'b10: model_count = model_count + 1;
                2'b01: model_count = model_count - 1;
                default: ;
            endcase
            cycle = cycle + 1;
            #1;
            if (count_ref !== model_count || count_srl !== model_count)
                $fatal(1, "REGISTER_BITS=%0d cycle=%0d scoreboard count=%0d ref=%0d srl=%0d",
                    REGISTER_BITS, cycle, model_count, count_ref, count_srl);
        end
    end

    task automatic step(input bit w, input bit r);
        @(negedge clk);
        wr_en = w;
        rd_en = r;
        for (int k = 0; k < DATA_W; k += 32) wr_data[k +: 32] = $urandom;
    endtask

    initial begin
        done = 0;
        wait (!reset);
        repeat (DEPTH) step(1, 0);
        step(1, 0); // reject a push while full
        step(1, 1); // full push+pop still rejects the push
        repeat (DEPTH-1) step(0, 1);
        step(0, 1); // empty pop is ignored
        repeat (80) step(1, 1);
        repeat (3000) begin
            bit w, r;
            w = ($urandom_range(0, 3) != 0);
            r = ($urandom_range(0, 3) != 0);
            step(w, r);
            if ($urandom_range(0, 199) == 0) begin
                @(negedge clk);
                random_reset = 1;
                wr_en = 0;
                rd_en = 0;
                @(negedge clk);
                random_reset = 0;
            end
        end
        step(0, 0);
        done = 1;
    end
endmodule

module tb_gesture_sync_fifo_srl;
    logic clk = 0;
    logic reset = 1;
    wire done48, done80;
    always #5 clk = ~clk;
    gesture_sync_fifo_pair_check #(.REGISTER_BITS(48)) c48 (.clk, .reset, .done(done48));
    gesture_sync_fifo_pair_check #(.REGISTER_BITS(80)) c80 (.clk, .reset, .done(done80));
    initial begin
        repeat (3) @(negedge clk);
        reset = 0;
        wait (done48 && done80);
        $display("PASS: paired baseline/SRL FIFO checks (128x32, REGISTER_BITS=48 and 80)");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "simulation timeout");
    end
endmodule
