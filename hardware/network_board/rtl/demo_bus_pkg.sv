package demo_bus_pkg;
    typedef struct packed {
        logic [3:0] arid;
        logic [31:0] araddr;
        logic [7:0] arlen;
        logic [2:0] arsize;
        logic [1:0] arburst;
        logic arvalid,rready;
        logic [3:0] awid;
        logic [31:0] awaddr;
        logic [7:0] awlen;
        logic [2:0] awsize;
        logic [1:0] awburst;
        logic awvalid;
        logic [127:0] wdata;
        logic [15:0] wstrb;
        logic wlast,wvalid,bready;
    } axi_req_t;
    typedef struct packed {
        logic arready;
        logic [3:0] rid;
        logic [127:0] rdata;
        logic [1:0] rresp;
        logic rlast,rvalid,awready,wready;
        logic [3:0] bid;
        logic [1:0] bresp;
        logic bvalid;
    } axi_rsp_t;
    // Stable descriptor until ready; ready completes exactly one operation.
    typedef struct packed {
        logic valid,write;
        logic [1:0] target;
        logic [11:0] address;
        logic [31:0] wdata;
        logic [3:0] wstrb;
    } csr_req_t;
    typedef struct packed {
        logic ready,error;
        logic [31:0] rdata;
    } csr_rsp_t;
    // Four MiB slots fit the maximum 1080p payload (0x3f4800).
    // Camera triple buffers end at 0x00bdf000, before the virtual RGB slot.
    localparam logic [31:0] MODEL_BASE=32'h01c00000;
    localparam logic [31:0] X0_BASE=32'h01000000;
    localparam logic [31:0] NPU_BASE=32'h00c00000;
    localparam logic [31:0] FINAL_A=32'h01400000,FINAL_B=32'h01800000;
    localparam logic [31:0] RGB_BYTES=32'd829440;
    function automatic logic [31:0] video_size(input logic [1:0] mode);
        case(mode)
            0:video_size={16'd1080,16'd1920};
            1:video_size={16'd720,16'd1280};
            default:video_size={16'd480,16'd854};
        endcase
    endfunction
    function automatic logic [15:0] video_stride(input logic [1:0] mode);
        case(mode) 0:video_stride=3840;1:video_stride=2560;default:video_stride=1728;endcase
    endfunction
    function automatic logic [15:0] video_x0_stride(input logic [1:0] mode);
        case(mode) 0:video_x0_stride=15360;1:video_x0_stride=10240;default:video_x0_stride=6848;endcase
    endfunction
    function automatic logic [31:0] video_bytes(input logic [1:0] mode);
        case(mode) 0:video_bytes=4147200;1:video_bytes=1843200;default:video_bytes=829440;endcase
    endfunction
endpackage
