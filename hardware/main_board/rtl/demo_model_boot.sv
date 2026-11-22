// Read the trained model from board Flash; no ROM, RAM, or CPU DDR master.
// SPI mode 0, 5.625MHz at proc_clk=180MHz. Pause SCLK while committing each
// complete 16-byte word: never hold the DDR write grant while waiting on Flash.
module demo_model_boot #(
    parameter logic [23:0] FLASH_ADDRESS=demo_model_asset_pkg::MODEL_FLASH_BUNDLE_ADDRESS,
    parameter integer BUNDLE_BYTES=demo_model_asset_pkg::MODEL_BUNDLE_BYTES,
    parameter logic [15:0] BUNDLE_CRC16=demo_model_asset_pkg::MODEL_BUNDLE_CRC16,
    parameter integer SPI_HALF_CYCLES=16,
    parameter integer WAKE_CYCLES=18000
)(
    input logic clk,reset,ddr_ready,start,
    output logic flash_cs_n,flash_clk,flash_mosi,
    input logic flash_miso,
    output demo_bus_pkg::axi_req_t req,
    input demo_bus_pkg::axi_rsp_t rsp,
    output logic done,fault
);
    import demo_bus_pkg::*;
    localparam integer BYTE_COUNT_W=$clog2(BUNDLE_BYTES+1);
    typedef enum logic [3:0] {
        WAIT_DDR,WAKE,WAKE_WAIT,READ_CMD,READ_DATA,AW,W,B,COMPLETE
    } state_t;
    state_t state;
    logic [$clog2(SPI_HALF_CYCLES)-1:0] divider;
    logic [$clog2(WAKE_CYCLES)-1:0] wake_count;
    logic [31:0] command,address;
    logic [5:0] bit_left;
    logic [7:0] byte_shift;
    logic [3:0] byte_index;
    logic [BYTE_COUNT_W-1:0] byte_count;
    logic [127:0] data;
    logic [15:0] crc16;
    (* async_reg="true" *) logic miso_meta,miso_sample;
    always_ff @(posedge clk) begin
        miso_meta<=flash_miso;
        miso_sample<=miso_meta;
    end
    always_comb begin
        flash_mosi=command[31];
        req='0;req.awid=1;req.awaddr=address;req.awlen=0;
        req.awsize=4;req.awburst=1;req.awvalid=state==AW;
        req.wdata=data;req.wstrb=16'hffff;req.wlast=1;
        req.wvalid=state==W;req.bready=state==B;
    end
    always_ff @(posedge clk) begin
        if(reset) begin
            state<=WAIT_DDR;done<=0;fault<=0;
            flash_cs_n<=1;flash_clk<=0;command<=0;
            divider<=0;wake_count<=0;bit_left<=0;
            byte_shift<=0;byte_index<=0;byte_count<=0;
            address<=MODEL_BASE;data<=0;crc16<=16'hffff;
        end else case(state)
            WAIT_DDR:if(ddr_ready && start) begin
                flash_cs_n<=0;command<=32'hab000000;bit_left<=7;
                divider<=0;state<=WAKE;
            end
            WAKE,READ_CMD,READ_DATA:begin
                if(divider==SPI_HALF_CYCLES-1) begin
                    divider<=0;
                    if(!flash_clk) begin
                        flash_clk<=1;
                        if(state==READ_DATA) begin
                            byte_shift<={byte_shift[6:0],miso_sample};
                            // CRC-16/CCITT-FALSE updated one incoming SPI bit
                            // at a time; no byte-parallel CRC network.
                            crc16<={crc16[14:0],1'b0} ^
                                ((crc16[15]^miso_sample)?16'h1021:16'h0000);
                        end
                    end else begin
                        flash_clk<=0;command<={command[30:0],1'b0};
                        if(bit_left!=0)bit_left<=bit_left-1'b1;
                        else if(state==WAKE) begin
                            flash_cs_n<=1;wake_count<=0;state<=WAKE_WAIT;
                        end else if(state==READ_CMD) begin
                            bit_left<=7;state<=READ_DATA;
                        end else begin
                            // Low-address byte ends up in data[7:0]. Fixed
                            // shifts avoid a 16-way byte insertion selector.
                            data<={byte_shift,data[127:8]};
                            byte_count<=byte_count+1'b1;bit_left<=7;
                            if(byte_count==BUNDLE_BYTES-1)flash_cs_n<=1;
                            if(byte_index==15) begin
                                byte_index<=0;state<=AW;
                            end else byte_index<=byte_index+1'b1;
                        end
                    end
                end else divider<=divider+1'b1;
            end
            WAKE_WAIT:if(wake_count==WAKE_CYCLES-1) begin
                flash_cs_n<=0;command<={8'h03,FLASH_ADDRESS};
                bit_left<=31;divider<=0;state<=READ_CMD;
            end else wake_count<=wake_count+1'b1;
            AW:if(rsp.awready)state<=W;
            W:if(rsp.wready)state<=B;
            B:if(rsp.bvalid) begin
                if(rsp.bresp!=0) begin
                    fault<=1;flash_cs_n<=1;state<=COMPLETE;
                end else if(byte_count==BUNDLE_BYTES) begin
                    done<=crc16==BUNDLE_CRC16;
                    fault<=crc16!=BUNDLE_CRC16;state<=COMPLETE;
                end else begin
                    address<=address+16;divider<=0;state<=READ_DATA;
                end
            end
            default:state<=COMPLETE;
        endcase
    end
endmodule
