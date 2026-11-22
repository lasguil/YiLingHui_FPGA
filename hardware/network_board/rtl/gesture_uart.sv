// Standalone APB UART for gesture-result transport.  Kept separate from the
// Sapphire diagnostic UART.  APB, TX, and RX state all run from core_clk.
module gesture_uart #(
    parameter integer FIFO_DEPTH = 64,
    parameter integer FIFO_ADDR_W = 6,
    parameter logic [15:0] DEFAULT_BAUD_DIV = 16'd868
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
    input  logic        uart_rx,
    output logic        uart_tx
);
    localparam integer COUNT_W = FIFO_ADDR_W + 1;
    localparam logic [11:0] REG_TXDATA = 12'h000;
    localparam logic [11:0] REG_RXDATA = 12'h004;
    localparam logic [11:0] REG_STATUS = 12'h008;
    localparam logic [11:0] REG_BAUD   = 12'h00c;
    localparam logic [11:0] REG_W1C    = 12'h010;

    logic [7:0] tx_mem [0:FIFO_DEPTH-1];
    logic [7:0] rx_mem [0:FIFO_DEPTH-1];
    logic [FIFO_ADDR_W-1:0] tx_wptr_q, tx_rptr_q;
    logic [FIFO_ADDR_W-1:0] rx_wptr_q, rx_rptr_q;
    logic [COUNT_W-1:0] tx_count_q, rx_count_q;
    wire tx_empty = (tx_count_q == 0);
    wire rx_empty = (rx_count_q == 0);
    wire tx_full = (tx_count_q == FIFO_DEPTH);
    wire rx_full = (rx_count_q == FIFO_DEPTH);

    logic [15:0] baud_div_q;
    logic rx_overflow_q, frame_error_q, break_q;

    logic [1:0] tx_state_q;
    localparam logic [1:0] TX_IDLE = 2'd0, TX_START = 2'd1,
                           TX_DATA = 2'd2, TX_STOP = 2'd3;
    wire tx_pop = (tx_state_q == TX_IDLE) && !tx_empty;
    logic [15:0] tx_timer_q;
    logic [2:0] tx_bit_q;
    logic [7:0] tx_shift_q;

    (* async_reg = "true" *) logic rx_meta_q, rx_sync_q;
    logic [1:0] rx_state_q;
    localparam logic [1:0] RX_IDLE = 2'd0, RX_START = 2'd1,
                           RX_DATA = 2'd2, RX_STOP = 2'd3;
    logic [15:0] rx_timer_q;
    logic [2:0] rx_bit_q;
    logic [7:0] rx_shift_q;

    logic apb_accept;
    logic apb_err;
    logic [31:0] apb_rdata;
    logic tx_push, rx_pop, rx_push;
    logic tx_write_allowed;
    logic rx_read_allowed;
    logic baud_write_allowed;
    wire rx_stop_sample = (rx_state_q == RX_STOP) && (rx_timer_q == 16'd0);
    wire rx_store = rx_stop_sample && rx_sync_q;
    wire rx_can_store = !rx_full || rx_pop;

    wire tx_idle_all = (tx_state_q == TX_IDLE) && tx_empty;
    wire rx_idle_all = (rx_state_q == RX_IDLE) && rx_empty;
    wire baud_idle = tx_idle_all && rx_idle_all && rx_meta_q && rx_sync_q;

    // The pointer wrap logic requires a power-of-two FIFO whose depth matches
    // the address width. Keep this check out of synthesis logic.
    // synthesis translate_off
    initial begin
        if (FIFO_DEPTH != (1 << FIFO_ADDR_W))
            $fatal(1, "gesture_uart FIFO_DEPTH must equal 2**FIFO_ADDR_W");
    end
    // synthesis translate_on

    always_comb begin
        apb_err = 1'b0;
        apb_rdata = 32'd0;
        tx_write_allowed = 1'b1;
        rx_read_allowed = 1'b1;
        baud_write_allowed = 1'b1;

        case (paddr)
            REG_TXDATA: begin
                apb_rdata = {24'd0, tx_mem[tx_rptr_q]};
                if (pwrite && tx_full && !tx_pop) tx_write_allowed = 1'b0;
                if (!pwrite) apb_err = 1'b1;
            end
            REG_RXDATA: begin
                apb_rdata = rx_empty ? 32'd0 : {24'd0, rx_mem[rx_rptr_q]};
                if (pwrite) apb_err = 1'b1;
                else if (rx_empty) apb_err = 1'b1;
            end
            REG_STATUS: begin
                apb_rdata = {24'd0, break_q, frame_error_q, rx_overflow_q,
                             rx_full, rx_empty, (tx_state_q != TX_IDLE),
                             tx_full, tx_empty};
                if (pwrite) apb_err = 1'b1;
            end
            REG_BAUD: begin
                apb_rdata = {16'd0, baud_div_q};
                if (pwrite && !baud_idle) begin
                    baud_write_allowed = 1'b0;
                    apb_err = 1'b1;
                end else if (pwrite && pwdata[15:0] < 16'd4) begin
                    baud_write_allowed = 1'b0;
                    apb_err = 1'b1;
                end
            end
            REG_W1C: begin
                apb_rdata = {24'd0, break_q, frame_error_q, rx_overflow_q, 5'd0};
                if (!pwrite) apb_err = 1'b1;
            end
            default: apb_err = 1'b1;
        endcase

        pready = 1'b1;
        if (psel && penable && pwrite && (paddr == REG_TXDATA) && !tx_write_allowed)
            pready = 1'b0;
        pslverr = psel && penable && pready && apb_err;
        prdata = apb_rdata;
        apb_accept = psel && penable && pready && !apb_err;
        tx_push = apb_accept && pwrite && (paddr == REG_TXDATA);
        rx_pop = apb_accept && !pwrite && (paddr == REG_RXDATA);
    end

    // RX enqueue is a one-cycle event at the middle of a valid stop bit.
    assign rx_push = rx_store && rx_can_store;

    always_ff @(posedge clk) begin
        if (reset) begin
            tx_wptr_q <= '0;
            tx_rptr_q <= '0;
            tx_count_q <= '0;
            rx_wptr_q <= '0;
            rx_rptr_q <= '0;
            rx_count_q <= '0;
            baud_div_q <= DEFAULT_BAUD_DIV;
            rx_overflow_q <= 1'b0;
            frame_error_q <= 1'b0;
            break_q <= 1'b0;
        end else begin
            if (tx_push) begin
                tx_mem[tx_wptr_q] <= pwdata[7:0];
                tx_wptr_q <= tx_wptr_q + 1'b1;
            end
            if (tx_pop) tx_rptr_q <= tx_rptr_q + 1'b1;
            case ({tx_push, tx_pop})
                2'b10: tx_count_q <= tx_count_q + 1'b1;
                2'b01: tx_count_q <= tx_count_q - 1'b1;
                default: ;
            endcase

            if (rx_push) begin
                rx_mem[rx_wptr_q] <= rx_shift_q;
                rx_wptr_q <= rx_wptr_q + 1'b1;
            end
            if (rx_pop) rx_rptr_q <= rx_rptr_q + 1'b1;
            case ({rx_push, rx_pop})
                2'b10: rx_count_q <= rx_count_q + 1'b1;
                2'b01: rx_count_q <= rx_count_q - 1'b1;
                default: ;
            endcase

            if (apb_accept && pwrite && (paddr == REG_BAUD))
                baud_div_q <= pwdata[15:0];
            if (apb_accept && pwrite && (paddr == REG_W1C)) begin
                if (pwdata[5]) rx_overflow_q <= 1'b0;
                if (pwdata[6]) frame_error_q <= 1'b0;
                if (pwdata[7]) break_q <= 1'b0;
            end
            // A new error event wins over a simultaneous W1C clear.
            if (rx_store && !rx_can_store) rx_overflow_q <= 1'b1;
            if (rx_stop_sample && !rx_sync_q) begin
                frame_error_q <= 1'b1;
                if (rx_shift_q == 8'h00) break_q <= 1'b1;
            end
        end
    end

    // TX: 8N1, LSB first. A FIFO entry is removed only when the transmitter
    // accepts it in IDLE, so APB backpressure never loses a byte.
    always_ff @(posedge clk) begin
        if (reset) begin
            tx_state_q <= TX_IDLE;
            tx_timer_q <= 16'd0;
            tx_bit_q <= 3'd0;
            tx_shift_q <= 8'd0;
            uart_tx <= 1'b1;
        end else begin
            case (tx_state_q)
                TX_IDLE: begin
                    uart_tx <= 1'b1;
                    if (!tx_empty) begin
                        tx_shift_q <= tx_mem[tx_rptr_q];
                        uart_tx <= 1'b0;
                        tx_timer_q <= baud_div_q - 1'b1;
                        tx_bit_q <= 3'd0;
                        tx_state_q <= TX_START;
                    end
                end
                TX_START: begin
                    if (tx_timer_q == 0) begin
                        uart_tx <= tx_shift_q[0];
                        tx_timer_q <= baud_div_q - 1'b1;
                        tx_state_q <= TX_DATA;
                    end else tx_timer_q <= tx_timer_q - 1'b1;
                end
                TX_DATA: begin
                    if (tx_timer_q == 0) begin
                        if (tx_bit_q == 3'd7) begin
                            uart_tx <= 1'b1;
                            tx_timer_q <= baud_div_q - 1'b1;
                            tx_state_q <= TX_STOP;
                        end else begin
                            tx_shift_q <= {1'b0, tx_shift_q[7:1]};
                            tx_bit_q <= tx_bit_q + 1'b1;
                            uart_tx <= tx_shift_q[1];
                            tx_timer_q <= baud_div_q - 1'b1;
                        end
                    end else tx_timer_q <= tx_timer_q - 1'b1;
                end
                TX_STOP: begin
                    if (tx_timer_q == 0) begin
                        uart_tx <= 1'b1;
                        tx_state_q <= TX_IDLE;
                    end else tx_timer_q <= tx_timer_q - 1'b1;
                end
                default: begin
                    tx_state_q <= TX_IDLE;
                    uart_tx <= 1'b1;
                end
            endcase
        end
    end

    // RX: two-flop synchronizer, half-bit start validation, then center
    // sampling of each data and stop bit. The sampler tolerates ordinary UART
    // baud mismatch; tests exercise +/-2% remote baud.
    always_ff @(posedge clk) begin
        if (reset) begin
            rx_meta_q <= 1'b1;
            rx_sync_q <= 1'b1;
            rx_state_q <= RX_IDLE;
            rx_timer_q <= 16'd0;
            rx_bit_q <= 3'd0;
            rx_shift_q <= 8'd0;
        end else begin
            rx_meta_q <= uart_rx;
            rx_sync_q <= rx_meta_q;
            case (rx_state_q)
                RX_IDLE: if (!rx_sync_q) begin
                    rx_timer_q <= (baud_div_q >> 1) - 1'b1;
                    rx_state_q <= RX_START;
                end
                RX_START: begin
                    if (rx_timer_q == 0) begin
                        if (!rx_sync_q) begin
                            rx_timer_q <= baud_div_q - 1'b1;
                            rx_bit_q <= 3'd0;
                            rx_shift_q <= 8'd0;
                            rx_state_q <= RX_DATA;
                        end else rx_state_q <= RX_IDLE;
                    end else rx_timer_q <= rx_timer_q - 1'b1;
                end
                RX_DATA: begin
                    if (rx_timer_q == 0) begin
                        rx_shift_q[rx_bit_q] <= rx_sync_q;
                        rx_timer_q <= baud_div_q - 1'b1;
                        if (rx_bit_q == 3'd7) rx_state_q <= RX_STOP;
                        else rx_bit_q <= rx_bit_q + 1'b1;
                    end else rx_timer_q <= rx_timer_q - 1'b1;
                end
                RX_STOP: begin
                    if (rx_timer_q == 0) rx_state_q <= RX_IDLE;
                    else rx_timer_q <= rx_timer_q - 1'b1;
                end
                default: rx_state_q <= RX_IDLE;
            endcase
        end
    end
endmodule
