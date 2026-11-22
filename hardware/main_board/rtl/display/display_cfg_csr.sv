// CPU-visible display configuration bank with atomic cfg_clk -> pix_clk commit.
// A COMMIT snapshots the shadow registers; the pixel side applies the bundle
// only on a rising VS edge and acknowledges after capture.
module display_cfg_csr (
    input  logic        cfg_clk,
    input  logic        cfg_rst_n,
    input  logic        cfg_valid,
    input  logic        cfg_write,
    input  logic [11:0] cfg_addr,
    input  logic [31:0] cfg_wdata,
    input  logic [3:0]  cfg_wstrb,
    output logic        cfg_ready,
    output logic        cfg_error,
    output logic [31:0] cfg_rdata,

    input  logic        pix_clk,
    input  logic        pix_rst_n,
    input  logic        in_vs,
    input  logic        pix_line_start,
    input  logic [3:0]  diagnostics_status,
    input  logic        underflow_a_event,
    input  logic        underflow_b_event,
    input  logic [11:0] underflow_a_x,underflow_a_y,
    input  logic [11:0] underflow_b_x,underflow_b_y,
    output logic [1:0]  scene_mode,
    output logic [31:0] base_a, base_b,
    output logic [15:0] stride_a, stride_b,
    output logic [11:0] source_width, source_height, source_x, source_y,
    output logic [11:0] dest_x, dest_y, dest_width, dest_height, wipe_x,
    output logic [31:0] x_step, y_step,
    output logic        ui_enable, status_ok,
    output logic [11:0] fps_bcd,
    output logic [31:0] ui_data,
    output logic [13:0] ui_hint,
    output logic [16:0] ui_metrics,
    output logic [4:0]  catalog_model_count,
    output logic [3:0]  catalog_table_count,
    output logic [95:0] ui_values,
    output logic [2:0]  ui_live_state,
    output logic        config_applied,
    output logic [demo_model_asset_pkg::MODEL_CATALOG_ADDR_WIDTH-1:0] catalog_wr_addr,
    output logic [7:0]  catalog_wr_data,
    output logic        catalog_wr_en
);
    logic [1:0] sh_mode;
    logic [31:0] sh_base_a, sh_base_b;
    logic [15:0] sh_stride_a, sh_stride_b;
    logic [11:0] sh_src_w, sh_src_h, sh_src_x, sh_src_y;
    logic [11:0] sh_dst_x, sh_dst_y, sh_dst_w, sh_dst_h, sh_wipe_x;
    logic [31:0] sh_x_step, sh_y_step;
    logic sh_ui_enable, sh_status_ok;
    logic [11:0] sh_fps_bcd;
    logic [31:0] sh_ui_data;
    logic [13:0] sh_ui_hint;
    logic [16:0] sh_ui_metrics;
    logic [11:0] sh_catalog_info;
    logic [11:0] ui_catalog_info;
    logic [95:0] sh_ui_values;
    logic [2:0] sh_ui_live_state;
    logic ui_state_req_toggle, ui_state_seen, ui_state_ack_toggle;
    (* async_reg="true" *) logic ui_state_req_meta,ui_state_req_sync;
    (* async_reg="true" *) logic ui_state_ack_meta,ui_state_ack_sync;
    logic [2:0] ui_state_pix_q;
    logic diag_clear_req_toggle,diag_clear_ack_toggle;
    (* async_reg="true" *) logic diag_clear_req_meta,diag_clear_req_sync;
    (* async_reg="true" *) logic diag_clear_ack_meta,diag_clear_ack_sync;
    logic diag_clear_seen_pix;
    logic diag_window_active_pix,diag_a_seen_pix,diag_b_seen_pix;
    logic [7:0] diag_a_count_pix,diag_b_count_pix;
    logic [11:0] diag_a_x_pix,diag_a_y_pix,diag_b_x_pix,diag_b_y_pix;
    logic diag_snapshot_req_toggle,diag_snapshot_ack_seen_cfg;
    (* async_reg="true" *) logic diag_snapshot_req_meta,diag_snapshot_req_sync;
    (* async_reg="true" *) logic diag_snapshot_ack_meta,diag_snapshot_ack_sync;
    logic diag_snapshot_seen_pix,diag_snapshot_ack_toggle;
    logic [31:0] diag_snapshot_status_pix,diag_snapshot_a_pix,diag_snapshot_b_pix;
    logic [31:0] diag_snapshot_status_cfg,diag_snapshot_a_cfg,diag_snapshot_b_cfg;
    wire diag_snapshot_write = cfg_valid && cfg_write && cfg_addr==12'h054;
    logic [454:0] mailbox;
    logic commit_toggle, applied_toggle;
    (* async_reg="true" *) logic applied_meta, applied_sync;
    (* async_reg="true" *) logic commit_meta, commit_sync;
    logic applied_seen, vs_q;
    logic [31:0] read_mux;
    logic [demo_model_asset_pkg::MODEL_CATALOG_ADDR_WIDTH-1:0] catalog_index;
    (* async_reg="true" *) logic [3:0] diagnostics_meta,diagnostics_sync;
    always_ff @(posedge cfg_clk or negedge cfg_rst_n)begin
        if(!cfg_rst_n)begin diagnostics_meta<=0;diagnostics_sync<=0;end
        else begin diagnostics_meta<=diagnostics_status;diagnostics_sync<=diagnostics_meta;end
    end

    assign cfg_ready = cfg_valid;
    assign config_applied = (commit_toggle == applied_sync);
    assign catalog_wr_addr=catalog_index;
    assign catalog_wr_data=cfg_wdata[7:0];
    assign catalog_wr_en=cfg_valid&&cfg_write&&!cfg_error&&(cfg_addr==12'h074)&&cfg_wstrb[0];
    assign catalog_model_count=ui_catalog_info[4:0];
    assign catalog_table_count=ui_catalog_info[11:8];

    function automatic [31:0] merge_bytes(input [31:0] oldv, input [31:0] newv, input [3:0] strobe);
        integer i;
        begin
            merge_bytes=oldv;
            for(i=0;i<4;i=i+1) if(strobe[i]) merge_bytes[i*8+:8]=newv[i*8+:8];
        end
    endfunction

    logic [31:0] merged_write;
    always_comb merged_write=merge_bytes(read_mux,cfg_wdata,cfg_wstrb);

    always_comb begin
        read_mux=0;
        case(cfg_addr)
            12'h000:read_mux={30'd0,sh_mode};
            12'h004:read_mux=sh_base_a;
            12'h008:read_mux=sh_base_b;
            12'h00c:read_mux={4'd0,sh_src_h,4'd0,sh_src_w};
            12'h010:read_mux={4'd0,sh_src_y,4'd0,sh_src_x};
            12'h014:read_mux={4'd0,sh_dst_y,4'd0,sh_dst_x};
            12'h018:read_mux={4'd0,sh_dst_h,4'd0,sh_dst_w};
            12'h01c:read_mux={16'd0,sh_stride_a};
            12'h020:read_mux={16'd0,sh_stride_b};
            12'h024:read_mux=sh_x_step;
            12'h028:read_mux=sh_y_step;
            12'h02c:read_mux={20'd0,sh_fps_bcd};
            12'h030:read_mux={30'd0,sh_status_ok,sh_ui_enable};
            12'h034:read_mux={20'd0,sh_wipe_x};
            12'h038:read_mux={30'd0,config_applied,commit_toggle};
            12'h03c:read_mux={28'd0,diagnostics_sync};
            12'h040:read_mux=sh_ui_data;
            12'h044:read_mux={18'd0,sh_ui_hint};
            12'h048:read_mux={15'd0,sh_ui_metrics};
            12'h064:read_mux=sh_ui_values[31:0];
            12'h068:read_mux=sh_ui_values[63:32];
            12'h06c:read_mux=sh_ui_values[95:64];
            12'h070:read_mux={{(32-demo_model_asset_pkg::MODEL_CATALOG_ADDR_WIDTH){1'b0}},catalog_index};
            12'h078:read_mux={20'd0,sh_catalog_info};
            12'h04c:read_mux={22'd0,ui_state_ack_sync,ui_state_req_toggle,sh_ui_live_state};
            12'h050:read_mux={30'd0,diag_clear_ack_sync,diag_clear_req_toggle};
            12'h054:read_mux={30'd0,diag_snapshot_ack_sync,diag_snapshot_req_toggle};
            12'h058:read_mux=diag_snapshot_status_cfg;
            12'h05c:read_mux=diag_snapshot_a_cfg;
            12'h060:read_mux=diag_snapshot_b_cfg;
            default:read_mux=0;
        endcase
    end
    always_comb begin
        cfg_rdata=read_mux;
        cfg_error=1'b0;
        if(cfg_valid && cfg_addr[1:0]!=0) cfg_error=1'b1;
        else if(cfg_valid && !cfg_write && !(cfg_addr<=12'h060 ||
                                             cfg_addr==12'h064 || cfg_addr==12'h068 || cfg_addr==12'h06c || cfg_addr==12'h070 || cfg_addr==12'h078)) cfg_error=1'b1;
        else if(cfg_valid && cfg_write && !(cfg_addr<=12'h034 || cfg_addr==12'h038 ||
                                             cfg_addr==12'h040 || cfg_addr==12'h044 || cfg_addr==12'h048 ||
                                             cfg_addr==12'h064 || cfg_addr==12'h068 || cfg_addr==12'h06c ||
                                             (cfg_addr==12'h070 && (cfg_wstrb[0]||cfg_wstrb[1])) ||
                                             cfg_addr==12'h078 ||
                                             (cfg_addr==12'h074) ||
                                             (cfg_addr==12'h04c && ui_state_req_toggle==ui_state_ack_sync) ||
                                             (cfg_addr==12'h050 && cfg_wdata[0] && cfg_wstrb[0] &&
                                              diag_clear_req_toggle==diag_clear_ack_sync) ||
                                             (cfg_addr==12'h054 && cfg_wdata[0] && cfg_wstrb[0] &&
                                              diag_snapshot_req_toggle==diag_snapshot_ack_sync))) cfg_error=1'b1;
        else if(cfg_valid && cfg_write && cfg_addr==12'h038 &&
                (cfg_wdata[0]!=1'b1 || !cfg_wstrb[0] || (commit_toggle!=applied_sync))) cfg_error=1'b1;
    end

    always_ff @(posedge cfg_clk or negedge cfg_rst_n) begin
        if(!cfg_rst_n) begin
            sh_mode<=0; sh_base_a<=0; sh_base_b<=0; sh_src_w<=1280; sh_src_h<=720;
            sh_src_x<=0; sh_src_y<=0; sh_dst_x<=0; sh_dst_y<=0; sh_dst_w<=1920; sh_dst_h<=1080;
            sh_stride_a<=2560; sh_stride_b<=2560; sh_x_step<=32'h0000_aaab; sh_y_step<=32'h0000_aaab;
            sh_fps_bcd<=12'h000; sh_ui_enable<=1; sh_status_ok<=0; sh_wipe_x<=960;
            sh_ui_data<={20'd0,4'b0011,3'd0,3'd0,2'd2};
            sh_ui_hint<=14'h007f;sh_ui_metrics<=0;sh_catalog_info<=0;sh_ui_values<=0;sh_ui_live_state<=0;ui_state_req_toggle<=0;
            ui_state_ack_meta<=0;ui_state_ack_sync<=0;
            diag_clear_req_toggle<=0;diag_clear_ack_meta<=0;diag_clear_ack_sync<=0;
            catalog_index<=0;
            mailbox<=0; commit_toggle<=0; applied_meta<=0; applied_sync<=0;
        end else begin
            applied_meta<=applied_toggle; applied_sync<=applied_meta;
            ui_state_ack_meta<=ui_state_ack_toggle;ui_state_ack_sync<=ui_state_ack_meta;
            diag_clear_ack_meta<=diag_clear_ack_toggle;diag_clear_ack_sync<=diag_clear_ack_meta;
            if(cfg_valid && cfg_write && !cfg_error) begin
                case(cfg_addr)
                    12'h070:begin
                        if(cfg_wstrb[0])catalog_index[7:0]<=cfg_wdata[7:0];
                        if(cfg_wstrb[1])catalog_index[9:8]<=cfg_wdata[9:8];
                    end
                    12'h074:if(cfg_wstrb[0])catalog_index<=catalog_index+1'b1;
                    12'h000:sh_mode<=merge_bytes({30'd0,sh_mode},cfg_wdata,cfg_wstrb);
                    12'h004:sh_base_a<=merge_bytes(sh_base_a,cfg_wdata,cfg_wstrb);
                    12'h008:sh_base_b<=merge_bytes(sh_base_b,cfg_wdata,cfg_wstrb);
                    12'h00c:begin
                        sh_src_w<=merged_write[11:0]; sh_src_h<=merged_write[27:16];
                    end
                    12'h010:begin
                        sh_src_x<=merged_write[11:0]; sh_src_y<=merged_write[27:16];
                    end
                    12'h014:begin
                        sh_dst_x<=merged_write[11:0]; sh_dst_y<=merged_write[27:16];
                    end
                    12'h018:begin
                        sh_dst_w<=merged_write[11:0]; sh_dst_h<=merged_write[27:16];
                    end
                    12'h01c:sh_stride_a<=merged_write[15:0];
                    12'h020:sh_stride_b<=merged_write[15:0];
                    12'h024:sh_x_step<=merged_write;
                    12'h028:sh_y_step<=merged_write;
                    12'h02c:sh_fps_bcd<=merged_write[11:0];
                    12'h030:begin
                        sh_ui_enable<=merged_write[0]; sh_status_ok<=merged_write[1];
                    end
                    12'h034:sh_wipe_x<=merged_write[11:0];
                    12'h040:sh_ui_data<=merge_bytes(sh_ui_data,cfg_wdata,cfg_wstrb);
                    12'h044:sh_ui_hint<=merge_bytes({18'd0,sh_ui_hint},cfg_wdata,cfg_wstrb);
                    12'h048:sh_ui_metrics<=merge_bytes({15'd0,sh_ui_metrics},cfg_wdata,cfg_wstrb);
                    12'h078:sh_catalog_info<=merge_bytes({20'd0,sh_catalog_info},cfg_wdata,cfg_wstrb);
                    12'h064:sh_ui_values[31:0]<=merge_bytes(sh_ui_values[31:0],cfg_wdata,cfg_wstrb);
                    12'h068:sh_ui_values[63:32]<=merge_bytes(sh_ui_values[63:32],cfg_wdata,cfg_wstrb);
                    12'h06c:sh_ui_values[95:64]<=merge_bytes(sh_ui_values[95:64],cfg_wdata,cfg_wstrb);
                    12'h04c:begin sh_ui_live_state<=cfg_wdata[2:0];ui_state_req_toggle<=~ui_state_req_toggle;end
                    12'h050:if(cfg_wdata[0]&&cfg_wstrb[0])diag_clear_req_toggle<=~diag_clear_req_toggle;
                    12'h054:begin end
                    12'h038:begin
                mailbox<={sh_mode,sh_base_a,sh_base_b,sh_stride_a,sh_stride_b,
                            sh_src_w,sh_src_h,sh_src_x,sh_src_y,sh_dst_x,sh_dst_y,sh_dst_w,sh_dst_h,
                            sh_wipe_x,sh_x_step,sh_y_step,sh_ui_enable,sh_status_ok,sh_fps_bcd,
                            sh_ui_data,sh_ui_hint,sh_ui_metrics,sh_catalog_info,sh_ui_values};
                        commit_toggle<=~commit_toggle;
                    end
                    default:;
                endcase
            end
        end
    end

    always_ff @(posedge cfg_clk or negedge cfg_rst_n)begin
        if(!cfg_rst_n)begin
            diag_snapshot_req_toggle<=0;diag_snapshot_ack_meta<=0;diag_snapshot_ack_sync<=0;
            diag_snapshot_ack_seen_cfg<=0;
            diag_snapshot_status_cfg<=0;diag_snapshot_a_cfg<=0;diag_snapshot_b_cfg<=0;
        end else begin
            diag_snapshot_ack_meta<=diag_snapshot_ack_toggle;
            diag_snapshot_ack_sync<=diag_snapshot_ack_meta;
            if(diag_snapshot_write&&!cfg_error&&cfg_wdata[0]&&cfg_wstrb[0]&&
               diag_snapshot_req_toggle==diag_snapshot_ack_sync)begin
                diag_snapshot_req_toggle<=~diag_snapshot_req_toggle;
            end
            if(diag_snapshot_ack_sync!=diag_snapshot_ack_seen_cfg)begin
                diag_snapshot_status_cfg<=diag_snapshot_status_pix;
                diag_snapshot_a_cfg<=diag_snapshot_a_pix;
                diag_snapshot_b_cfg<=diag_snapshot_b_pix;
                diag_snapshot_ack_seen_cfg<=diag_snapshot_ack_sync;
            end
        end
    end

    always_ff @(posedge pix_clk or negedge pix_rst_n) begin
        if(!pix_rst_n) begin
            commit_meta<=0; commit_sync<=0; applied_seen<=0; applied_toggle<=0; vs_q<=0;
            {scene_mode,base_a,base_b,stride_a,stride_b,source_width,source_height,source_x,source_y,
             dest_x,dest_y,dest_width,dest_height,wipe_x,x_step,y_step,ui_enable,status_ok,fps_bcd,
             ui_data,ui_metrics,ui_catalog_info}<=0;ui_hint<=14'h007f;
            ui_values<=0;
            ui_state_req_meta<=0;ui_state_req_sync<=0;ui_state_seen<=0;ui_state_ack_toggle<=0;ui_state_pix_q<=0;
        end else begin
            commit_meta<=commit_toggle; commit_sync<=commit_meta; vs_q<=in_vs;
            ui_state_req_meta<=ui_state_req_toggle;ui_state_req_sync<=ui_state_req_meta;
            if(pix_line_start && ui_state_req_sync!=ui_state_seen)begin
                ui_state_pix_q<=sh_ui_live_state;
                ui_state_seen<=ui_state_req_sync;ui_state_ack_toggle<=ui_state_req_sync;
            end
            if(in_vs && !vs_q && commit_sync!=applied_seen) begin
                {scene_mode,base_a,base_b,stride_a,stride_b,source_width,source_height,source_x,source_y,
                 dest_x,dest_y,dest_width,dest_height,wipe_x,x_step,y_step,ui_enable,status_ok,fps_bcd,
                 ui_data,ui_hint,ui_metrics,ui_catalog_info}<=mailbox[454:96];
                ui_values<=mailbox[95:0];
                applied_seen<=commit_sync;
                applied_toggle<=commit_sync;
            end
        end
    end

    always_ff @(posedge pix_clk or negedge pix_rst_n)begin
        if(!pix_rst_n)begin
            diag_clear_req_meta<=0;diag_clear_req_sync<=0;diag_clear_seen_pix<=0;
            diag_clear_ack_toggle<=0;diag_window_active_pix<=0;
            diag_a_seen_pix<=0;diag_b_seen_pix<=0;diag_a_count_pix<=0;diag_b_count_pix<=0;
            diag_a_x_pix<=0;diag_a_y_pix<=0;diag_b_x_pix<=0;diag_b_y_pix<=0;
            diag_snapshot_req_meta<=0;diag_snapshot_req_sync<=0;diag_snapshot_seen_pix<=0;
            diag_snapshot_ack_toggle<=0;diag_snapshot_status_pix<=0;
            diag_snapshot_a_pix<=0;diag_snapshot_b_pix<=0;
        end else begin
            diag_clear_req_meta<=diag_clear_req_toggle;diag_clear_req_sync<=diag_clear_req_meta;
            diag_snapshot_req_meta<=diag_snapshot_req_toggle;diag_snapshot_req_sync<=diag_snapshot_req_meta;
            if(diag_clear_req_sync!=diag_clear_seen_pix)begin
                diag_clear_seen_pix<=diag_clear_req_sync;diag_clear_ack_toggle<=diag_clear_req_sync;
                diag_window_active_pix<=1;
                diag_a_count_pix<=underflow_a_event?8'd1:8'd0;
                diag_b_count_pix<=underflow_b_event?8'd1:8'd0;
                diag_a_seen_pix<=underflow_a_event;diag_b_seen_pix<=underflow_b_event;
                if(underflow_a_event)begin diag_a_x_pix<=underflow_a_x;diag_a_y_pix<=underflow_a_y;end
                else begin diag_a_x_pix<=0;diag_a_y_pix<=0;end
                if(underflow_b_event)begin diag_b_x_pix<=underflow_b_x;diag_b_y_pix<=underflow_b_y;end
                else begin diag_b_x_pix<=0;diag_b_y_pix<=0;end
            end else if(diag_window_active_pix)begin
                if(underflow_a_event&&diag_a_count_pix!=8'hff)diag_a_count_pix<=diag_a_count_pix+1'b1;
                if(underflow_b_event&&diag_b_count_pix!=8'hff)diag_b_count_pix<=diag_b_count_pix+1'b1;
                if(underflow_a_event&&!diag_a_seen_pix)begin
                    diag_a_seen_pix<=1;diag_a_x_pix<=underflow_a_x;diag_a_y_pix<=underflow_a_y;
                end
                if(underflow_b_event&&!diag_b_seen_pix)begin
                    diag_b_seen_pix<=1;diag_b_x_pix<=underflow_b_x;diag_b_y_pix<=underflow_b_y;
                end
            end
            if(diag_snapshot_req_sync!=diag_snapshot_seen_pix)begin
                diag_snapshot_seen_pix<=diag_snapshot_req_sync;
                diag_snapshot_status_pix<={diag_window_active_pix,diag_a_seen_pix,diag_b_seen_pix,
                    5'd0,diag_b_count_pix,diag_a_count_pix,8'd0};
                diag_snapshot_a_pix<={8'd0,diag_a_y_pix,diag_a_x_pix};
                diag_snapshot_b_pix<={8'd0,diag_b_y_pix,diag_b_x_pix};
                diag_snapshot_ack_toggle<=diag_snapshot_req_sync;
            end
        end
    end
    assign ui_live_state=ui_state_pix_q;
endmodule


