// Four-phase crop/token stage. It consumes every halo pixel but stores no line
// history; only center pixels are forwarded. Bayer phase retains the original
// stream-coordinate x convention, including the consumed left halo.
module ipx_crop #(parameter integer MAX_ROW_WIDTH=2048)(
    input logic clk,clear,run,step,
    input logic [1:0] phase,
    input wire ipx_types::config_t cfg,
    input logic in_valid,
    output logic in_ready,
    output logic needs_input,
    input logic [17:0] in_data,
    output logic out_valid,completed,
    output logic [17:0] out_data,
    output ipx_types::meta_t meta
);
    import ipx_types::*;
    logic [10:0] x_q,y_q;
    logic slot_q,emit_q;
    logic [17:0] input_q;
    wire [10:0] center_end=11'(cfg.st_lo)+cfg.dst_width;
    wire center_pixel=x_q>=11'(cfg.st_lo)&&x_q<center_end;
    wire take=run&&step&&phase==0&&!completed&&in_valid;
    initial if(MAX_ROW_WIDTH<1||MAX_ROW_WIDTH>2048)
        $fatal(1,"IPX crop width outside supported 1..2048 range");
    always_comb begin
        needs_input=run&&!completed&&y_q<cfg.height&&x_q<cfg.width;
        in_ready=run&&step&&phase==0&&!completed&&y_q<cfg.height&&x_q<cfg.width;
    end
    always_ff @(posedge clk)begin
        if(clear)begin
            x_q<=0;y_q<=0;slot_q<=0;emit_q<=0;
            out_valid<=0;completed<=0;
        end else if(step)begin
            if(phase==0)begin
                slot_q<=take;
                if(take)input_q<=in_data;
            end
            if(phase==2)emit_q<=slot_q&&center_pixel;
            if(phase==3)begin
                out_valid<=emit_q;
                if(emit_q)begin
                    out_data<=input_q;
                    meta.original<=input_q;
                    meta.pattern<=bayer(x_q[1:0],y_q[1:0]);
                end
                if(slot_q)begin
                    if(x_q==cfg.width-1'b1)begin
                        x_q<=0;
                        if(y_q==cfg.height-1'b1)completed<=1;
                        else y_q<=y_q+1'b1;
                    end else x_q<=x_q+1'b1;
                end
            end
        end
    end
`ifdef SIM_ASSERT
    always @(posedge clk)if(!clear)begin
        if(take&&!in_ready)$fatal(1,"IPX crop accepted without ready");
        if(slot_q&&phase==3&&x_q>=cfg.width)$fatal(1,"IPX crop input coordinate");
        if(emit_q&&phase==3&&!center_pixel)$fatal(1,"IPX crop emitted halo");
    end
`endif
endmodule
