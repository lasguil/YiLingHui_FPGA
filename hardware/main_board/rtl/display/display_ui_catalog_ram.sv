// One byte-wide dual-clock catalog shared by model/table strings.
// CPU initialization completes before ui_enable is asserted; runtime writes
// are restricted by firmware to slots absent from displayed/desired metadata.
// The independent CPU/pixel clocks make same-address read/write undefined;
// firmware and the UI publication protocol prohibit that collision.
module display_ui_catalog_ram (
    input  logic       wr_clk,
    input  logic       wr_en,
    input  logic [demo_model_asset_pkg::MODEL_CATALOG_ADDR_WIDTH-1:0] wr_addr,
    input  logic [7:0] wr_data,
    input  logic       rd_clk,
    input  logic       rd_en,
    input  logic [demo_model_asset_pkg::MODEL_CATALOG_ADDR_WIDTH-1:0] rd_addr,
    output logic [7:0] rd_data
);
    localparam [255:0] INIT_0={32{8'h20}};
    localparam [255:0] INIT_1={32{8'h20}};
    localparam [255:0] INIT_2={32{8'h20}};
    localparam [255:0] INIT_3={32{8'h20}};
    localparam [255:0] INIT_4={32{8'h20}};
    localparam [255:0] INIT_5={32{8'h20}};
    localparam [255:0] INIT_6={32{8'h20}};
    localparam [255:0] INIT_7={32{8'h20}};
    localparam [255:0] INIT_8={32{8'h20}};
    localparam [255:0] INIT_9={32{8'h20}};
    localparam [255:0] INIT_A={32{8'h20}};
    localparam [255:0] INIT_B={32{8'h20}};
    localparam [255:0] INIT_C={32{8'h20}};
    localparam [255:0] INIT_D={32{8'h20}};
    localparam [255:0] INIT_E={32{8'h20}};
    localparam [255:0] INIT_F={32{8'h20}};

    EFX_RAM10 #(.READ_WIDTH(8),.WRITE_WIDTH(8),.OUTPUT_REG(1'b0),
        .WRITE_MODE("READ_UNKNOWN"),
        .INIT_0(INIT_0),.INIT_1(INIT_1),.INIT_2(INIT_2),.INIT_3(INIT_3),
        .INIT_4(INIT_4),.INIT_5(INIT_5),.INIT_6(INIT_6),.INIT_7(INIT_7),
        .INIT_8(INIT_8),.INIT_9(INIT_9),.INIT_A(INIT_A),.INIT_B(INIT_B),
        .INIT_C(INIT_C),.INIT_D(INIT_D),.INIT_E(INIT_E),.INIT_F(INIT_F)) u_catalog (
        .WCLK(wr_clk),.WE({2{wr_en}}),.WCLKE(wr_en),.WADDREN(1'b1),
        .WDATA(wr_data),.WADDR(wr_addr),
        .RCLK(rd_clk),.RE(rd_en),.RST(1'b0),.RADDREN(1'b1),
        .RDATA(rd_data),.RADDR(rd_addr)
    );
endmodule
