// 手势关键点 NPU 顶层：APB 从口（CPU 控制）+ AXI4 主口（DDR 访存）+ 执行引擎。
//
// 控制流：CPU 用 APB 写四个基址和 CTRL.start；顶层 FSM 从层 0 走到层 62，
// 每层给引擎一个 start，引擎算完给 done；全部走完置 STATUS.done 并可选中断。
// 算完一整帧不需要 CPU 参与，CPU 只在开头配置、结尾读结果。
import gesture_desc_pkg::*;

module gesture_top #(
    parameter int APB_ADDR_W = 12,
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_ID_W   = 4
) (
    output wire [127:0]           dbg_snapshot,
    input  logic                  clk,
    input  logic                  reset,

    // ---------------- APB 从口（CPU 控制面）----------------
    input  logic                  apb_psel,
    input  logic                  apb_penable,
    input  logic                  apb_pwrite,
    input  logic [APB_ADDR_W-1:0] apb_paddr,
    input  logic [31:0]           apb_pwdata,
    output logic [31:0]           apb_prdata,
    output logic                  apb_pready,
    output logic                  apb_pslverr,

    // ---------------- AXI4 主口（数据面，128 位）----------------
    output logic [AXI_ID_W-1:0]   m_axi_arid,
    output logic [AXI_ADDR_W-1:0] m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    input  logic [AXI_ID_W-1:0]   m_axi_rid,
    input  logic [127:0]          m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,

    output logic [AXI_ID_W-1:0]   m_axi_awid,
    output logic [AXI_ADDR_W-1:0] m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [127:0]          m_axi_wdata,
    output logic [15:0]           m_axi_wstrb,
    output logic                  m_axi_wlast,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    input  logic [AXI_ID_W-1:0]   m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,

    // ---------------- 状态直出（便于板上观测）----------------
    output logic                  irq,
    output logic [7:0]            dbg_layer,
    output logic                  dbg_busy
);
    // ----------------------------------------------------------- 寄存器
    logic [31:0] reg_ctrl, reg_status, reg_irq_en;
    logic [31:0] reg_irq_status;      // 由层调度器独占驱动
    logic        irq_clear_pulse;
    logic [31:0] reg_weights_base, reg_params_base, reg_image_base, reg_scores_base;
    // Descriptor addresses are offsets within the packed NPU memory image.
    // Translate the whole image into an allocated DDR window at the AXI edge.
    logic [31:0] reg_ddr_base_offset;
    logic        start_pulse;

    wire apb_write = apb_psel && apb_penable && apb_pwrite;
    wire apb_read  = apb_psel && apb_penable && !apb_pwrite;

    always_ff @(posedge clk) begin
        if (reset) begin
            reg_ctrl <= '0;
            reg_irq_en <= '0;
            reg_weights_base <= DDR_WEIGHTS;
            reg_params_base  <= DDR_PARAMS;
            reg_image_base   <= DDR_IMAGE;
            reg_scores_base  <= DDR_SCORES;
            reg_ddr_base_offset <= 32'h0000_0000;
            start_pulse <= 1'b0;
            irq_clear_pulse <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            irq_clear_pulse <= 1'b0;
            if (apb_write) begin
                case (apb_paddr[7:0])
                    8'h00: begin
                        reg_ctrl <= apb_pwdata;
                        if (apb_pwdata[0]) start_pulse <= 1'b1;
                    end
                    8'h08: begin
                        reg_irq_en <= apb_pwdata;
                        if (apb_pwdata[0]) irq_clear_pulse <= 1'b1;  // W1C
                    end
                    8'h10: reg_weights_base <= apb_pwdata;
                    8'h14: reg_params_base  <= apb_pwdata;
                    8'h18: reg_image_base   <= apb_pwdata;
                    8'h1C: reg_scores_base  <= apb_pwdata;
                    8'h24: reg_ddr_base_offset <= apb_pwdata;
                    default: ;
                endcase
            end
            if (apb_read && apb_paddr[7:0] == 8'h0C)
                irq_clear_pulse <= 1'b1;                           // 读清
        end
    end

    assign irq = reg_irq_en[0] && reg_irq_status[0];

    // ------------------------------------------------------------- 引擎
    logic [31:0] dbg_engine,dbg_position,dbg_load,dbg_store,dbg_axi;
    logic         eng_start, eng_busy, eng_done, eng_error;
    logic [7:0]   eng_layer;
    logic         rd_valid, rd_ready, wr_valid, wr_ready;
    logic [31:0]  rd_addr, wr_addr;
    logic [15:0]  rd_len, wr_len;
    logic         rd_dv, rd_dr, rd_last, rd_done, rd_error;
    logic [127:0] rd_data;
    logic [15:0]  rd_keep;
    logic         wr_dv, wr_dr, wr_last, wr_done, wr_error;
    logic [127:0] wr_data;
    logic [15:0]  wr_keep;

    gesture_engine #(
        .OUT_BYTES(8192)
    ) u_engine (
        .debug_state(dbg_engine), .debug_position(dbg_position),
        .debug_load(dbg_load), .debug_store(dbg_store),
        .clk(clk), .reset(reset),
        .start(eng_start), .layer_id(eng_layer),
        .busy(eng_busy), .done(eng_done), .error(eng_error),
        .rd_valid(rd_valid), .rd_ready(rd_ready), .rd_address(rd_addr),
        .rd_length(rd_len),
        .rd_data_valid(rd_dv), .rd_data_ready(rd_dr), .rd_data(rd_data),
        .rd_keep(rd_keep), .rd_last(rd_last), .rd_done(rd_done), .rd_error(rd_error),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_address(wr_addr),
        .wr_length(wr_len),
        .wr_data_valid(wr_dv), .wr_data_ready(wr_dr), .wr_data(wr_data),
        .wr_keep(wr_keep), .wr_last(wr_last), .wr_done(wr_done), .wr_error(wr_error));

    logic [AXI_ADDR_W-1:0] axi_araddr_offset, axi_awaddr_offset;
    gesture_axi_master #(.ADDR_W(AXI_ADDR_W), .ID_W(AXI_ID_W)) u_axi (
        .debug_state(dbg_axi),
        .clk(clk), .reset(reset), .abort(1'b0),
        .read_valid(rd_valid), .read_ready(rd_ready),
        .read_address(rd_addr), .read_length(rd_len),
        .read_data_valid(rd_dv), .read_data_ready(rd_dr), .read_data(rd_data),
        .read_keep(rd_keep), .read_last(rd_last), .read_done(rd_done), .read_error(rd_error),
        .write_valid(wr_valid), .write_ready(wr_ready),
        .write_address(wr_addr), .write_length(wr_len),
        .write_data_valid(wr_dv), .write_data_ready(wr_dr), .write_data(wr_data),
        .write_keep(wr_keep), .write_done(wr_done), .write_error(wr_error), .idle(),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(axi_araddr_offset),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(axi_awaddr_offset),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready));

    // Keep the memory-map image relocatable while preserving the original
    // zero-offset behavior used by the standalone NPU regression.
    always_comb begin
        m_axi_araddr = axi_araddr_offset + AXI_ADDR_W'(reg_ddr_base_offset);
        m_axi_awaddr = axi_awaddr_offset + AXI_ADDR_W'(reg_ddr_base_offset);
    end

    // ------------------------------------------------------- 层调度 FSM
    typedef enum logic [2:0] {S_IDLE, S_ISSUE, S_WAIT, S_DONE, S_FAULT} seq_t;
    seq_t seq_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            seq_q <= S_IDLE;
            eng_start <= 1'b0;
            eng_layer <= '0;
            reg_status <= '0;
            reg_irq_status <= '0;
        end else begin
            eng_start <= 1'b0;
            if (irq_clear_pulse) reg_irq_status <= '0;
            case (seq_q)
            S_IDLE: begin
                reg_status[0] <= 1'b0;
                if (start_pulse) begin
                    eng_layer <= 8'd0;
                    reg_status <= '0;
                    seq_q <= S_ISSUE;
                end
            end

            S_ISSUE: begin
                eng_start <= 1'b1;
                reg_status[0] <= 1'b1;          // busy
                seq_q <= S_WAIT;
            end

            S_WAIT: begin
                if (eng_error) begin
                    reg_status[2] <= 1'b1;      // error
                    seq_q <= S_FAULT;
                end else if (eng_done) begin
                    if (eng_layer + 8'd1 == LAYER_COUNT) begin
                        reg_status[0] <= 1'b0;
                        reg_status[1] <= 1'b1;  // done
                        reg_irq_status[0] <= 1'b1;
                        seq_q <= S_DONE;
                    end else begin
                        eng_layer <= eng_layer + 8'd1;
                        seq_q <= S_ISSUE;
                    end
                end
            end

            S_DONE:  if (start_pulse) begin eng_layer <= '0; reg_status <= '0; seq_q <= S_ISSUE; end
            S_FAULT: if (start_pulse) begin reg_status <= '0; seq_q <= S_ISSUE; eng_layer <= '0; end
            default: seq_q <= S_IDLE;
            endcase
        end
    end

    assign dbg_layer = eng_layer;
    assign dbg_busy  = eng_busy;

`ifdef SIM_ASSERT
    // 引擎发出的读/写命令地址必须满足 AXI 主机的 16 字节对齐契约
    always_ff @(posedge clk) begin
        if (!reset && rd_valid && (rd_addr[3:0] != 4'd0))
            $fatal(1, "top: unaligned read command 0x%08x len=%0d", rd_addr, rd_len);
        if (!reset && rd_valid && rd_len == 16'd0)
            $fatal(1, "top: zero-length read command 0x%08x", rd_addr);
        if (!reset && wr_valid && (wr_addr[3:0] != 4'd0))
            $fatal(1, "top: unaligned write command 0x%08x", wr_addr);
    end
`endif
    assign dbg_snapshot={dbg_axi,dbg_load,dbg_engine,{16'd0,seq_q,eng_busy,eng_error,eng_done,rd_done,wr_done,eng_layer}};

    always_comb begin
        apb_prdata  = 32'h0;
        apb_pready  = 1'b1;
        apb_pslverr = 1'b0;
        case (apb_paddr[7:0])
            8'h00:   apb_prdata = reg_ctrl;
            8'h04:   apb_prdata = reg_status;
            8'h08:   apb_prdata = reg_irq_en;
            8'h0C:   apb_prdata = reg_irq_status;
            8'h10:   apb_prdata = reg_weights_base;
            8'h14:   apb_prdata = reg_params_base;
            8'h18:   apb_prdata = reg_image_base;
            8'h1C:   apb_prdata = reg_scores_base;
            8'h20:   apb_prdata = 32'h2026_1001;        // 版本
            8'h24:   apb_prdata = reg_ddr_base_offset;
            8'h28: apb_prdata = {16'd0,seq_q,eng_busy,eng_error,eng_done,rd_done,wr_done,eng_layer};
            8'h2c: apb_prdata = dbg_engine;
            8'h30: apb_prdata = dbg_position;
            8'h34: apb_prdata = dbg_load;
            8'h38: apb_prdata = dbg_store;
            8'h3c: apb_prdata = dbg_axi;
            8'h40: apb_prdata = rd_addr;
            8'h44: apb_prdata = wr_addr;
            8'h48: apb_prdata = axi_araddr_offset;
            8'h4c: apb_prdata = axi_awaddr_offset;
            default: apb_prdata = 32'hDEAD_BEEF;
        endcase
    end

endmodule
