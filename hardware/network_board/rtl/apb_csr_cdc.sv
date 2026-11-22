// One outstanding APB access crossing between the Sapphire/core and accelerator
// domains. APB access is held until the remote slave replies.
module apb_csr_cdc (
    input  logic        s_clk,
    input  logic        s_reset,
    input  logic        s_psel,
    input  logic        s_penable,
    input  logic        s_pwrite,
    input  logic [11:0] s_paddr,
    input  logic [31:0] s_pwdata,
    output logic [31:0] s_prdata,
    output logic        s_pready,
    output logic        s_pslverr,

    input  logic        m_clk,
    input  logic        m_reset,
    output logic        m_psel,
    output logic        m_penable,
    output logic        m_pwrite,
    output logic [11:0] m_paddr,
    output logic [31:0] m_pwdata,
    input  logic [31:0] m_prdata,
    input  logic        m_pready,
    input  logic        m_pslverr
);
    (* async_reg = "true" *) logic req_sync1, req_sync2;
    (* async_reg = "true" *) logic ack_sync1, ack_sync2;
    logic req_toggle, ack_toggle;
    logic active_q;
    logic response_valid_q;
    (* syn_keep = 1 *) logic [11:0] addr_q;
    (* syn_keep = 1 *) logic write_q;
    (* syn_keep = 1 *) logic [31:0] wdata_q;
    (* syn_keep = 1 *) logic [11:0] m_addr_q;
    (* syn_keep = 1 *) logic m_write_q;
    (* syn_keep = 1 *) logic [31:0] m_wdata_q;
    (* syn_keep = 1 *) logic [31:0] rdata_q;
    logic error_q;
    (* syn_keep = 1 *) logic [31:0] remote_rdata_q;
    logic remote_error_q;

    always_ff @(posedge s_clk) begin
        if (s_reset) begin
            ack_sync1 <= 1'b0;
            ack_sync2 <= 1'b0;
            req_toggle <= 1'b0;
            active_q <= 1'b0;
            response_valid_q <= 1'b0;
            addr_q <= '0;
            write_q <= 1'b0;
            wdata_q <= '0;
            rdata_q <= '0;
            error_q <= 1'b0;
        end else begin
            ack_sync1 <= ack_toggle;
            ack_sync2 <= ack_sync1;
            if (!active_q && s_psel && s_penable) begin
                addr_q <= s_paddr;
                write_q <= s_pwrite;
                wdata_q <= s_pwdata;
                req_toggle <= ~req_toggle;
                active_q <= 1'b1;
                response_valid_q <= 1'b0;
            end
            if (active_q && !response_valid_q && ack_sync2 == req_toggle) begin
                // The remote response is stable before ack_toggle crosses back.
                rdata_q <= remote_rdata_q;
                error_q <= remote_error_q;
                response_valid_q <= 1'b1;
            end
            if (active_q && response_valid_q && s_psel && s_penable) begin
                active_q <= 1'b0;
                response_valid_q <= 1'b0;
            end
        end
    end

    always_comb begin
        s_pready = active_q && response_valid_q;
        s_prdata = rdata_q;
        s_pslverr = error_q;
    end

    typedef enum logic [1:0] {M_IDLE, M_SETUP, M_ACCESS} mstate_t;
    mstate_t mstate_q;
    always_comb begin
        m_psel = (mstate_q != M_IDLE);
        m_penable = (mstate_q == M_ACCESS);
        m_pwrite = m_write_q;
        m_paddr = m_addr_q;
        m_pwdata = m_wdata_q;
    end

    always_ff @(posedge m_clk) begin
        if (m_reset) begin
            req_sync1 <= 1'b0;
            req_sync2 <= 1'b0;
            ack_toggle <= 1'b0;
            mstate_q <= M_IDLE;
            m_addr_q <= '0;
            m_write_q <= 1'b0;
            m_wdata_q <= '0;
            remote_rdata_q <= '0;
            remote_error_q <= 1'b0;
        end else begin
            req_sync1 <= req_toggle;
            req_sync2 <= req_sync1;
            case (mstate_q)
                M_IDLE: if (req_sync2 != ack_toggle) begin
                    // Sample stable source payload after the request toggle's
                    // two-flop synchronizer, then start a normal APB setup.
                    m_addr_q <= addr_q;
                    m_write_q <= write_q;
                    m_wdata_q <= wdata_q;
                    mstate_q <= M_SETUP;
                end
                M_SETUP: mstate_q <= M_ACCESS;
                M_ACCESS: if (m_pready) begin
                    remote_rdata_q <= m_prdata;
                    remote_error_q <= m_pslverr;
                    ack_toggle <= req_sync2;
                    mstate_q <= M_IDLE;
                end
                default: mstate_q <= M_IDLE;
            endcase
        end
    end
endmodule
