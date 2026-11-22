// CH9350L receive-only 115200 8N1 UART and APB byte FIFO.
// APB window is selected externally; paddr is the low 16-bit address.
module ch9350_uart_rx_csr #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer FIFO_DEPTH = 1024,
    parameter integer ENABLE_TX = 0
)(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        uart_rx,
    output wire        uart_tx,
    input  wire [15:0] paddr,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverror
);
    wire apb_access = psel && penable;
    wire apb_write = apb_access && pwrite;
    wire [5:0] reg_index = paddr[7:2]; // APB byte offsets are 0x600, 0x604, ...
    localparam integer DIVISOR = (CLK_HZ + 57_600) / 115_200;
    localparam integer HALF_DIV = DIVISOR / 2;
    localparam integer BAUD_W = (DIVISOR <= 2) ? 1 : $clog2(DIVISOR);
    localparam integer BREAK_CYCLES = CLK_HZ / 10_000; // 100 us, about one 115200-baud character
    localparam integer LOW_W = (BREAK_CYCLES <= 2) ? 1 : $clog2(BREAK_CYCLES+1);
    localparam integer PTR_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam integer COUNT_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH+1);

    reg tx_line;
    reg [9:0] tx_shift;
    reg [3:0] tx_bit;
    reg [BAUD_W-1:0] tx_baud;
    reg tx_busy;
    wire tx_write = ENABLE_TX && apb_write && reg_index==7 && !tx_busy;
    assign uart_tx = ENABLE_TX ? tx_line : 1'b1;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin tx_line<=1'b1;tx_shift<=10'h3ff;tx_bit<=0;tx_baud<=0;tx_busy<=0;end
        else if(ENABLE_TX)begin
            if(tx_write)begin
                tx_shift<={1'b1,pwdata[7:0],1'b0};tx_bit<=0;tx_baud<=DIVISOR-1;tx_busy<=1;tx_line<=1'b0;
            end else if(tx_busy)begin
                if(tx_baud==0)begin
                    tx_baud<=DIVISOR-1;
                    if(tx_bit==9)begin tx_line<=1'b1;tx_busy<=0;end
                    else begin tx_line<=tx_shift[1];tx_shift<={1'b1,tx_shift[9:1]};tx_bit<=tx_bit+1'b1;end
                end else tx_baud<=tx_baud-1'b1;
            end
        end else begin tx_line<=1'b1;tx_busy<=0;end
    end

    (* async_reg = "true", syn_preserve = 1 *) reg rx_meta, rx_sync;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin rx_meta <= 1'b1; rx_sync <= 1'b1; end
        else begin rx_meta <= uart_rx; rx_sync <= rx_meta; end
    end

    localparam [1:0] RX_IDLE=2'd0, RX_START=2'd1, RX_DATA=2'd2, RX_STOP=2'd3;
    reg [1:0] rx_state;
    reg [BAUD_W-1:0] baud_count;
    reg [2:0] bit_index;
    reg [7:0] rx_shift;
    reg rx_byte_valid;
    reg [7:0] rx_byte;
    reg [LOW_W-1:0] low_count;
    reg break_latched;
    reg framing_error;
    reg [31:0] framing_count;
    reg [31:0] byte_count;
    wire break_now = (low_count >= BREAK_CYCLES);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rx_state<=RX_IDLE; baud_count<=0; bit_index<=0; rx_shift<=0;
            rx_byte_valid<=0; rx_byte<=0; low_count<=0; break_latched<=0;
            framing_error<=0; framing_count<=0;
        end else begin
            rx_byte_valid <= 1'b0;
            if (rx_sync) begin low_count<=0; break_latched<=0; end
            else if (low_count < CLK_HZ/10_000) low_count<=low_count+1'b1;
            if (apb_write && reg_index==1 && pwdata[2]) framing_error<=1'b0;
            if (break_now) begin
                rx_state<=RX_IDLE; baud_count<=0;
                if (!break_latched) begin framing_error<=1'b1; framing_count<=framing_count+1'b1; end
                break_latched<=1'b1;
            end else case (rx_state)
                RX_IDLE: if (!rx_sync && !break_latched) begin rx_state<=RX_START; baud_count<=HALF_DIV-1; end
                RX_START: if (baud_count==0) begin
                    if (!rx_sync) begin rx_state<=RX_DATA; baud_count<=DIVISOR-1; bit_index<=0; end
                    else rx_state<=RX_IDLE;
                end else baud_count<=baud_count-1'b1;
                RX_DATA: if (baud_count==0) begin
                    rx_shift[bit_index]<=rx_sync;
                    baud_count<=DIVISOR-1;
                    if (bit_index==7) rx_state<=RX_STOP; else bit_index<=bit_index+1'b1;
                end else baud_count<=baud_count-1'b1;
                RX_STOP: if (baud_count==0) begin
                    rx_state<=RX_IDLE;
                    if (rx_sync) begin rx_byte<=rx_shift; rx_byte_valid<=1'b1; end
                    else begin framing_error<=1'b1; framing_count<=framing_count+1'b1; end
                end else baud_count<=baud_count-1'b1;
                default: rx_state<=RX_IDLE;
            endcase
        end
    end

    reg [7:0] mem [0:FIFO_DEPTH-1];
    reg [PTR_W-1:0] wr_ptr, rd_ptr;
    reg [COUNT_W-1:0] count;
    reg [7:0] ram_q, out_q;
    reg out_valid, rd_pending;
    reg overrun;
    reg [31:0] overrun_count;
    wire apb_read_data = apb_access && pready && !pwrite && reg_index==0;
    wire rd_issue = !out_valid && !rd_pending && count!=0;
    wire fifo_write = rx_byte_valid && ((count<FIFO_DEPTH) || apb_read_data);
    assign pready = apb_access && ((reg_index==0 && !pwrite) ? out_valid : 1'b1);
    assign pslverror = 1'b0;

    // True block RAM in product builds; behavioral byte array is for RTL simulation only.
`ifdef FAST_SIM
    reg [7:0] sim_dout;
    always @(posedge clk) if (rd_issue) sim_dout <= mem[rd_ptr];
    always @(posedge clk) if (fifo_write) mem[wr_ptr] <= rx_byte;
    always @* ram_q = sim_dout;
`else
    wire [7:0] ram_out;
    EFX_RAM10 #(.READ_WIDTH(8),.WRITE_WIDTH(8),.OUTPUT_REG(0),
        .WRITE_MODE("READ_UNKNOWN"),.RESET_RAM("NONE"),.RESET_OUTREG("NONE")) u_fifo_ram(
        .WCLK(clk),.WE({fifo_write,fifo_write}),
        .WCLKE(1'b1),.WADDREN(1'b1),.WDATA(rx_byte),.WADDR(wr_ptr),
        .RCLK(clk),.RE(rd_issue),.RST(1'b0),
        .RADDREN(1'b1),.RDATA(ram_out),.RADDR(rd_ptr));
    always @* ram_q = ram_out;
`endif

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wr_ptr<=0; rd_ptr<=0; count<=0; out_q<=0; out_valid<=0; rd_pending<=0;
            overrun<=0; overrun_count<=0; byte_count<=0;
        end else begin
            if (fifo_write) begin wr_ptr<=wr_ptr+1'b1; byte_count<=byte_count+1'b1; end
            if (apb_write && reg_index==1 && pwdata[1]) overrun<=1'b0;
            if (rx_byte_valid && count==FIFO_DEPTH && !apb_read_data) begin overrun<=1'b1; overrun_count<=overrun_count+1'b1; end
            if (rd_issue) rd_pending<=1'b1;
            else if (rd_pending) begin out_q<=ram_q; out_valid<=1'b1; rd_pending<=1'b0; end
            if (apb_read_data) begin out_valid<=1'b0; rd_ptr<=rd_ptr+1'b1; end
            if (apb_write && reg_index==6 && pwdata[0]) begin
                wr_ptr<=0; rd_ptr<=0; count<=0; out_valid<=0; rd_pending<=0;
            end
            if (!(apb_write && reg_index==6 && pwdata[0])) begin
                case ({fifo_write,apb_read_data})
                    2'b10: count<=count+1'b1;
                    2'b01: count<=count-1'b1;
                    default: count<=count;
                endcase
            end
        end
    end

    always @* begin
        prdata=0;
        case (reg_index)
            0: prdata={24'd0,out_q};
            1: prdata={27'd0, (count==FIFO_DEPTH), 1'b0, framing_error, overrun, (count!=0)};
            2: prdata=count;
            3: prdata=overrun_count;
            4: prdata=framing_count;
            5: prdata=byte_count;
            6: prdata=0;
            7: prdata=0;
            8: prdata={31'd0,(ENABLE_TX && !tx_busy)};
            default: prdata=0;
        endcase
    end
endmodule
