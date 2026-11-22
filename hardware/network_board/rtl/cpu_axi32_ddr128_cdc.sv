// Clock-domain wrapper for cpu_axi32_ddr128. The 32->128 converter remains
// entirely in the CPU clock domain; five one-entry bundled-data mailboxes
// carry AW, W, AR, B and R independently across to/from the DDR clock.
// reset inputs are expected to be a common system reset. Keep m_enable low
// during DDR calibration: requests and responses then remain parked safely.
module cpu_axi32_ddr128_cdc (
    input logic s_clk, input logic s_reset,
    input logic m_clk, input logic m_reset,
    input logic m_enable,

    input logic [7:0] s_awid, input logic [31:0] s_awaddr,
    input logic [7:0] s_awlen, input logic [2:0] s_awsize,
    input logic [1:0] s_awburst, input logic s_awvalid, output logic s_awready,
    input logic [31:0] s_wdata, input logic [3:0] s_wstrb,
    input logic s_wlast, input logic s_wvalid, output logic s_wready,
    output logic [7:0] s_bid, output logic [1:0] s_bresp,
    output logic s_bvalid, input logic s_bready,

    input logic [7:0] s_arid, input logic [31:0] s_araddr,
    input logic [7:0] s_arlen, input logic [2:0] s_arsize,
    input logic [1:0] s_arburst, input logic s_arvalid, output logic s_arready,
    output logic [7:0] s_rid, output logic [31:0] s_rdata,
    output logic [1:0] s_rresp, output logic s_rlast,
    output logic s_rvalid, input logic s_rready,

    output demo_bus_pkg::axi_req_t m_req,
    input demo_bus_pkg::axi_rsp_t m_rsp
);
    import demo_bus_pkg::*;

    wire common_reset = s_reset | m_reset;
    (* async_reg = "true" *) logic [1:0] s_reset_pipe_q, m_reset_pipe_q;
    wire s_local_reset = s_reset_pipe_q[1];
    wire m_local_reset = m_reset_pipe_q[1];
    (* async_reg = "true" *) logic m_up_sync1_q, m_up_sync2_q;
    (* async_reg = "true" *) logic s_up_sync1_q, s_up_sync2_q;
    wire s_domain_ready = !s_reset_pipe_q[1] && m_up_sync2_q;
    wire m_domain_ready = !m_reset_pipe_q[1] && s_up_sync2_q;
    axi_req_t c_req;
    axi_rsp_t c_rsp;
    logic bridge_awready, bridge_wready, bridge_arready;
    logic bridge_bvalid, bridge_rvalid;

    // Assert reset to both sides together; release locally and synchronize
    // remote-up before permitting any AXI handshake in either direction.
    always_ff @(posedge s_clk or posedge common_reset) begin
        if (common_reset) s_reset_pipe_q <= 2'b11;
        else s_reset_pipe_q <= {s_reset_pipe_q[0],1'b0};
    end
    always_ff @(posedge m_clk or posedge common_reset) begin
        if (common_reset) m_reset_pipe_q <= 2'b11;
        else m_reset_pipe_q <= {m_reset_pipe_q[0],1'b0};
    end
    always_ff @(posedge s_clk or posedge s_local_reset) begin
        if (s_local_reset) begin m_up_sync1_q<=1'b0; m_up_sync2_q<=1'b0; end
        else begin m_up_sync1_q<=!m_reset_pipe_q[1]; m_up_sync2_q<=m_up_sync1_q; end
    end
    always_ff @(posedge m_clk or posedge m_local_reset) begin
        if (m_local_reset) begin s_up_sync1_q<=1'b0; s_up_sync2_q<=1'b0; end
        else begin s_up_sync1_q<=!s_reset_pipe_q[1]; s_up_sync2_q<=s_up_sync1_q; end
    end

    logic [48:0] aw_s_data, aw_m_data;
    logic [144:0] w_s_data, w_m_data;
    logic [48:0] ar_s_data, ar_m_data;
    logic [5:0] b_s_data, b_m_data;
    logic [134:0] r_s_data, r_m_data;
    logic aw_s_ready, aw_m_valid, w_s_ready, w_m_valid;
    logic ar_s_ready, ar_m_valid, b_m_ready, b_s_valid;
    logic r_m_ready, r_s_valid;

    cpu_axi32_ddr128 u_cpu_bridge (
        .clk(s_clk), .reset(s_reset_pipe_q[1]),
        .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen),
        .s_awsize(s_awsize), .s_awburst(s_awburst), .s_awvalid(s_domain_ready && s_awvalid), .s_awready(bridge_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_domain_ready && s_wvalid), .s_wready(bridge_wready),
        .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(bridge_bvalid), .s_bready(s_domain_ready && s_bready),
        .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen),
        .s_arsize(s_arsize), .s_arburst(s_arburst), .s_arvalid(s_domain_ready && s_arvalid), .s_arready(bridge_arready),
        .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(bridge_rvalid), .s_rready(s_domain_ready && s_rready),
        .m_req(c_req), .m_rsp(c_rsp)
    );

    assign aw_s_data = {c_req.awid,c_req.awaddr,c_req.awlen,c_req.awsize,c_req.awburst};
    assign w_s_data  = {c_req.wdata,c_req.wstrb,c_req.wlast};
    assign ar_s_data = {c_req.arid,c_req.araddr,c_req.arlen,c_req.arsize,c_req.arburst};
    assign b_s_data  = {m_rsp.bid,m_rsp.bresp};
    assign r_s_data  = {m_rsp.rid,m_rsp.rdata,m_rsp.rresp,m_rsp.rlast};

    axi_cdc_mailbox #(.WIDTH(49)) u_aw_mailbox (
        .s_reset(s_local_reset), .s_clk(s_clk), .s_valid(s_domain_ready && c_req.awvalid), .s_ready(aw_s_ready), .s_data(aw_s_data),
        .m_reset(m_local_reset),
        .m_clk(m_clk), .m_valid(aw_m_valid), .m_ready(m_enable && m_rsp.awready), .m_data(aw_m_data)
    );
    axi_cdc_mailbox #(.WIDTH(145)) u_w_mailbox (
        .s_reset(s_local_reset), .s_clk(s_clk), .s_valid(s_domain_ready && c_req.wvalid), .s_ready(w_s_ready), .s_data(w_s_data),
        .m_reset(m_local_reset),
        .m_clk(m_clk), .m_valid(w_m_valid), .m_ready(m_enable && m_rsp.wready), .m_data(w_m_data)
    );
    axi_cdc_mailbox #(.WIDTH(49)) u_ar_mailbox (
        .s_reset(s_local_reset), .s_clk(s_clk), .s_valid(s_domain_ready && c_req.arvalid), .s_ready(ar_s_ready), .s_data(ar_s_data),
        .m_reset(m_local_reset),
        .m_clk(m_clk), .m_valid(ar_m_valid), .m_ready(m_enable && m_rsp.arready), .m_data(ar_m_data)
    );
    axi_cdc_mailbox #(.WIDTH(6)) u_b_mailbox (
        .s_reset(m_local_reset), .s_clk(m_clk), .s_valid(m_domain_ready && m_enable && m_rsp.bvalid), .s_ready(b_m_ready), .s_data(b_s_data),
        .m_reset(s_local_reset),
        .m_clk(s_clk), .m_valid(b_s_valid), .m_ready(c_req.bready), .m_data(b_m_data)
    );
    axi_cdc_mailbox #(.WIDTH(135)) u_r_mailbox (
        .s_reset(m_local_reset), .s_clk(m_clk), .s_valid(m_domain_ready && m_enable && m_rsp.rvalid), .s_ready(r_m_ready), .s_data(r_s_data),
        .m_reset(s_local_reset),
        .m_clk(s_clk), .m_valid(r_s_valid), .m_ready(c_req.rready), .m_data(r_m_data)
    );

    always_comb begin
        s_awready = s_domain_ready && bridge_awready;
        s_wready = s_domain_ready && bridge_wready;
        s_arready = s_domain_ready && bridge_arready;
        s_bvalid = s_domain_ready && bridge_bvalid;
        s_rvalid = s_domain_ready && bridge_rvalid;
        c_rsp = '0;
        c_rsp.awready = s_domain_ready && aw_s_ready;
        c_rsp.wready = s_domain_ready && w_s_ready;
        c_rsp.arready = s_domain_ready && ar_s_ready;
        c_rsp.bvalid = s_domain_ready && b_s_valid;
        c_rsp.bid = b_m_data[5:2];
        c_rsp.bresp = b_m_data[1:0];
        c_rsp.rvalid = s_domain_ready && r_s_valid;
        c_rsp.rid = r_m_data[134:131];
        c_rsp.rdata = r_m_data[130:3];
        c_rsp.rresp = r_m_data[2:1];
        c_rsp.rlast = r_m_data[0];

        m_req = '0;
        m_req.awid = aw_m_data[48:45];
        m_req.awaddr = aw_m_data[44:13];
        m_req.awlen = aw_m_data[12:5];
        m_req.awsize = aw_m_data[4:2];
        m_req.awburst = aw_m_data[1:0];
        m_req.awvalid = m_domain_ready && m_enable && aw_m_valid;
        m_req.wdata = w_m_data[144:17];
        m_req.wstrb = w_m_data[16:1];
        m_req.wlast = w_m_data[0];
        m_req.wvalid = m_domain_ready && m_enable && w_m_valid;
        m_req.bready = m_domain_ready && m_enable && b_m_ready;
        m_req.arid = ar_m_data[48:45];
        m_req.araddr = ar_m_data[44:13];
        m_req.arlen = ar_m_data[12:5];
        m_req.arsize = ar_m_data[4:2];
        m_req.arburst = ar_m_data[1:0];
        m_req.arvalid = m_domain_ready && m_enable && ar_m_valid;
        m_req.rready = m_domain_ready && m_enable && r_m_ready;
    end
