module gesture_sync_fifo #(
    parameter int DATA_W = 128,
    parameter int ADDR_W = 8,
    parameter int REGISTER_BITS = 0
) (
    input  logic              clk,
    input  logic              reset,
    input  logic              wr_en,
    input  logic [DATA_W-1:0] wr_data,
    output logic              full,
    input  logic              rd_en,
    output logic [DATA_W-1:0] rd_data,
    output logic              empty,
    output logic [ADDR_W:0]    count
);
    logic [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];
    logic [ADDR_W-1:0] wr_ptr, rd_ptr;
    wire do_write = wr_en && !full;
    wire do_read = rd_en && !empty;
    assign full = count == (1<<ADDR_W);
    assign empty = count == 0;
    if (REGISTER_BITS > 0 && ADDR_W >= 3) begin : g_hybrid_srl
        // Keep the same FIFO capacity while fitting the remaining physical
        // RAM blocks. The shallow bank is an explicit EFX_SRL8 cascade; the
        // wider bank remains block RAM. Both use the original accepted write.
        (* syn_ramstyle = "block_ram" *) logic [DATA_W-REGISTER_BITS-1:0] block_mem [0:(1<<ADDR_W)-1];
        localparam int SRL_SEGMENTS = (1 << ADDR_W) / 8;
        wire [ADDR_W-1:0] tap = count[ADDR_W-1:0] - 1'b1;
        wire [2:0] srl_address = ~tap[2:0];
        wire [REGISTER_BITS-1:0] srl_rd_data;

        assign rd_data = {block_mem[rd_ptr], srl_rd_data};
        always_ff @(posedge clk) if(!reset && do_write)begin
            block_mem[wr_ptr]<=wr_data[DATA_W-1:REGISTER_BITS];
        end
        for (genvar b = 0; b < REGISTER_BITS; b = b + 1) begin : g_srl_bit
            wire [SRL_SEGMENTS:0] cascade;
            wire [SRL_SEGMENTS-1:0] selected;
            assign cascade[0] = ~wr_data[b];
            for (genvar s = 0; s < SRL_SEGMENTS; s = s + 1) begin : g_segment
                EFX_SRL8 u_srl (
                    .D(cascade[s]), .A(srl_address), .CLK(clk), .CE(!reset && do_write),
                    .Q(selected[s]), .Q7(cascade[s+1])
                );
            end
            if (ADDR_W == 3) begin : g_single_segment
                assign srl_rd_data[b] = selected[0];
            end else begin : g_multiple_segments
                assign srl_rd_data[b] = selected[tap[ADDR_W-1:3]];
            end
        end
    end else if (REGISTER_BITS > 0) begin : g_hybrid_generic
        // Preserve the generic implementation for depths smaller than SRL8.
        (* syn_ramstyle = "registers" *) logic [REGISTER_BITS-1:0] reg_mem [0:(1<<ADDR_W)-1];
        (* syn_ramstyle = "block_ram" *) logic [DATA_W-REGISTER_BITS-1:0] block_mem [0:(1<<ADDR_W)-1];
        assign rd_data={block_mem[rd_ptr],reg_mem[rd_ptr]};
        always_ff @(posedge clk) if(!reset && do_write)begin
            reg_mem[wr_ptr]<=wr_data[REGISTER_BITS-1:0];
            block_mem[wr_ptr]<=wr_data[DATA_W-1:REGISTER_BITS];
        end
    end else begin:g_memory
        assign rd_data=mem[rd_ptr];
        always_ff @(posedge clk) if(!reset && do_write)mem[wr_ptr]<=wr_data;
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count <= '0;
        end else begin
            if (do_write) begin
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (do_read) rd_ptr <= rd_ptr + 1'b1;
            case ({do_write,do_read})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
        end
    end
endmodule
