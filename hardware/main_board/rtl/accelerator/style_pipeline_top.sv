/* OPTIMIZATION_NOTE_20261005
 * 整机验收边界（2026-10-05）：完整加速器以200MHz验收，系统运行目标仍为180MHz。
 * 两组200MHz P&R均通过；具体资源与setup/hold见docs/TIMING_200MHZ_20261005.md。
 * 接入板级互连/时钟/视频后必须重跑整机P&R，不能沿用子系统报告宣布整机时序通过。
 * 720p 32.1466fps是DIRECT融合路径的有限DDR停顿周期模型，并非板上共享DDR实测。
 * 算术cluster有显式替身；CPU条带IRQ和真实DDR争用仍须验收，邻域DDR回退另测吞吐。
 * 支持640x480/1280x720/1920x1080，固定目标仅720p30，不能宣称三档均30fps。
 * 模型参数及IPX表仍只在整帧空闲更新；两主口各接AXI互连，不可直接并接。
 * 详见 docs/OPTIMIZATION_CONSTRAINTS.md 及 docs/INTEGRATION.md。
 */
// 完整NPU/后处理集成：统一原生寄存器接口、两路DDR AXI主口、同一处理时钟。
// 模型、原图、checkpoint和最终帧由外部DDR/系统互连提供；不包含板级PHY或视频接口。
module style_pipeline_top(
    input wire csr_valid,csr_write,
    input wire [11:0] csr_address,
    input wire [31:0] csr_wdata,
    input wire [3:0] csr_wstrb,
    output logic csr_ready,csr_error,
    output wire [31:0] csr_rdata,
    input wire [1:0] csr_target,
    input wire clk,reset,
    output wire control_idle,
    output wire  n_irq, // 系统AXI/中断边界。
    output wire [3:0] n_m_axi_arid, // 系统AXI/中断边界。
    output wire [31:0] n_m_axi_araddr, // 系统AXI/中断边界。
    output wire [7:0] n_m_axi_arlen, // 系统AXI/中断边界。
    output wire [2:0] n_m_axi_arsize, // 系统AXI/中断边界。
    output wire [1:0] n_m_axi_arburst, // 系统AXI/中断边界。
    output wire  n_m_axi_arvalid, // 系统AXI/中断边界。
    input wire  n_m_axi_arready, // 系统AXI/中断边界。
    input wire [3:0] n_m_axi_rid, // 系统AXI/中断边界。
    input wire [127:0] n_m_axi_rdata, // 系统AXI/中断边界。
    input wire [1:0] n_m_axi_rresp, // 系统AXI/中断边界。
    input wire  n_m_axi_rlast, // 系统AXI/中断边界。
    input wire  n_m_axi_rvalid, // 系统AXI/中断边界。
    output wire  n_m_axi_rready, // 系统AXI/中断边界。
    output wire [3:0] n_m_axi_awid, // 系统AXI/中断边界。
    output wire [31:0] n_m_axi_awaddr, // 系统AXI/中断边界。
    output wire [7:0] n_m_axi_awlen, // 系统AXI/中断边界。
    output wire [2:0] n_m_axi_awsize, // 系统AXI/中断边界。
    output wire [1:0] n_m_axi_awburst, // 系统AXI/中断边界。
    output wire  n_m_axi_awvalid, // 系统AXI/中断边界。
    input wire  n_m_axi_awready, // 系统AXI/中断边界。
    output wire [127:0] n_m_axi_wdata, // 系统AXI/中断边界。
    output wire [15:0] n_m_axi_wstrb, // 系统AXI/中断边界。
    output wire  n_m_axi_wlast, // 系统AXI/中断边界。
    output wire  n_m_axi_wvalid, // 系统AXI/中断边界。
    input wire  n_m_axi_wready, // 系统AXI/中断边界。
    input wire [3:0] n_m_axi_bid, // 系统AXI/中断边界。
    input wire [1:0] n_m_axi_bresp, // 系统AXI/中断边界。
    input wire  n_m_axi_bvalid, // 系统AXI/中断边界。
    output wire  n_m_axi_bready, // 系统AXI/中断边界。
    output wire  p_irq, // 系统AXI/中断边界。
    output wire [3:0] p_m_axi_arid, // 系统AXI/中断边界。
    output wire [3:0] p_m_axi_awid, // 系统AXI/中断边界。
    output wire [31:0] p_m_axi_araddr, // 系统AXI/中断边界。
    output wire [31:0] p_m_axi_awaddr, // 系统AXI/中断边界。
    output wire [7:0] p_m_axi_arlen, // 系统AXI/中断边界。
    output wire [7:0] p_m_axi_awlen, // 系统AXI/中断边界。
    output wire [2:0] p_m_axi_arsize, // 系统AXI/中断边界。
    output wire [2:0] p_m_axi_awsize, // 系统AXI/中断边界。
    output wire [1:0] p_m_axi_arburst, // 系统AXI/中断边界。
    output wire [1:0] p_m_axi_awburst, // 系统AXI/中断边界。
    output wire  p_m_axi_arvalid, // 系统AXI/中断边界。
    output wire  p_m_axi_awvalid, // 系统AXI/中断边界。
    output wire  p_m_axi_rready, // 系统AXI/中断边界。
    output wire  p_m_axi_wlast, // 系统AXI/中断边界。
    output wire  p_m_axi_wvalid, // 系统AXI/中断边界。
    output wire  p_m_axi_bready, // 系统AXI/中断边界。
    input wire  p_m_axi_arready, // 系统AXI/中断边界。
    input wire  p_m_axi_awready, // 系统AXI/中断边界。
    input wire  p_m_axi_rlast, // 系统AXI/中断边界。
    input wire  p_m_axi_rvalid, // 系统AXI/中断边界。
    input wire  p_m_axi_wready, // 系统AXI/中断边界。
    input wire  p_m_axi_bvalid, // 系统AXI/中断边界。
    input wire [3:0] p_m_axi_rid, // 系统AXI/中断边界。
    input wire [3:0] p_m_axi_bid, // 系统AXI/中断边界。
    input wire [127:0] p_m_axi_rdata, // 系统AXI/中断边界。
    input wire [1:0] p_m_axi_rresp, // 系统AXI/中断边界。
    input wire [1:0] p_m_axi_bresp, // 系统AXI/中断边界。
    output wire [127:0] p_m_axi_wdata, // 系统AXI/中断边界。
    output wire [15:0] p_m_axi_wstrb
);
    wire n_csr_ready,n_csr_error,p_csr_ready,p_csr_error,link_csr_ready,link_csr_error;
    wire [31:0] n_csr_rdata,p_csr_rdata,link_csr_rdata;
    always_comb begin
        csr_ready=csr_valid;csr_error=1'b1;
        case(csr_target)
            0:begin csr_ready=n_csr_ready;csr_error=n_csr_error;end
            1:begin csr_ready=p_csr_ready;csr_error=p_csr_error;end
            2:begin csr_ready=link_csr_ready;csr_error=link_csr_error;end
            default:begin end
        endcase
    end
    assign csr_rdata=({32{csr_target==0}} & n_csr_rdata) |
        ({32{csr_target==1}} & p_csr_rdata) | ({32{csr_target==2}} & link_csr_rdata);

    wire n_busy,p_busy,bridge_idle;
    wire discard,bridge_clear;
    wire [31:0] rgb_base,rgb_limit;
    assign control_idle=!(n_busy || p_busy) && bridge_idle;
    wire [127:0] stream_data;
    wire stream_valid,stream_ready,stream_start;
    wire [18:0] stream_words;
    wire [3:0] raw_m_axi_awid;
    wire [31:0] raw_m_axi_awaddr;
    wire [7:0] raw_m_axi_awlen;
    wire [2:0] raw_m_axi_awsize;
    wire [1:0] raw_m_axi_awburst;
    wire  raw_m_axi_awvalid;
    wire  raw_m_axi_awready;
    wire [127:0] raw_m_axi_wdata;
    wire [15:0] raw_m_axi_wstrb;
    wire  raw_m_axi_wlast;
    wire  raw_m_axi_wvalid;
    wire  raw_m_axi_wready;
    wire [3:0] raw_m_axi_bid;
    wire [1:0] raw_m_axi_bresp;
    wire  raw_m_axi_bvalid;
    wire  raw_m_axi_bready;
    ngm_npu_top #(.ID_W(4)) u_n(
        .clk(clk),
        .reset(reset),
        .csr_valid(csr_valid && csr_target==2'd0), .csr_write(csr_write), .csr_address(csr_address), .csr_wdata(csr_wdata), .csr_wstrb(csr_wstrb), .csr_ready(n_csr_ready), .csr_error(n_csr_error), .csr_rdata(n_csr_rdata),

        .irq(n_irq),
        .m_axi_arid(n_m_axi_arid),
        .m_axi_araddr(n_m_axi_araddr),
        .m_axi_arlen(n_m_axi_arlen),
        .m_axi_arsize(n_m_axi_arsize),
        .m_axi_arburst(n_m_axi_arburst),
        .m_axi_arvalid(n_m_axi_arvalid),
        .m_axi_arready(n_m_axi_arready),
        .m_axi_rid(n_m_axi_rid),
        .m_axi_rdata(n_m_axi_rdata),
        .m_axi_rresp(n_m_axi_rresp),
        .m_axi_rlast(n_m_axi_rlast),
        .m_axi_rvalid(n_m_axi_rvalid),
        .m_axi_rready(n_m_axi_rready),
        .m_axi_awid(raw_m_axi_awid),
        .m_axi_awaddr(raw_m_axi_awaddr),
        .m_axi_awlen(raw_m_axi_awlen),
        .m_axi_awsize(raw_m_axi_awsize),
        .m_axi_awburst(raw_m_axi_awburst),
        .m_axi_awvalid(raw_m_axi_awvalid),
        .m_axi_awready(raw_m_axi_awready),
        .m_axi_wdata(raw_m_axi_wdata),
        .m_axi_wstrb(raw_m_axi_wstrb),
        .m_axi_wlast(raw_m_axi_wlast),
        .m_axi_wvalid(raw_m_axi_wvalid),
        .m_axi_wready(raw_m_axi_wready),
        .m_axi_bid(raw_m_axi_bid),
        .m_axi_bresp(raw_m_axi_bresp),
        .m_axi_bvalid(raw_m_axi_bvalid),
        .m_axi_bready(raw_m_axi_bready),
        .task_busy(n_busy)
    );
    // Every executor/software task is a <=480 center strip plus <=8 pixels
    // per seam. Full-resolution frames are assembled in DDR across strips.
    ipx_top #(.MAX_ROW_WIDTH(512)) u_p(
        .clk(clk),
        .reset(reset),
        .csr_valid(csr_valid && csr_target==2'd1), .csr_write(csr_write), .csr_address(csr_address), .csr_wdata(csr_wdata), .csr_wstrb(csr_wstrb), .csr_ready(p_csr_ready), .csr_error(p_csr_error), .csr_rdata(p_csr_rdata),

        .irq(p_irq),
        .m_axi_arid(p_m_axi_arid),
        .m_axi_awid(p_m_axi_awid),
        .m_axi_araddr(p_m_axi_araddr),
        .m_axi_awaddr(p_m_axi_awaddr),
        .m_axi_arlen(p_m_axi_arlen),
        .m_axi_awlen(p_m_axi_awlen),
        .m_axi_arsize(p_m_axi_arsize),
        .m_axi_awsize(p_m_axi_awsize),
        .m_axi_arburst(p_m_axi_arburst),
        .m_axi_awburst(p_m_axi_awburst),
        .m_axi_arvalid(p_m_axi_arvalid),
        .m_axi_awvalid(p_m_axi_awvalid),
        .m_axi_rready(p_m_axi_rready),
        .m_axi_wlast(p_m_axi_wlast),
        .m_axi_wvalid(p_m_axi_wvalid),
        .m_axi_bready(p_m_axi_bready),
        .m_axi_arready(p_m_axi_arready),
        .m_axi_awready(p_m_axi_awready),
        .m_axi_rlast(p_m_axi_rlast),
        .m_axi_rvalid(p_m_axi_rvalid),
        .m_axi_wready(p_m_axi_wready),
        .m_axi_bvalid(p_m_axi_bvalid),
        .m_axi_rid(p_m_axi_rid),
        .m_axi_bid(p_m_axi_bid),
        .m_axi_rdata(p_m_axi_rdata),
        .m_axi_rresp(p_m_axi_rresp),
        .m_axi_bresp(p_m_axi_bresp),
        .m_axi_wdata(p_m_axi_wdata),
        .stream_data(stream_data),
        .stream_valid(stream_valid),
        .stream_ready(stream_ready),
        .stream_start(stream_start),
        .stream_words(stream_words),
        .m_axi_wstrb(p_m_axi_wstrb),
        .task_busy(p_busy)
    );
    ipx_npu_write_bridge u_bridge(
        .clk(clk),
        .reset(reset||bridge_clear),
        .credit_load(stream_start),
        .credit_words(stream_words),
        .rgb_base(rgb_base),
        .rgb_limit(rgb_limit),
        .discard(discard),
        .stream_data(stream_data),
        .stream_valid(stream_valid),
        .stream_ready(stream_ready),
        .idle(bridge_idle),
        .s_awid(raw_m_axi_awid),
        .m_awid(n_m_axi_awid),
        .s_awaddr(raw_m_axi_awaddr),
        .m_awaddr(n_m_axi_awaddr),
        .s_awlen(raw_m_axi_awlen),
        .m_awlen(n_m_axi_awlen),
        .s_awsize(raw_m_axi_awsize),
        .m_awsize(n_m_axi_awsize),
        .s_awburst(raw_m_axi_awburst),
        .m_awburst(n_m_axi_awburst),
        .s_awvalid(raw_m_axi_awvalid),
        .m_awvalid(n_m_axi_awvalid),
        .s_awready(raw_m_axi_awready),
        .m_awready(n_m_axi_awready),
        .s_wdata(raw_m_axi_wdata),
        .m_wdata(n_m_axi_wdata),
        .s_wstrb(raw_m_axi_wstrb),
        .m_wstrb(n_m_axi_wstrb),
        .s_wlast(raw_m_axi_wlast),
        .m_wlast(n_m_axi_wlast),
        .s_wvalid(raw_m_axi_wvalid),
        .m_wvalid(n_m_axi_wvalid),
        .s_wready(raw_m_axi_wready),
        .m_wready(n_m_axi_wready),
        .s_bid(raw_m_axi_bid),
        .m_bid(n_m_axi_bid),
        .s_bresp(raw_m_axi_bresp),
        .m_bresp(n_m_axi_bresp),
        .s_bvalid(raw_m_axi_bvalid),
        .m_bvalid(n_m_axi_bvalid),
        .s_bready(raw_m_axi_bready),
        .m_bready(n_m_axi_bready)
    );
    style_link_regs u_link(
        .clk(clk),.reset(reset),
        .n_busy(n_busy),.p_busy(p_busy),.bridge_idle(bridge_idle),
        .discard(discard),.bridge_clear(bridge_clear),
        .rgb_base(rgb_base),.rgb_limit(rgb_limit),
        .csr_valid(csr_valid && csr_target==2'd2), .csr_write(csr_write), .csr_address(csr_address), .csr_wdata(csr_wdata), .csr_wstrb(csr_wstrb), .csr_ready(link_csr_ready), .csr_error(link_csr_error), .csr_rdata(link_csr_rdata));
endmodule
