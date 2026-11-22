// Single-outstanding bridge from Sapphire's 32-bit AXI-A port to the board's
// 128-bit DDR client interface. One narrow beat becomes one 128-bit beat with
// byte strobes; the read path selects the addressed 32-bit word.
module cpu_axi32_ddr128 (
    input  logic clk,
    input  logic reset,

    input  logic [7:0]   s_awid,
    input  logic [31:0]  s_awaddr,
    input  logic [7:0]   s_awlen,
    input  logic [2:0]   s_awsize,
    input  logic [1:0]   s_awburst,
    input  logic         s_awvalid,
    output logic         s_awready,
    input  logic [31:0]  s_wdata,
    input  logic [3:0]   s_wstrb,
    input  logic         s_wlast,
    input  logic         s_wvalid,
    output logic         s_wready,
    output logic [7:0]   s_bid,
    output logic [1:0]   s_bresp,
    output logic         s_bvalid,
    input  logic         s_bready,

    input  logic [7:0]   s_arid,
    input  logic [31:0]  s_araddr,
    input  logic [7:0]   s_arlen,
    input  logic [2:0]   s_arsize,
    input  logic [1:0]   s_arburst,
    input  logic         s_arvalid,
    output logic         s_arready,
    output logic [7:0]   s_rid,
    output logic [31:0]  s_rdata,
    output logic [1:0]   s_rresp,
    output logic         s_rlast,
    output logic         s_rvalid,
    input  logic         s_rready,

    output demo_bus_pkg::axi_req_t m_req,
    input  demo_bus_pkg::axi_rsp_t m_rsp
);
    import demo_bus_pkg::*;

    typedef enum logic [2:0] {W_IDLE, W_CAPTURE, W_ADDR, W_DATA, W_RESP, W_UP_RESP} wstate_t;
    typedef enum logic [2:0] {R_IDLE, R_ADDR, R_DATA, R_UP_DATA} rstate_t;
    wstate_t wstate_q;
    rstate_t rstate_q;

    logic [31:0] w_addr_q;
    logic [8:0]  w_left_q;
    logic [7:0]  w_id_q;
    logic [2:0]  w_size_q;
    logic [1:0]  w_burst_q, w_resp_q;
    logic [127:0] w_data_q;
    logic [15:0]  w_strb_q;
    logic         w_last_q;

    logic [31:0] r_addr_q;
    logic [8:0]  r_left_q;
    logic [7:0]  r_id_q;
    logic [2:0]  r_size_q;
    logic [1:0]  r_burst_q;
    logic [31:0] r_data_q;
    logic [1:0]  r_resp_q;
    logic        r_last_q;

    always_comb begin
        m_req = '0;
        s_awready = (wstate_q == W_IDLE);
        s_wready  = (wstate_q == W_CAPTURE);
        s_bid     = w_id_q;
        s_bresp   = w_resp_q;
        s_bvalid  = (wstate_q == W_UP_RESP);

        s_arready = (rstate_q == R_IDLE);
        s_rid     = r_id_q;
        s_rdata   = r_data_q;
        s_rresp   = r_resp_q;
        s_rlast   = r_last_q;
        s_rvalid  = (rstate_q == R_UP_DATA);

        m_req.awid    = 4'd0;
        m_req.awaddr  = {w_addr_q[31:4],4'b0000};
        m_req.awlen   = 8'd0;
        m_req.awsize  = 3'd4;
        m_req.awburst = 2'b01;
        m_req.awvalid = (wstate_q == W_ADDR);
        m_req.wdata   = w_data_q;
        m_req.wstrb   = w_strb_q;
        m_req.wlast   = 1'b1;
        m_req.wvalid  = (wstate_q == W_DATA);
        m_req.bready  = (wstate_q == W_RESP);

        m_req.arid    = 4'd0;
        m_req.araddr  = {r_addr_q[31:4],4'b0000};
        m_req.arlen   = 8'd0;
        m_req.arsize  = 3'd4;
        m_req.arburst = 2'b01;
        m_req.arvalid = (rstate_q == R_ADDR);
        m_req.rready  = (rstate_q == R_DATA);
    end

    always_ff @(posedge clk) begin : write_bridge
        logic [127:0] wide_data;
        logic [15:0] wide_strb;
        integer lane;
        if (reset) begin
            wstate_q <= W_IDLE;
            w_addr_q <= '0;
            w_left_q <= '0;
            w_id_q <= '0;
            w_size_q <= '0;
            w_burst_q <= '0;
            w_resp_q <= '0;
            w_data_q <= '0;
            w_strb_q <= '0;
            w_last_q <= 1'b0;
        end else begin
            case (wstate_q)
                W_IDLE: if (s_awvalid && s_awready) begin
                    w_addr_q <= s_awaddr;
                    w_left_q <= {1'b0, s_awlen} + 9'd1;
                    w_id_q <= s_awid;
                    w_size_q <= s_awsize;
                    w_burst_q <= s_awburst;
                    w_resp_q <= 2'b00;
                    wstate_q <= W_CAPTURE;
                end
                W_CAPTURE: if (s_wvalid && s_wready) begin
                    wide_data = '0;
                    wide_strb = '0;
                    for (int j=0; j<4; j++) begin
                        lane = w_addr_q[3:0] - w_addr_q[1:0] + j;
                        wide_data[8*lane +: 8] = s_wdata[8*j +: 8];
                        wide_strb[lane] = s_wstrb[j];
                    end
                    w_data_q <= wide_data;
                    w_strb_q <= wide_strb;
                    w_last_q <= s_wlast;
                    wstate_q <= W_ADDR;
                end
                W_ADDR: if (m_req.awvalid && m_rsp.awready) wstate_q <= W_DATA;
                W_DATA: if (m_req.wvalid && m_rsp.wready) wstate_q <= W_RESP;
                W_RESP: if (m_rsp.bvalid && m_req.bready) begin
                    if (m_rsp.bresp != 2'b00) w_resp_q <= m_rsp.bresp;
                    if (w_left_q == 1) begin
                        wstate_q <= W_UP_RESP;
                    end else begin
                        w_left_q <= w_left_q - 1'b1;
                        if (w_burst_q == 2'b01) w_addr_q <= w_addr_q + (32'd1 << w_size_q);
                        wstate_q <= W_CAPTURE;
                    end
                end
                W_UP_RESP: if (s_bvalid && s_bready) wstate_q <= W_IDLE;
                default: wstate_q <= W_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin : read_bridge
        if (reset) begin
            rstate_q <= R_IDLE;
            r_addr_q <= '0;
            r_left_q <= '0;
            r_id_q <= '0;
            r_size_q <= '0;
            r_burst_q <= '0;
            r_data_q <= '0;
            r_resp_q <= '0;
            r_last_q <= 1'b0;
        end else begin
            case (rstate_q)
                R_IDLE: if (s_arvalid && s_arready) begin
                    r_addr_q <= s_araddr;
                    r_left_q <= {1'b0, s_arlen} + 9'd1;
                    r_id_q <= s_arid;
                    r_size_q <= s_arsize;
                    r_burst_q <= s_arburst;
                    rstate_q <= R_ADDR;
                end
                R_ADDR: if (m_req.arvalid && m_rsp.arready) rstate_q <= R_DATA;
                R_DATA: if (m_rsp.rvalid && m_req.rready) begin
                    r_data_q <= m_rsp.rdata[32*r_addr_q[3:2] +: 32];
                    r_resp_q <= m_rsp.rresp;
                    r_last_q <= (r_left_q == 1);
                    rstate_q <= R_UP_DATA;
                end
                R_UP_DATA: if (s_rvalid && s_rready) begin
                    if (r_left_q == 1) begin
                        rstate_q <= R_IDLE;
                    end else begin
                        r_left_q <= r_left_q - 1'b1;
                        if (r_burst_q == 2'b01) r_addr_q <= r_addr_q + (32'd1 << r_size_q);
                        rstate_q <= R_ADDR;
                    end
                end
                default: rstate_q <= R_IDLE;
            endcase
        end
    end

    always @(posedge clk) if (!reset) begin
        if (s_awvalid && s_awready && (s_awsize > 3'd2 || (s_awburst != 2'b00 && s_awburst != 2'b01) || (s_awaddr & ((32'd1 << s_awsize) - 1)) != 0))
            $fatal(1, "CPU AXI-A write size/burst unsupported");
        if (s_wvalid && s_wready && (s_wlast != (w_left_q == 1)))
            $fatal(1, "CPU AXI-A WLAST missing on final beat");
        if (s_arvalid && s_arready && (s_arsize > 3'd2 || (s_arburst != 2'b00 && s_arburst != 2'b01) || (s_araddr & ((32'd1 << s_arsize) - 1)) != 0))
            $fatal(1, "CPU AXI-A read size/burst unsupported");
    end
endmodule