endmodule

// One-entry toggle mailbox. The source holds payload stable until the
// synchronized acknowledgement returns; only the toggle crosses as control.
module axi_cdc_mailbox #(parameter integer WIDTH=32) (
    input logic s_reset,
    input logic s_clk, input logic s_valid, output logic s_ready, input logic [WIDTH-1:0] s_data,
    input logic m_reset,
    input logic m_clk, output logic m_valid, input logic m_ready, output logic [WIDTH-1:0] m_data
);
    (* syn_keep = 1 *) logic [WIDTH-1:0] data_q;
    (* syn_keep = 1 *) logic [WIDTH-1:0] m_data_q;
    logic m_valid_q;
    logic req_toggle_q, ack_toggle_q;
    (* async_reg = "true" *) logic ack_sync1_q, ack_sync2_q;
    (* async_reg = "true" *) logic req_sync1_q, req_sync2_q;

    assign s_ready = (ack_sync2_q == req_toggle_q);
    assign m_valid = m_valid_q;
    assign m_data = m_data_q;

    always_ff @(posedge s_clk) begin
        if (s_reset) begin
            req_toggle_q <= 1'b0;
            data_q <= '0;
            ack_sync1_q <= 1'b0;
            ack_sync2_q <= 1'b0;
        end else begin
            ack_sync1_q <= ack_toggle_q;
            ack_sync2_q <= ack_sync1_q;
            if (s_valid && s_ready) begin
                data_q <= s_data;
                req_toggle_q <= ~req_toggle_q;
            end
        end
    end

    always_ff @(posedge m_clk) begin
        if (m_reset) begin
            req_sync1_q <= 1'b0;
            req_sync2_q <= 1'b0;
            ack_toggle_q <= 1'b0;
            m_valid_q <= 1'b0;
            m_data_q <= '0;
        end else begin
            req_sync1_q <= req_toggle_q;
            req_sync2_q <= req_sync1_q;
            // Capture the bundled payload only after the request toggle has
            // crossed two destination flops. This gives STA a real endpoint
            // for the max-delay bound and keeps payload out of async logic.
            if (!m_valid_q && (req_sync2_q != ack_toggle_q)) begin
                m_data_q <= data_q;
                m_valid_q <= 1'b1;
            end else if (m_valid_q && m_ready) begin
                ack_toggle_q <= req_sync2_q;
                m_valid_q <= 1'b0;
            end
        end
    end
endmodule
