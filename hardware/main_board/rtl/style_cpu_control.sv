// CPU APB -> one held request/response mailbox -> one native register bus (three address windows).
// CPU owns model/frame policy; the executor only runs a submitted frame. No DDR master.
module style_cpu_control(
    input wire cpu_clk,cpu_reset_n,clk,reset_n,
    input wire [15:0] paddr,
    input wire psel,penable,pwrite,
    input wire [31:0] pwdata,
    output logic [31:0] prdata,
    output wire pready,pslverror,cpu_irq,
    input wire ddr_ready,boot_done,boot_fault,control_idle,n_irq,p_irq,axi_fault,
    input wire camera_valid,
    input wire [15:0] camera_sequence,
    input wire [1:0] camera_bank,
    input wire [31:0] camera_base,display_active_base,
    input wire [1:0] camera_mode,camera_mode_active,
    input wire camera_switching,camera_fault,
    output logic [1:0] mode_request,display_mode,
    output logic mode_toggle,
    output logic boot_start,camera_lock,display_valid,fault,
    output logic [1:0] camera_locked_bank,
    output logic display_source_pending,
    output logic [1:0] display_source_pending_bank,
    output logic [31:0] display_base,
    output logic [15:0] completed_frames,
    output logic [31:0] dbg_mbox,
    output demo_bus_pkg::csr_req_t req,
    input demo_bus_pkg::csr_rsp_t rsp
);
    import demo_bus_pkg::*;
    wire mailbox_reset=!(cpu_reset_n && reset_n);
    logic request_level,ack_level;
    logic boot_requested; // a SYS_LOAD_FLASH command is waiting for the pipeline to be free
    logic sticky_0108;   // bring-up: latched, a 0x0108 write was presented
    logic [1:0] sticky_state,sticky_dh;          // condition snapshot (proc-side)
    logic sticky_rs;                             // request_sync at that moment
    logic [4:0] sticky_cond;                     // ddr_ready,camera_lock,display_pending,control_idle,fault
    wire request_meta,request_sync,ack_meta,ack_sync;
    // Explicit FFs keep the CDC endpoints stable; a synchronizer must not
    // silently turn into a shift RAM when adding the routed constraints.
    EFX_FF request_head(.D(request_level),.CE(1'b1),.CLK(clk),.SR(mailbox_reset),.Q(request_meta));
    EFX_FF request_tail(.D(request_meta),.CE(1'b1),.CLK(clk),.SR(mailbox_reset),.Q(request_sync));
    EFX_FF ack_head(.D(ack_level),.CE(1'b1),.CLK(cpu_clk),.SR(mailbox_reset),.Q(ack_meta));
    EFX_FF ack_tail(.D(ack_meta),.CE(1'b1),.CLK(cpu_clk),.SR(mailbox_reset),.Q(ack_sync));
    // Assertion cancels the mailbox immediately; deassert on local clocks.
    logic [1:0] cpu_release,proc_release;
    always_ff @(posedge cpu_clk or posedge mailbox_reset)
        if(mailbox_reset)cpu_release<=0;else cpu_release<={cpu_release[0],1'b1};
    always_ff @(posedge clk or posedge mailbox_reset)
        if(mailbox_reset)proc_release<=0;else proc_release<={proc_release[0],1'b1};
    typedef enum logic [1:0]{CPU_IDLE,CPU_WAIT,CPU_RETURN} cpu_state_t;
    cpu_state_t cpu_state;
    logic [15:0] address_hold;
    logic write_hold;
    logic [31:0] data_hold,response_hold;
    logic response_error;
    wire cpu_access=psel && penable;
    assign pready=cpu_access && (!cpu_release[1] || (cpu_state==CPU_WAIT && ack_sync));
    assign pslverror=pready && (!cpu_release[1] || response_error);
    always_comb prdata=cpu_release[1] ? response_hold : 32'd0;
    always_ff @(posedge cpu_clk or posedge mailbox_reset)begin
        if(mailbox_reset)begin
            cpu_state<=CPU_IDLE;request_level<=0;address_hold<=0;write_hold<=0;data_hold<=0;
        end else case(cpu_state)
            CPU_IDLE:if(cpu_access && cpu_release[1])begin
                address_hold<=paddr;write_hold<=pwrite;data_hold<=pwdata;
                request_level<=1;cpu_state<=CPU_WAIT;
            end
            CPU_WAIT:if(cpu_access && ack_sync)begin request_level<=0;cpu_state<=CPU_RETURN;end
            CPU_RETURN:if(!ack_sync)cpu_state<=CPU_IDLE;
            default:cpu_state<=CPU_IDLE;
        endcase
    end
    typedef enum logic [1:0]{IDLE,CSR_ISSUE,CSR_WAIT,RESPONSE} state_t;
    state_t state;
    logic [15:0] claimed_sequence;
    logic [31:0] claimed_base,target_base;
    logic display_pending;
    // A published result's camera source remains reserved after the NPU lock
    // is released, until the drained display bundle makes it active.
    logic [31:0] claim_target;
    logic claim_slot_available;
    logic [1:0] claimed_mode;
    logic mode_busy;
    logic [15:0] mode_sequence;
    wire csr_ready,csr_done,csr_error;
    wire [31:0] read_data;
    wire frame_busy,frame_done,frame_fault;
    wire op_ready=csr_ready && !frame_busy;
    wire op_done=csr_done && !frame_busy;
    wire op_error=csr_error;
    wire frame_op_valid,frame_op_read;
    wire [1:0] frame_op_target;
    wire [11:0] frame_op_address;
    wire [31:0] frame_op_data;
    logic frame_start,frame_clear;
    wire [31:0] frame_size=video_size(claimed_mode);
    wire mode_write_ok=!camera_lock && !display_pending && control_idle &&
        !frame_busy && !frame_start && !mode_busy && csr_ready && !fault && !camera_fault;
    always_comb begin
        claim_target=FINAL_A;
        claim_slot_available=1'b0;
        if(display_active_base!=FINAL_A && (!display_pending || display_base!=FINAL_A))begin
            claim_target=FINAL_A;claim_slot_available=1'b1;
        end else if(display_active_base!=FINAL_B && (!display_pending || display_base!=FINAL_B))begin
            claim_target=FINAL_B;claim_slot_available=1'b1;
        end else if(display_active_base!=FINAL_C && (!display_pending || display_base!=FINAL_C))begin
            claim_target=FINAL_C;claim_slot_available=1'b1;
        end
    end
    wire claim_ok=boot_done && !boot_fault && !fault && !camera_fault && camera_valid &&
        !camera_lock && claim_slot_available && control_idle && !mode_busy &&
        !camera_switching && camera_mode==mode_request && camera_mode_active==mode_request;
    wire frame_launch_ok=camera_lock && control_idle && !frame_busy && !mode_busy && !fault &&
        !axi_fault && !boot_fault && !camera_fault;
    // SYS_STREAM (0x154) is a compatibility slot; the data path is always streaming.
    assign cpu_irq=(n_irq && !camera_lock) || frame_done || frame_fault || boot_fault || fault;
    style_frame_executor u_frame(.clk(clk),.reset(!reset_n),.start(frame_start),.clear_done(frame_clear),
        .original(claimed_base),.npu_rgb(NPU_BASE),.final_base(target_base),
        .x0(X0_BASE),.rgb_bytes(video_bytes(claimed_mode)),.visible_width(frame_size[15:0]),.height(frame_size[31:16]),
        .rgb_stride(video_stride(claimed_mode)),.x0_stride(video_x0_stride(claimed_mode)),.busy(frame_busy),.done(frame_done),.fault(frame_fault),
        .op_valid(frame_op_valid),.op_read(frame_op_read),.op_target(frame_op_target),
        .op_address(frame_op_address),.op_data(frame_op_data),.op_ready(csr_ready && frame_busy),
        .op_done(csr_done && frame_busy),.op_error(csr_error),.read_data(read_data));
    wire [1:0] csr_target=address_hold[13:12]-2'd1;
    style_reg_master u_csr(.clk(clk),.reset(!reset_n),
        .op_valid(frame_busy ? frame_op_valid : state==CSR_ISSUE),
        .op_read(frame_busy ? frame_op_read : !write_hold),
        .op_target(frame_busy ? frame_op_target : csr_target),
        .op_address(frame_busy ? frame_op_address : address_hold[11:0]),
        .op_data(frame_busy ? frame_op_data : data_hold),
        .op_ready(csr_ready),.done(csr_done),.error(csr_error),.read_data(read_data),.req(req),.rsp(rsp));
    // Mutually exclusive address selects: parallel masked read mux, no priority chain.
    wire [23:0] sys_read_select;
    assign sys_read_select[0]=address_hold==16'h0100;
    assign sys_read_select[1]=address_hold==16'h0104;
    assign sys_read_select[2]=address_hold==16'h010c;
    assign sys_read_select[3]=address_hold==16'h0110;
    assign sys_read_select[4]=address_hold==16'h0114;
    assign sys_read_select[5]=address_hold==16'h0118;
    assign sys_read_select[6]=address_hold==16'h011c;
    assign sys_read_select[7]=address_hold==16'h0120;
    assign sys_read_select[8]=address_hold==16'h0124;
    assign sys_read_select[9]=address_hold==16'h0128;
    assign sys_read_select[10]=address_hold==16'h012c;
    assign sys_read_select[11]=address_hold==16'h0130;
    assign sys_read_select[12]=address_hold==16'h0134;
    assign sys_read_select[13]=address_hold==16'h0138;
    assign sys_read_select[14]=address_hold==16'h013c;
    assign sys_read_select[15]=address_hold==16'h0160;
    assign sys_read_select[16]=address_hold==16'h0164;
    assign sys_read_select[17]=address_hold==16'h0140;
    assign sys_read_select[18]=address_hold==16'h0144;
    assign sys_read_select[19]=address_hold==16'h0148;
    assign sys_read_select[20]=address_hold==16'h014c;
    assign sys_read_select[21]=address_hold==16'h0150;
    assign sys_read_select[22]=address_hold==16'h0154;
    assign sys_read_select[23]=address_hold==16'h0158;
    wire [31:0] sys_read_data=
        ({32{sys_read_select[0]}} & (32'h53594302)) |
        ({32{sys_read_select[1]}} & ({21'd0,frame_fault,frame_done,frame_busy,display_valid,camera_valid,fault,display_pending,
                                                camera_lock,boot_fault,boot_done,ddr_ready})) |
        ({32{sys_read_select[2]}} & ({16'd0,claimed_sequence})) |
        ({32{sys_read_select[3]}} & (claimed_base)) |
        ({32{sys_read_select[4]}} & ({30'd0,camera_locked_bank})) |
        ({32{sys_read_select[5]}} & (target_base)) |
        ({32{sys_read_select[6]}} & (display_active_base)) |
        ({32{sys_read_select[7]}} & ({16'd0,completed_frames})) |
        ({32{sys_read_select[8]}} & ({30'd0,p_irq,n_irq})) |
        ({32{sys_read_select[9]}} & ({31'd0,fault})) |
        ({32{sys_read_select[10]}} & ({16'd0,camera_sequence})) |
        ({32{sys_read_select[11]}} & (video_size(camera_mode))) |
        ({32{sys_read_select[12]}} & ({30'd0,mode_request})) |
        ({32{sys_read_select[13]}} & ({30'd0,camera_mode_active})) |
        ({32{sys_read_select[14]}} & ({29'd0,camera_fault,camera_switching,mode_busy})) |
        ({32{sys_read_select[15]}} & ({30'd0,camera_mode})) |
        ({32{sys_read_select[16]}} & ({30'd0,claimed_mode})) |
        ({32{sys_read_select[17]}} & (NPU_BASE)) |
        ({32{sys_read_select[18]}} & (X0_BASE)) |
        ({32{sys_read_select[19]}} & ({16'd0,video_stride(mode_request)})) |
        ({32{sys_read_select[20]}} & ({16'd0,video_x0_stride(mode_request)})) |
        ({32{sys_read_select[21]}} & (video_size(mode_request))) |
        ({32{sys_read_select[22]}} & (32'd1)) |
        ({32{sys_read_select[23]}} & (video_bytes(mode_request)));
    // bring-up: whole mailbox state in one readable word.
    // bring-up word: raw APB inputs plus the latches, so a single read says whether
    // the CPU write even reaches this module, and whether the FSM is being reset.
    assign dbg_mbox={8'b0,sticky_0108,boot_start,sticky_state,sticky_rs,sticky_dh,
                     sticky_cond,12'b0};

    always_ff @(posedge clk) begin
        if(mailbox_reset)begin sticky_0108<=1'b0;sticky_state<=0;sticky_rs<=0;sticky_dh<=0;sticky_cond<=0;end
        else if(request_sync && write_hold && address_hold==16'h0108) begin
            // Proc-side view: the first cycle the boot_start condition is evaluated.
            sticky_state<=state; sticky_rs<=request_sync; sticky_dh<=data_hold[1:0];
            sticky_cond<={ddr_ready,camera_lock,display_pending,control_idle,fault};
            sticky_0108<=1'b1;
        end
    end
    // Ownership registers have the processing reset, not the CPU reset.
    // A CPU-only restart must not release a camera bank still being read.
    always_ff @(posedge clk or negedge reset_n)begin
        if(!reset_n)begin
            boot_start<=0;camera_lock<=0;camera_locked_bank<=0;
            claimed_base<=0;claimed_sequence<=0;target_base<=FINAL_A;
            display_valid<=0;display_base<=FINAL_A;display_pending<=0;
            display_source_pending<=0;display_source_pending_bank<=0;
            completed_frames<=0;fault<=0;frame_start<=0;frame_clear<=0;boot_requested<=0;
            mode_request<=2;mode_toggle<=0;mode_busy<=1;mode_sequence<=0;
            display_mode<=2;claimed_mode<=2;
        end else begin
            frame_start<=0;frame_clear<=0;
            if(boot_fault || axi_fault || frame_fault || camera_fault)fault<=1;
            if(mode_busy && camera_valid && camera_sequence!=mode_sequence &&
               camera_mode==mode_request && camera_mode_active==mode_request && !camera_switching)
                mode_busy<=0;
            if(display_pending && display_active_base==display_base)begin
                display_pending<=0;
                display_source_pending<=0;
            end
            // Deferred load start: fires as soon as the accelerator can take it,
            // so a request that arrived while busy is honoured rather than lost.
            if(boot_requested && ddr_ready && !camera_lock && !display_pending && control_idle && !fault)begin
                boot_start<=1'b1; boot_requested<=1'b0;
            end
            if(state==IDLE && request_sync && proc_release[1] && write_hold && address_hold[1:0]==0)begin
                case(address_hold)
                    16'h0108:begin
                        // Record the load request instead of acting on it in this
                        // same cycle. The accelerator can be momentarily busy
                        // (control_idle low) and the CPU issues this command only
                        // once, so dropping it would deadlock the boot wait.
                        if(data_hold==1) boot_requested<=1'b1;
                        if(data_hold==2 && claim_ok)begin
                            camera_lock<=1;camera_locked_bank<=camera_bank;
                            claimed_base<=camera_base;claimed_sequence<=camera_sequence;
                            claimed_mode<=camera_mode;
                            target_base<=claim_target;
                        end
                        if(data_hold==4 && camera_lock && frame_done && !frame_busy &&
                           !display_pending && control_idle && !fault && !axi_fault && !boot_fault)begin
                            display_base<=target_base;display_valid<=1;display_pending<=1;
                            display_source_pending<=1;display_source_pending_bank<=camera_locked_bank;
                            display_mode<=claimed_mode;
                            completed_frames<=completed_frames+1'b1;camera_lock<=0;frame_clear<=1;
                        end
                        if(data_hold==8 && camera_lock && control_idle && !frame_busy)begin camera_lock<=0;frame_clear<=1;end
                        if(data_hold==16 && frame_launch_ok)frame_start<=1;
                    end
                    16'h0134:if(data_hold[31:2]==0 && mode_write_ok && data_hold[1:0]!=mode_request)begin
                        mode_request<=data_hold[1:0];mode_toggle<=!mode_toggle;
                        mode_busy<=1;mode_sequence<=camera_sequence;
                    end
                    16'h0128:if(data_hold==1)fault<=1;
                    16'h0154:begin end // Compatibility write; no path selector exists.
                    default:begin end
                endcase
            end
        end
    end
    always_ff @(posedge clk or posedge mailbox_reset)begin
        if(mailbox_reset)begin state<=IDLE;ack_level<=0;response_hold<=0;response_error<=0;end
        else case(state)
            IDLE:if(request_sync && proc_release[1])begin
                response_hold<=0;response_error<=0;
                if(address_hold[1:0]!=0)begin response_error<=1;ack_level<=1;state<=RESPONSE;end
                else if(address_hold[15:14]==0 && address_hold[13:12]!=0)begin
                    if(frame_busy || frame_start)begin response_error<=1;ack_level<=1;state<=RESPONSE;end
                    else state<=CSR_ISSUE;
                end
                else begin
                    state<=RESPONSE;ack_level<=1;
                    if(write_hold)case(address_hold)
                        16'h0108:case(data_hold)
                            1:response_error<=!(ddr_ready && !camera_lock && !display_pending && control_idle && !fault);
                            2:response_error<=!claim_ok;
                            4:response_error<=!(camera_lock && frame_done && !frame_busy && !display_pending &&
                                                control_idle && !fault && !axi_fault && !boot_fault);
                            8:response_error<=!(camera_lock && control_idle && !frame_busy);
                            16:response_error<=!frame_launch_ok;
                            default:response_error<=1;
                        endcase
                        16'h0128:response_error<=data_hold!=1;
                        16'h0134:response_error<=data_hold[31:2]!=0 || !mode_write_ok;
                        16'h0154:response_error<=frame_busy || !control_idle;
                        default:response_error<=1;
                    endcase
                    else begin
                        response_hold<=sys_read_data;
                        response_error<=!(|sys_read_select);
                    end
                end
            end
            CSR_ISSUE:if(op_ready)state<=CSR_WAIT;
            CSR_WAIT:if(op_done)begin response_hold<=read_data;response_error<=op_error;ack_level<=1;state<=RESPONSE;end
            RESPONSE:if(!request_sync)begin ack_level<=0;state<=IDLE;end
            default:state<=IDLE;
        endcase
    end
endmodule
