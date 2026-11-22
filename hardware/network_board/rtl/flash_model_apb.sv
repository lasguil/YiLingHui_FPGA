// Read-only SPI mode-0 bridge for the model flash. The CPU owns transaction
// boundaries through APB and consumes one little-endian 32-bit word at a time.
module flash_model_apb #(
    parameter integer HALF_PERIOD_CYCLES = 10
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [11:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,
    output logic        flash_cs_n,
    output logic        flash_clk,
    output logic        flash_mosi,
    input  logic        flash_miso
);
    localparam logic [11:0] REG_CTRL   = 12'h000;
    localparam logic [11:0] REG_ADDR   = 12'h004;
    localparam logic [11:0] REG_DATA   = 12'h008;
    localparam logic [11:0] REG_STATUS = 12'h00c;

    typedef enum logic [2:0] {IDLE, COMMAND, READ_DATA, WORD_END, PAUSED} state_t;
    state_t state;

    logic [23:0] address_q;
    logic [31:0] command_q;
    logic [5:0] command_bit;
    logic [2:0] bit_index;
    logic [1:0] byte_index;
    logic [7:0] rx_shift;
    logic [31:0] data_q;
    logic [3:0] divider;
    logic busy_q, valid_q, done_q, fault_q;
    (* async_reg = "true", syn_preserve = 1 *) logic miso_meta_q;
    (* async_reg = "true", syn_preserve = 1 *) logic miso_sync_q;

    wire apb_access = psel && penable;
    wire [11:0] reg_addr = {paddr[11:2], 2'b00};
    wire data_read = apb_access && !pwrite && (reg_addr == REG_DATA);
    wire ctrl_write = apb_access && pwrite && (reg_addr == REG_CTRL);
    wire [7:0] sampled_byte = {rx_shift[6:0], miso_sync_q};

    always_ff @(posedge clk) begin
        if (reset) begin
            miso_meta_q <= 1'b1;
            miso_sync_q <= 1'b1;
        end else begin
            miso_meta_q <= flash_miso;
            miso_sync_q <= miso_meta_q;
        end
    end

    always_comb begin
        pready = 1'b1;
        pslverr = 1'b0;
        prdata = 32'h0;
        case (reg_addr)
            REG_CTRL:   prdata = {31'd0, busy_q};
            REG_ADDR:   prdata = {8'd0, address_q};
            REG_DATA:   prdata = data_q;
            REG_STATUS: prdata = {28'd0, fault_q, done_q, valid_q, busy_q};
            default:    pslverr = apb_access;
        endcase
        flash_mosi = command_q[31];
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            address_q <= 24'd0;
            command_q <= 32'd0;
            command_bit <= 6'd0;
            bit_index <= 3'd0;
            byte_index <= 2'd0;
            rx_shift <= 8'd0;
            data_q <= 32'd0;
            divider <= 4'd0;
            flash_cs_n <= 1'b1;
            flash_clk <= 1'b0;
            busy_q <= 1'b0;
            valid_q <= 1'b0;
            done_q <= 1'b0;
            fault_q <= 1'b0;
        end else begin
            if (ctrl_write && pwdata[1]) begin
                state <= IDLE;
                flash_cs_n <= 1'b1;
                flash_clk <= 1'b0;
                divider <= 4'd0;
                busy_q <= 1'b0;
                valid_q <= 1'b0;
                done_q <= 1'b1;
            end else if (ctrl_write && pwdata[0]) begin
                if (state == IDLE) begin
                    state <= COMMAND;
                    flash_cs_n <= 1'b0;
                    flash_clk <= 1'b0;
                    command_q <= {8'h03, address_q};
                    command_bit <= 6'd0;
                    bit_index <= 3'd0;
                    byte_index <= 2'd0;
                    divider <= 4'd0;
                    busy_q <= 1'b1;
                    valid_q <= 1'b0;
                    done_q <= 1'b0;
                    fault_q <= 1'b0;
                end else begin
                    fault_q <= 1'b1;
                end
            end else begin
                if (apb_access && pwrite && (reg_addr == REG_ADDR)) begin
                    if (state == IDLE) address_q <= pwdata[23:0];
                    else fault_q <= 1'b1;
                end

                if (data_read && state == PAUSED && valid_q) begin
                    valid_q <= 1'b0;
                    address_q <= address_q + 24'd4;
                    byte_index <= 2'd0;
                    bit_index <= 3'd0;
                    state <= READ_DATA;
                end

                if ((state == COMMAND || state == READ_DATA || state == WORD_END)
                    && !valid_q) begin
                    if (divider == HALF_PERIOD_CYCLES - 1) begin
                        divider <= 4'd0;
                        if (!flash_clk) begin
                            flash_clk <= 1'b1;
                            if (state == READ_DATA) begin
                                rx_shift <= sampled_byte;
                                if (bit_index == 3'd7) begin
                                    data_q <= {sampled_byte, data_q[31:8]};
                                    bit_index <= 3'd0;
                                    if (byte_index == 2'd3) state <= WORD_END;
                                    else byte_index <= byte_index + 2'd1;
                                end else bit_index <= bit_index + 3'd1;
                            end
                        end else begin
                            flash_clk <= 1'b0;
                            if (state == COMMAND) begin
                                command_q <= {command_q[30:0], 1'b0};
                                if (command_bit == 6'd31) begin
                                    state <= READ_DATA;
                                    byte_index <= 2'd0;
                                    bit_index <= 3'd0;
                                    rx_shift <= 8'd0;
                                end else command_bit <= command_bit + 6'd1;
                            end else if (state == WORD_END) begin
                                valid_q <= 1'b1;
                                state <= PAUSED;
                            end
                        end
                    end else divider <= divider + 4'd1;
                end else divider <= 4'd0;
            end
        end
    end
endmodule
