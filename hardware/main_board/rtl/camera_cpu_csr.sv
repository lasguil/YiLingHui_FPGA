// Small CPU-owned camera gate/status block. Configuration data is sampled
// with the AE toggle, and capture/mode requests may be committed on VS blank.
module camera_cpu_csr(
    input  wire        clk,reset_n,
    input  wire [15:0] paddr,
    input  wire        psel,penable,pwrite,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,pslverror,
    input  wire        ae_toggle_async,
    input  wire        wave_left,
    input  wire [1:0]  ae_action_async,
    input  wire        vs_async,
    input  wire        rx_effective,
    input  wire        capture_effective,
    output wire        config_ready,
    output wire        rx_enable,
    output wire        capture_enable,
    output wire        camera_fault,
    output wire        switching,
    output reg  [1:0]  mode_active,
    output wire        bayer_y_xor
);
    reg ready_reg,rx_reg,capture_reg,fault_reg,switching_reg,bayer_y_xor_reg;
    reg [1:0] boundary_mode;
    reg boundary_capture,boundary_pending,boundary_ack;
    (* async_reg="true" *) reg ae_toggle_meta,ae_toggle_sync;
    (* async_reg="true" *) reg [1:0] ae_action_meta,ae_action_sync;
    reg ae_toggle_seen,ae_event_toggle,ae_pending,ae_pending_toggle;
    reg [1:0] ae_event_action;
    (* async_reg="true" *) reg vs_meta,vs_sync;
    reg vs_d;
    reg [31:0] vs_count;
    (* async_reg="true" *) reg rx_ack_meta,rx_ack_sync;
    (* async_reg="true" *) reg cap_ack_meta,cap_ack_sync;
    wire access=psel&&penable;
    wire control_addr=(paddr[7:2]==6'd3)&&(paddr[1:0]==2'b00);
    wire control_fault=pwdata[3]||fault_reg;
    wire next_ready=pwdata[0];
    wire next_rx=pwdata[2];
    wire next_capture=pwdata[1];
    wire fault_shutdown=pwdata[3]&&!next_ready&&!next_rx&&!next_capture;
    wire write_ok=control_addr && (!boundary_pending||fault_shutdown) &&
        (!(next_ready||next_rx||next_capture)||!control_fault) &&
        (!next_rx||next_ready) &&
        (!next_capture||(next_ready&&next_rx));
    assign pready=access;
    assign pslverror=access && ((paddr[1:0]!=0) ||
        (pwrite ? !write_ok : (paddr[7:2]>6'd4)));
    assign config_ready=ready_reg&&!fault_reg;
    assign rx_enable=rx_reg&&config_ready;
    assign capture_enable=capture_reg&&rx_enable;
    assign camera_fault=fault_reg;
    assign switching=switching_reg;
    assign bayer_y_xor=bayer_y_xor_reg;
    always @* begin
        case(paddr[7:2])
            0:prdata={23'd0,wave_left,boundary_ack,mode_active,switching_reg,fault_reg,
                      cap_ack_sync,rx_ack_sync,ready_reg};
            1:prdata={29'd0,ae_event_action,ae_event_toggle};
            2:prdata=vs_count;
            3:prdata={24'd0,bayer_y_xor_reg,mode_active,switching_reg,fault_reg,
                      rx_reg,capture_reg,ready_reg};
            4:prdata={29'd0,ae_action_sync,ae_toggle_sync};
            default:prdata=32'd0;
        endcase
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin
            ready_reg<=0;rx_reg<=0;capture_reg<=0;fault_reg<=0;
            switching_reg<=0;bayer_y_xor_reg<=0;mode_active<=2'd2;boundary_mode<=2'd2;
            boundary_capture<=0;boundary_pending<=0;boundary_ack<=0;
        end else begin
            if(access&&pwrite&&!pslverror&&control_addr)begin
                ready_reg<=pwdata[0];rx_reg<=pwdata[2];bayer_y_xor_reg<=pwdata[7];
                if(pwdata[3])begin
                    fault_reg<=1;capture_reg<=0;switching_reg<=0;boundary_pending<=0;
                end else if(pwdata[4]&&!switching_reg)begin
                    boundary_capture<=pwdata[1];boundary_mode<=pwdata[6:5];
                    switching_reg<=1;boundary_pending<=1;
                end else begin
                    capture_reg<=pwdata[1];mode_active<=pwdata[6:5];
                    switching_reg<=pwdata[4];
                end
            end
            if(vs_d&&!vs_sync&&boundary_pending)begin
                capture_reg<=boundary_capture;mode_active<=boundary_mode;
                boundary_pending<=0;boundary_ack<=~boundary_ack;
            end
        end
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin
            ae_toggle_meta<=0;ae_toggle_sync<=0;ae_action_meta<=0;ae_action_sync<=0;
            ae_toggle_seen<=0;ae_event_toggle<=0;ae_event_action<=0;
            ae_pending<=0;ae_pending_toggle<=0;
            vs_meta<=0;vs_sync<=0;vs_d<=0;vs_count<=0;
            rx_ack_meta<=0;rx_ack_sync<=0;cap_ack_meta<=0;cap_ack_sync<=0;
        end else begin
            ae_toggle_meta<=ae_toggle_async;ae_toggle_sync<=ae_toggle_meta;
            ae_action_meta<=ae_action_async;ae_action_sync<=ae_action_meta;
            if(ae_pending)begin
                ae_pending<=0;ae_toggle_seen<=ae_pending_toggle;
                ae_event_toggle<=ae_pending_toggle;ae_event_action<=ae_action_sync;
            end else if(ae_toggle_sync!=ae_toggle_seen)begin
                ae_pending<=1;ae_pending_toggle<=ae_toggle_sync;
            end
            vs_meta<=vs_async;vs_sync<=vs_meta;vs_d<=vs_sync;
            if(vs_d&&!vs_sync)vs_count<=vs_count+1'b1;
            rx_ack_meta<=rx_effective;rx_ack_sync<=rx_ack_meta;
            cap_ack_meta<=capture_effective;cap_ack_sync<=cap_ack_meta;
        end
    end
endmodule
