// One common descriptor, no AXI-Lite channels or duplicate slave latches.
module style_reg_master(
    input logic clk,reset,op_valid,op_read,
    input logic [1:0] op_target,
    input logic [11:0] op_address,
    input logic [31:0] op_data,
    output wire op_ready,done,error,
    output wire [31:0] read_data,
    output demo_bus_pkg::csr_req_t req,
    input demo_bus_pkg::csr_rsp_t rsp
);
    logic pending,write_q;
    logic [1:0] target_q;
    logic [11:0] address_q;
    logic [31:0] data_q;
    assign op_ready=!pending;
    assign done=pending && rsp.ready;
    assign error=rsp.error;
    assign read_data=rsp.rdata;
    always_comb begin
        req='0;req.valid=pending;req.write=write_q;
        req.target=target_q;req.address=address_q;
        req.wdata=data_q;req.wstrb=4'hf;
    end
    always_ff @(posedge clk)begin
        if(reset)begin pending<=0;write_q<=0;target_q<=0;address_q<=0;data_q<=0;end
        else if(done)pending<=0;
        else if(op_valid && op_ready)begin
            pending<=1;write_q<=!op_read;target_q<=op_target;
            address_q<=op_address;data_q<=op_data;
        end
    end
endmodule
