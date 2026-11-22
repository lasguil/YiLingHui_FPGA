`timescale 1ns/1ps
module tb_gesture_uart;
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1;
    logic psel = 0, penable = 0, pwrite = 0;
    logic [11:0] paddr = 0;
    logic [31:0] pwdata = 0, prdata;
    logic pready, pslverr;
    logic uart_rx = 1;
    logic uart_tx;
    localparam int DEPTH = 64;

    gesture_uart dut (.*);

    task automatic apb_write(input logic [11:0] addr, input logic [31:0] data,
                             output bit waited, output bit err);
        int cycles;
        begin
            waited = 0;
            @(negedge clk);
            psel = 1; penable = 0; pwrite = 1; paddr = addr; pwdata = data;
            @(negedge clk);
            penable = 1;
            cycles = 0;
            while (1) begin
                @(posedge clk);
                if (pready) begin err = pslverr; break; end
                waited = 1;
                cycles++;
                if (cycles > 20000) $fatal(1, "APB write timeout addr=%03x", addr);
            end
            @(negedge clk); psel = 0; penable = 0; pwrite = 0;
        end
    endtask

    task automatic apb_read(input logic [11:0] addr, output logic [31:0] data,
                            output bit err);
        int cycles;
        begin
            @(negedge clk);
            psel = 1; penable = 0; pwrite = 0; paddr = addr; pwdata = 0;
            @(negedge clk);
            penable = 1;
            cycles = 0;
            while (1) begin
                @(posedge clk);
                if (pready) begin data = prdata; err = pslverr; break; end
                cycles++;
                if (cycles > 20000) $fatal(1, "APB read timeout addr=%03x", addr);
            end
            @(negedge clk); psel = 0; penable = 0;
        end
    endtask

    task automatic tx_expect(input byte expected, input int div);
        byte got;
        begin
            @(negedge uart_tx);
            repeat (div/2) @(posedge clk);
            if (uart_tx !== 1'b0) $fatal(1, "TX start bit not low");
            got = 0;
            for (int i = 0; i < 8; i++) begin
                repeat (div) @(posedge clk);
                got[i] = uart_tx;
            end
            repeat (div) @(posedge clk);
            if (uart_tx !== 1'b1) $fatal(1, "TX stop bit not high byte=%02x", expected);
            if (got !== expected)
                $fatal(1, "TX data mismatch got=%02x expected=%02x", got, expected);
        end
    endtask

    task automatic rx_send(input byte value, input int bit_cycles,
                           input bit good_stop);
        begin
            // Vary the start edge across system-clock phases while preserving
            // the remote UART's bit period for the rest of the frame.
            #(1 + $urandom_range(0, 8)); uart_rx = 0;
            #(bit_cycles * 10);
            for (int i = 0; i < 8; i++) begin
                uart_rx = value[i];
                #(bit_cycles * 10);
            end
            uart_rx = good_stop ? 1'b1 : 1'b0;
            #(bit_cycles * 10);
            uart_rx = 1;
            #(bit_cycles * 10);
        end
    endtask

    task automatic check_status(input logic [7:0] mask, input logic [7:0] value);
        logic [31:0] status;
        bit err;
        begin
            apb_read(12'h008, status, err);
            if (err || ((status[7:0] & mask) !== value))
                $fatal(1, "STATUS mismatch status=%02x mask=%02x expected=%02x err=%0d",
                       status[7:0], mask, value, err);
        end
    endtask

    initial begin : test
        logic [31:0] d;
        logic [7:0] partial;
        bit err, waited, tx_waited;
        int div;
        #37; reset = 0;
        apb_read(12'h00c, d, err);
        if (err || d[15:0] != 868) $fatal(1, "default divider mismatch %0d", d[15:0]);
        if (100_000_000.0 / 868.0 < 115200.0 ||
            100_000_000.0 / 868.0 > 115216.0)
            $fatal(1, "default baud error outside expected range");

        // Faster simulation baud for stress cases; illegal divisor is rejected.
        apb_write(12'h00c, 32'd3, waited, err);
        if (!err) $fatal(1, "divider < 4 was accepted");
        apb_write(12'h00c, 32'd50, waited, err);
        if (err) $fatal(1, "idle divider write rejected");
        div = 50;

        // Queue and serialize 66 distinct bytes. The first byte leaves the
        // FIFO as soon as TX accepts it; the 66th APB write must then wait for
        // the next slot while the monitor verifies ordering and every bit.
        tx_waited = 0;
        fork
            begin
                for (int i = 0; i < DEPTH+2; i++) begin
                    apb_write(12'h000, i[7:0], waited, err);
                    if (err) $fatal(1, "TXDATA write returned PSLVERR");
                    if (i == DEPTH+1 && waited) tx_waited = 1;
                    if ((i % 7) == 2) repeat ($urandom_range(0, 5)) @(negedge clk);
                end
            end
            begin
                for (int i = 0; i < DEPTH+2; i++) tx_expect(i[7:0], div);
            end
        join
        if (!tx_waited) $fatal(1, "TX FIFO full did not backpressure APB");
        repeat (div+2) @(negedge clk); // finish stop hold and return to IDLE
        check_status(8'h07, 8'h01); // empty, not full, not busy

        // Busy divider protection, then RX at -2% and +2% remote bit periods.
        fork
            begin
                apb_write(12'h000, 32'h000000a6, waited, err);
                if (err) $fatal(1, "TX queue write failed");
                apb_write(12'h00c, 32'd60, waited, err);
                if (!err) $fatal(1, "divider changed with TX busy/FIFO nonempty");
            end
            begin tx_expect(8'ha6, div); end
        join
        rx_send(8'hff, 49, 1); // ~+2.04% relative to divisor 50
        rx_send(8'h00, 51, 1); // ~-1.96%
        apb_read(12'h004, d, err);
        if (err || d[7:0] != 8'hff) $fatal(1, "RX +2%% byte mismatch %02x", d[7:0]);
        apb_read(12'h004, d, err);
        if (err || d[7:0] != 8'h00) $fatal(1, "RX -2%% byte mismatch %02x", d[7:0]);
        apb_read(12'h004, d, err);
        if (!err || d != 0) $fatal(1, "empty RXDATA must return PSLVERR and zero");

        // RX full and overflow at 65th byte; all retained entries must preserve order.
        for (int i = 0; i < DEPTH+1; i++) rx_send((8'h40 + i), 50, 1);
        check_status(8'h38, 8'h30); // rx_full + sticky overflow

        // A simultaneous W1C and newly dropped stop byte must leave overflow
        // sticky set (the error event has priority over the software clear).
        fork
            rx_send(8'hA5, 50, 1);
            begin
                @(negedge clk);
                while (!((dut.rx_state_q == 2'd3) &&
                         (dut.rx_timer_q == 16'd1) && dut.rx_full))
                    @(negedge clk);
                psel = 1; penable = 0; pwrite = 1;
                paddr = 12'h010; pwdata = 32'h00000020;
                @(negedge clk); penable = 1;
                @(posedge clk);
                if (!pready || pslverr) $fatal(1, "coincident W1C APB transfer failed");
                @(negedge clk); psel = 0; penable = 0; pwrite = 0;
            end
        join
        check_status(8'h20, 8'h20);
        for (int i = 0; i < DEPTH; i++) begin
            apb_read(12'h004, d, err);
            if (err || d[7:0] !== (8'h40 + i))
                $fatal(1, "RX FIFO order mismatch idx=%0d got=%02x", i, d[7:0]);
        end
        check_status(8'h38, 8'h28); // RX empty, overflow sticky

        // Framing and break are sticky; W1C clears them independently.
        rx_send(8'h00, 50, 0);
        check_status(8'he0, 8'he0);
        apb_write(12'h010, 32'h000000e0, waited, err);
        if (err) $fatal(1, "W1C rejected");
        check_status(8'he0, 8'h00);

        // Baud write is also prohibited while RX is in flight.
        @(negedge clk); uart_rx = 0;
        // Attempt during the synchronizer-to-state-machine start-detect window.
        apb_write(12'h00c, 32'd52, waited, err);
        if (!err) $fatal(1, "divider changed while RX start was arriving");
        uart_rx = 1;
        repeat (100) @(negedge clk);

        // Reset in the middle of RX data flushes the partial frame.
        partial = 8'hA6;
        @(negedge clk); uart_rx = 0;
        repeat (div) @(negedge clk);
        for (int i = 0; i < 3; i++) begin
            uart_rx = partial[i];
            repeat (div) @(negedge clk);
        end
        @(negedge clk); reset = 1; uart_rx = 0;
        repeat (4) @(negedge clk);
        reset = 0; uart_rx = 1;
        repeat (3*div) @(negedge clk);
        check_status(8'hff, 8'h09);

        // Reset in the middle of TX restores idle-high and prevents stale
        // bytes/errors from appearing after recovery.
        apb_write(12'h000, 32'h0000005a, waited, err);
        if (err) $fatal(1, "TX write before reset failed");
        wait (uart_tx == 0);
        repeat (80) @(negedge clk);
        @(negedge clk); reset = 1;
        repeat (4) @(negedge clk);
        if (uart_tx !== 1'b1) $fatal(1, "TX reset level not idle high");
        reset = 0; uart_rx = 1;
        repeat (3*div) @(negedge clk);
        check_status(8'hff, 8'h09); // TX/RX empty and no busy/sticky bits
        apb_read(12'h004, d, err);
        if (!err) $fatal(1, "reset left stale RX byte");

        $display("PASS tb_gesture_uart: default baud, TX timing/order/backpressure, RX +/-2%%, FIFO boundaries, errors/W1C, mid-transfer reset");
        $finish;
    end

    initial begin
        #200_000_000;
        $fatal(1, "global simulation timeout");
    end
endmodule
