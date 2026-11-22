// Two ordered read bursts; display may pipeline two, peers keep one each.
// The registered ARREADY acknowledgement is excluded from a second display grant.
// DDR read ID is fixed to preserve return order; restore each client's ID.
// Only owner/ID metadata is queued: no data FIFOs or cross-clock signals.
// Owners change only at address handshake and final response handshake.
module demo_axi_merge #(
    parameter bit LIMIT_URGENT_BURSTS=1'b1,
    parameter bit RESERVE_DISPLAY_ROW=1'b0,
    parameter bit PIPELINE_DISPLAY=1'b0,
    parameter bit URGENT_EMPTY_ONLY=1'b0
)(
    input logic clk,reset,ddr_ready,display_urgent,capture_urgent,
    input demo_bus_pkg::axi_req_t req[4],
    output demo_bus_pkg::axi_rsp_t rsp[4],
    output demo_bus_pkg::axi_req_t mem_req,
    input demo_bus_pkg::axi_rsp_t mem_rsp,
    output logic idle
);
    import demo_bus_pkg::*;
    typedef enum logic [1:0] {W_IDLE,W_ADDR,W_DATA,W_RESP} wstate_t;
    logic ar_locked;
    logic [1:0] read_count;
    logic read_head,read_tail;
    logic [1:0] read_owner[2];
    logic [3:0] read_id[2];
    logic [3:0] read_pending;
    wire read_pop=read_count!=0 && mem_rsp.rvalid && mem_req.rready && mem_rsp.rlast;
    wire read_push=mem_req.arvalid && mem_rsp.arready;
    wstate_t ws;
    logic [1:0] ro,wo,rr,wr,rc,wc;
    logic rf,wf;
    logic display_urgent_q,capture_urgent_q;
    wire display_inflight=read_count!=0 && (read_owner[read_head]==0 || (read_count==2 && read_owner[!read_head]==0));
    // Watermarks have hundreds of beats of margin. Sample them one clock
    // before arbitration, without adding an AXI address/data pipeline stage.
    always_ff @(posedge clk)begin
        if(reset)begin display_urgent_q<=0;capture_urgent_q<=0;end
        else begin display_urgent_q<=display_urgent;capture_urgent_q<=capture_urgent;end
    end
    // Request-phase readies are registered per client, so a client's AR/AW
    // handshake no longer depends combinationally on the shared DDR ready and on
    // this arbitration. Without it, the NPU's internal request cone reaches the
    // display's request enable through this merge inside one 180MHz cycle.
    // A client whose read is still pending is excluded from arbitration until
    // its response completes, so holding VALID one extra cycle after the
    // delayed READY cannot issue a second request.
    logic [3:0] arready_d,awready_d;
    logic [3:0] arready_q,awready_q;
    logic capture_credit_q;
    logic write_urgent_q;
    always_comb begin
        arready_d='0;awready_d='0;
        if(ddr_ready&&!reset&&(ar_locked||(rf && read_count<2)))arready_d[rc]=mem_rsp.arready;
        if(ddr_ready&&!reset&&(ws==W_ADDR||(ws==W_IDLE&&wf)))awready_d[wc]=mem_rsp.awready;
    end
    always_ff @(posedge clk)begin
        if(reset)begin arready_q<=0;awready_q<=0;end
        else begin arready_q<=arready_d;awready_q<=awready_d;end
    end
    always_comb begin
        rc=rr;wc=wr;rf=0;wf=0;
        for(int k=0;k<4;k++)begin
            if(!rf&&req[2'(rr+k)].arvalid&&(!read_pending[2'(rr+k)] || (PIPELINE_DISPLAY && 2'(rr+k)==0)) &&
               !(PIPELINE_DISPLAY && 2'(rr+k)==0 && arready_q[0]))begin rc=2'(rr+k);rf=1;end
            if(!wf&&req[2'(wr+k)].awvalid)begin wc=2'(wr+k);wf=1;end
        end
        if(display_urgent_q&&(!URGENT_EMPTY_ONLY || !display_inflight)&&req[0].arvalid&&(!read_pending[0]||PIPELINE_DISPLAY)&&
           !(PIPELINE_DISPLAY&&arready_q[0]))begin rc=0;rf=1;end
        if(capture_urgent_q&&req[0].awvalid&&
           (!LIMIT_URGENT_BURSTS||capture_credit_q))begin wc=0;wf=1;end
        // Keep a row DMA's inter-burst gaps free of new peer reads. Existing
        // responses and a stalled, locked AR must still complete normally.
        if(RESERVE_DISPLAY_ROW && display_urgent_q && rc!=0)rf=0;
        if(ar_locked)rc=ro;
        if(ws!=W_IDLE)wc=wo;
        mem_req='0;
        // Payload may be broadcast; only VALID/READY identify its owner.
        for(int k=0;k<4;k++)begin
            rsp[k]='0;
            rsp[k].arready=arready_q[k];rsp[k].awready=awready_q[k];
            rsp[k].rid=read_id[read_head];rsp[k].rdata=mem_rsp.rdata;
            rsp[k].rresp=mem_rsp.rresp;rsp[k].rlast=mem_rsp.rlast;
            rsp[k].bid=mem_rsp.bid;rsp[k].bresp=mem_rsp.bresp;
        end
        mem_req.arid=4'd0;mem_req.araddr=req[rc].araddr;
        mem_req.arlen=req[rc].arlen;mem_req.arsize=req[rc].arsize;
        mem_req.arburst=req[rc].arburst;
        if(ddr_ready&&!reset&&(ar_locked||(rf && read_count<2)))begin
            mem_req.arvalid=req[rc].arvalid;
        end
        if(read_count!=0)begin
            rsp[read_owner[read_head]].rvalid=mem_rsp.rvalid;
            mem_req.rready=req[read_owner[read_head]].rready;
        end
        mem_req.awid=req[wc].awid;mem_req.awaddr=req[wc].awaddr;
        mem_req.awlen=req[wc].awlen;mem_req.awsize=req[wc].awsize;
        mem_req.awburst=req[wc].awburst;
        if(ddr_ready&&!reset&&(ws==W_ADDR||(ws==W_IDLE&&wf)))begin
            mem_req.awvalid=req[wc].awvalid;
        end
        mem_req.wdata=req[wo].wdata;mem_req.wstrb=req[wo].wstrb;
        mem_req.wlast=req[wo].wlast;
        if(ws==W_DATA)begin
            mem_req.wvalid=req[wo].wvalid;
            rsp[wo].wready=mem_rsp.wready;
        end
        if(ws==W_RESP)begin
            rsp[wo].bvalid=mem_rsp.bvalid;mem_req.bready=req[wo].bready;
        end
        idle=!ar_locked&&read_count==0&&ws==W_IDLE;
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            ar_locked<=0;read_count<=0;read_head<=0;read_tail<=0;read_pending<=0;
            read_owner[0]<=0;read_owner[1]<=0;read_id[0]<=0;read_id[1]<=0;
            ws<=W_IDLE;ro<=0;wo<=0;rr<=0;wr<=0;write_urgent_q<=0;
            capture_credit_q<=1;
        end
        else begin
            // Consume capture urgency only on a real DDR address handshake.
            // One accepted peer write restores the credit, while normal
            // round-robin advances among peers; AW/W/B ownership stays locked.
            if(LIMIT_URGENT_BURSTS&&
               ((ws==W_IDLE&&ddr_ready&&wf&&mem_req.awvalid&&mem_rsp.awready)||
                (ws==W_ADDR&&mem_req.awvalid&&mem_rsp.awready)))begin
                if(ws==W_IDLE)begin
                    if(wc==0&&capture_urgent_q&&capture_credit_q)capture_credit_q<=0;
                    else if(wc!=0)capture_credit_q<=1;
                end else begin
                    if(write_urgent_q&&capture_urgent_q)capture_credit_q<=0;
                    else if(wo!=0)capture_credit_q<=1;
                end
                write_urgent_q<=0;
            end
            if(!ar_locked && mem_req.arvalid && !mem_rsp.arready)begin ar_locked<=1;ro<=rc;end
            if(read_push)begin
                ar_locked<=0;rr<=rc+1'b1;
                read_owner[read_tail]<=rc;read_id[read_tail]<=req[rc].arid;read_tail<=!read_tail;
            end
            if(read_pop)read_head<=!read_head;
            case({read_push,read_pop})
                2'b10:read_count<=read_count+1'b1;
                2'b01:read_count<=read_count-1'b1;
                default:begin end
            endcase
            for(int k=0;k<4;k++)begin
                if(read_pop && read_owner[read_head]==2'(k))read_pending[k]<=0;
                if(read_push && rc==2'(k))read_pending[k]<=1;
            end
            if(ws==W_IDLE&&ddr_ready&&wf)begin
                wo<=wc;
                write_urgent_q<=!(mem_req.awvalid&&mem_rsp.awready)&&
                                 wc==0&&capture_urgent_q&&capture_credit_q;
                if(mem_req.awvalid&&mem_rsp.awready)begin ws<=W_DATA;wr<=wc+1'b1;end
                else ws<=W_ADDR;
            end else if(ws==W_ADDR&&mem_req.awvalid&&mem_rsp.awready)begin
                ws<=W_DATA;wr<=wo+1'b1;
            end else if(ws==W_DATA&&mem_req.wvalid&&mem_rsp.wready&&mem_req.wlast)ws<=W_RESP;
            else if(ws==W_RESP&&mem_rsp.bvalid&&mem_req.bready)ws<=W_IDLE;
        end
    end
endmodule
