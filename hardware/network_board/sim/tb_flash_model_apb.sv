module tb_flash_model_apb;
    logic clk = 0;
    logic reset = 1;
    logic psel = 0, penable = 0, pwrite = 0;
    logic [11:0] paddr = 0;
    logic [31:0] pwdata = 0, prdata;
    logic pready, pslverr;
    logic flash_cs_n, flash_clk, flash_mosi, flash_miso = 0;
    logic [7:0] flash_mem [0:255];
    logic [31:0] command_capture;
    integer command_bits = 0;
    integer byte_index = 0;
    integer data_bit = 7;
    logic command_seen = 0;
    logic [31:0] value0, value1, readback;
    integer i;

    always #5 clk = ~clk;

    flash_model_apb #(.HALF_PERIOD_CYCLES(4)) dut (
        .clk, .reset, .psel, .penable, .pwrite, .paddr, .pwdata,
        .prdata, .pready, .pslverr, .flash_cs_n, .flash_clk,
        .flash_mosi, .flash_miso
    );

    always @(posedge flash_clk or posedge flash_cs_n) begin
        if (flash_cs_n) begin
            command_capture = 0;
            command_bits = 0;
            command_seen = 0;
            byte_index = 0;
            data_bit = 7;
            flash_miso = 0;
        end else begin
            if (!command_seen) begin
                command_capture = {command_capture[30:0], flash_mosi};
                command_bits = command_bits + 1;
                if (command_bits == 32) begin
                    if (command_capture !== 32'h03123456)
                        $fatal(1, "SPI command/address bit order wrong: %08x", command_capture);
                    command_seen = 1;
                end
            end
        end
    end

    always @(negedge flash_clk) begin
        if (!flash_cs_n && command_seen) begin
            flash_miso = flash_mem[byte_index] >> data_bit;
            if (data_bit == 0) begin
                data_bit = 7;
                byte_index = byte_index + 1;
            end else data_bit = data_bit - 1;
        end
    end

    task automatic apb_write(input logic [11:0] address, input logic [31:0] value);
        begin
            @(negedge clk);
            psel = 1; penable = 1; pwrite = 1; paddr = address; pwdata = value;
            @(posedge clk);
            if (!pready || pslverr) $fatal(1, "APB write failed at %03x", address);
            @(negedge clk);
            psel = 0; penable = 0; pwrite = 0;
        end
    endtask

    task automatic apb_read(input logic [11:0] address, output logic [31:0] value);
        begin
            @(negedge clk);
            psel = 1; penable = 1; pwrite = 0; paddr = address;
            #1 value = prdata;
            @(posedge clk);
            if (!pready || pslverr) $fatal(1, "APB read failed at %03x", address);
            @(negedge clk);
            psel = 0; penable = 0;
        end
    endtask

    task automatic wait_valid;
        integer cycles;
        logic [31:0] status;
        begin
            cycles = 0;
            status = 0;
            while (!status[1] && cycles < 300) begin
                apb_read(12'h00c, status);
                cycles = cycles + 1;
            end
            if (!status[1]) $fatal(1, "SPI word-valid timeout");
        end
    endtask

    initial begin
        for (i = 0; i < 256; i = i + 1) flash_mem[i] = 8'hff;
        flash_mem[0] = 8'h11; flash_mem[1] = 8'h22;
        flash_mem[2] = 8'h33; flash_mem[3] = 8'h44;
        flash_mem[4] = 8'h55; flash_mem[5] = 8'h66;
        flash_mem[6] = 8'h77; flash_mem[7] = 8'h88;
        repeat (4) @(posedge clk);
        reset = 0;

        apb_write(12'h004, 32'h00123456);
        apb_write(12'h000, 32'h1);
        wait_valid();
        if (!command_seen || command_bits != 32) $fatal(1, "command not fully transmitted");
        repeat (40) @(posedge clk);
        if (flash_clk !== 0 || flash_cs_n !== 0)
            $fatal(1, "SPI did not pause low with CS asserted");
        apb_read(12'h008, value0);
        if (value0 !== 32'h44332211) $fatal(1, "LE word 0 wrong: %08x", value0);
        apb_read(12'h004, readback);
        if (readback !== 32'h0012345a) $fatal(1, "address did not advance by one word: %08x", readback);

        wait_valid();
        apb_read(12'h008, value1);
        if (value1 !== 32'h88776655) $fatal(1, "LE word 1 wrong: %08x", value1);
        apb_write(12'h000, 32'h2);
        apb_read(12'h00c, readback);
        if (readback[0] || !readback[2] || flash_cs_n !== 1 || flash_clk !== 0)
            $fatal(1, "stop did not close transaction");

        apb_write(12'h004, 32'h00123456);
        apb_write(12'h000, 32'h1);
        repeat (12) @(posedge flash_clk);
        reset = 1;
        repeat (2) @(posedge clk);
        if (flash_cs_n !== 1 || flash_clk !== 0) $fatal(1, "reset failed to cancel SPI/CS");
        reset = 0;
        apb_read(12'h00c, readback);
        if (readback[0] || readback[1]) $fatal(1, "reset did not clear active/valid status");

        $display("tb_flash_model_apb PASS");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "testbench watchdog");
    end
endmodule
