// Atomic network-to-CPU command mailbox for browser-originated J7 UART work.
// The network domain presents one token/type/length/payload record; the CPU
// drains the byte stream through its APB window without crossing raw buses.
module web_control_mailbox (
    input  logic        net_clk,
    input  logic        cpu_clk,
    input  logic        arst,
    input  logic        cmd_valid,
    output logic        cmd_ready,
    input  logic [31:0] cmd_token,
    input  logic [7:0]  cmd_type,
    input  logic [7:0]  cmd_length,
    input  logic [431:0] cmd_payload,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [11:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,
    output logic        net_status_valid,
    output logic [63:0] net_status_data
);
    logic [7:0] fifo_wdata, fifo_rdata;
    logic fifo_wr, fifo_full, fifo_rd, fifo_empty;
    logic busy;
    logic [31:0] token_q;
    logic [7:0] type_q, length_q;
    logic [431:0] payload_q;
    logic [6:0] index_q;
    logic [6:0] record_length;
    logic access;
    logic [1:0] net_ready_pipe;
    logic net_cmd_locked;
    logic [31:0] locked_token_q;
    logic [31:0] status_token_q, status_meta_q;
    logic [63:0] status_wdata, status_rdata;
    logic status_wr, status_full, status_rd, status_empty;

    assign access = psel && penable;
    assign pready = !(access && !pwrite && paddr[3:2] == 2'd1 && fifo_empty);
    assign pslverr = access && pready && pwrite &&
                     (paddr[5:2] == 4'd4 && status_full);
    assign cmd_ready = !busy && !fifo_full && !net_cmd_locked && net_ready_pipe[1];
    assign record_length = {1'b0,length_q} + 7'd6;

    always_comb begin
        fifo_wr = 1'b0;
        fifo_wdata = 8'd0;
        if (busy && !fifo_full) begin
            fifo_wr = 1'b1;
            case (index_q)
                0: fifo_wdata = token_q[7:0];
                1: fifo_wdata = token_q[15:8];
                2: fifo_wdata = token_q[23:16];
                3: fifo_wdata = token_q[31:24];
                4: fifo_wdata = type_q;
                5: fifo_wdata = length_q;
                default: fifo_wdata = payload_q[8*(index_q-6)+:8];
            endcase
        end
        fifo_rd = access && !pwrite && paddr[3:2] == 2'd1 && !fifo_empty;
        status_wr = access && pready && pwrite && paddr[5:2] == 4'd4 && !status_full;
        status_wdata = {status_meta_q,status_token_q};
        status_rd = !status_empty;
        net_status_valid = !status_empty;
        net_status_data = status_rdata;
        prdata = 32'd0;
        if (paddr[3:2] == 2'd0)
            prdata = {30'd0,status_full,fifo_empty};
        else if (paddr[3:2] == 2'd1)
            prdata = {24'd0,fifo_rdata};
        else if (paddr[5:2] == 4'd0)
            prdata = {31'd0,fifo_empty};
        else if (paddr[5:2] == 4'd2)
            prdata = status_token_q;
        else if (paddr[5:2] == 4'd3)
            prdata = status_meta_q;
    end

    gesture_async_fifo #(.DATA_W(8), .ADDR_W(7)) u_cmd_fifo (
        .arst(arst), .wclk(net_clk), .wr_en(fifo_wr), .wr_data(fifo_wdata),
        .full(fifo_full), .rclk(cpu_clk), .rd_en(fifo_rd),
        .rd_data(fifo_rdata), .empty(fifo_empty));
    gesture_async_fifo #(.DATA_W(64), .ADDR_W(4)) u_status_fifo (
        .arst(arst), .wclk(cpu_clk), .wr_en(status_wr), .wr_data(status_wdata),
        .full(status_full), .rclk(net_clk), .rd_en(status_rd),
        .rd_data(status_rdata), .empty(status_empty));

    always_ff @(posedge net_clk or posedge arst) begin
        if (arst) net_ready_pipe <= 2'b00;
        else      net_ready_pipe <= {net_ready_pipe[0],1'b1};
    end

    always_ff @(posedge net_clk or posedge arst) begin
        if (arst) begin
            busy <= 1'b0;
            net_cmd_locked <= 1'b0;
            locked_token_q <= 32'd0;
            index_q <= 7'd0;
            token_q <= 32'd0;
            type_q <= 8'd0;
            length_q <= 8'd0;
            payload_q <= '0;
        end else begin
            if (cmd_valid && cmd_ready && cmd_length <= 8'd54) begin
                busy <= 1'b1;
                net_cmd_locked <= 1'b1;
                locked_token_q <= cmd_token;
                index_q <= 7'd0;
                token_q <= cmd_token;
                type_q <= cmd_type;
                length_q <= cmd_length;
                payload_q <= cmd_payload;
            end else if (busy && !fifo_full) begin
                if (index_q + 7'd1 >= record_length) begin
                    busy <= 1'b0;
                    index_q <= 7'd0;
                end else index_q <= index_q + 7'd1;
            end
            if (net_status_valid && net_status_data[39:32] == 8'd4
                && net_status_data[31:0] == locked_token_q)
                net_cmd_locked <= 1'b0;
        end
    end

    always_ff @(posedge cpu_clk or posedge arst) begin
        if (arst) begin
            status_token_q <= 32'd0;
            status_meta_q <= 32'd0;
        end else if (access && pready && pwrite) begin
            case (paddr[5:2])
                4'd2: status_token_q <= pwdata;
                4'd3: status_meta_q <= pwdata;
                default: ;
            endcase
        end
    end
endmodule
