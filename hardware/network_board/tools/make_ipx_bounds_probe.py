"""Mirror the window coordinate bounds at the existing coordinate update edge."""
from pathlib import Path
import shutil,re
root=Path(__file__).resolve().parents[1];base=root/'build/render_takeover_20261011'
source=(base/'ipx_control_native/ipx_window.sv').read_text(encoding='utf-8')
variant=source.replace('    logic replay_q,slot_q;', '''    logic x_in_range_q,y_in_range_q;
    logic [10:0] width_last_q,height_last_q,span_last_q;
    logic replay_q,slot_q;''',1)
assert variant.count('x_q<cfg.width')==3 and variant.count('y_q<cfg.height')==2
variant=variant.replace('x_q<cfg.width','x_in_range_q').replace('y_q<cfg.height','y_in_range_q')
# Preserve the public idle diagnostic too; only the live handshake uses flags.
variant=variant.replace('needs_input=need_input&&!completed;', 'needs_input=(cfg.spatial==DIRECT||(cfg.spatial==PIXELATE&&!replay_q)||(neighbor&&x_q<cfg.width&&y_q<cfg.height))&&!completed;')
variant=variant.replace("cfg.width-1'b1",'width_last_q').replace("cfg.height-1'b1",'height_last_q').replace("win_span-1'b1",'span_last_q')
variant=variant.replace('        if(clear)begin', '''        if(clear)begin
            // cfg is the existing task-held snapshot; no extra cycle is added.
            width_last_q<=cfg.width-1'b1;height_last_q<=cfg.height-1'b1;span_last_q<=win_span-1'b1;''',1)
assert variant.count('x_q<=0;')==3 and variant.count("x_q<=x_q+1'b1;")==2
variant=variant.replace('x_q<=0;','x_q<=0;x_in_range_q<=cfg.width!=0;')
variant=re.sub(r'\by_q<=0;', 'y_q<=0;y_in_range_q<=cfg.height!=0;',variant)
variant=variant.replace("x_q<=x_q+1'b1;", "begin x_q<=x_q+1'b1;x_in_range_q<=x_in_range_q && x_q!=width_last_q;end")
variant=variant.replace("y_q<=y_q+1'b1;", "begin y_q<=y_q+1'b1;y_in_range_q<=y_in_range_q && y_q!=height_last_q;end")
dest=base/'ipx_control_bounds';dest.mkdir(exist_ok=True)
for f in (base/'ipx_control_native').iterdir():
    if f.is_file() and f.suffix in ['.sv','.xml','.sdc']:shutil.copy2(f,dest/f.name)
(dest/'ipx_window.sv').write_text(variant,encoding='utf-8')
(dest/'ipx_window_ref.sv').write_text(source.replace('module ipx_window(', 'module ipx_window_ref(',1),encoding='utf-8')
tb='''`timescale 1ns/1ps
module tb_ipx_bounds;
import ipx_types::*;
logic clk=0;always #2.5 clk=~clk;
logic clear=1,run=0,step=0,in_valid=0;logic [1:0] phase=0;
logic [23:0] in_data=0;config_t cfg='0;
wire ready_a,ready_b,needs_a,needs_b,out_a,out_b,done_a,done_b;
wire [215:0] window_a,window_b;meta_t meta_a,meta_b;
ipx_window_ref golden(.clk,.clear,.run,.step,.phase,.cfg,.in_valid,.in_ready(ready_a),.needs_input(needs_a),.in_data,.out_valid(out_a),.completed(done_a),.window(window_a),.meta(meta_a));
ipx_window dut(.clk,.clear,.run,.step,.phase,.cfg,.in_valid,.in_ready(ready_b),.needs_input(needs_b),.in_data,.out_valid(out_b),.completed(done_b),.window(window_b),.meta(meta_b));
int widths[8]='{1,2,3,7,8,17,31,33};int heights[4]='{1,2,3,7};
int checked=0,frames=0;
initial begin
    for(int m=0;m<8;m++)for(int wi=0;wi<8;wi++)for(int hi=0;hi<4;hi++)begin
        @(negedge clk);clear=1;run=0;step=0;phase=0;
        cfg='0;cfg.spatial=spatial_t'(m);cfg.width=11'(widths[wi]);cfg.height=11'(heights[hi]);
        cfg.block_size=2'(wi%3);cfg.st_lo=widths[wi]>=17 && (wi%2) ? 8 : 0;
        cfg.st_hi=cfg.st_lo;cfg.dst_width=cfg.width-11'(cfg.st_lo)-11'(cfg.st_hi);
        repeat(2)@(negedge clk);clear=0;run=1;
        for(int c=0;c<20000;c++)begin
            step=($urandom%5)!=0;in_valid=($urandom%4)!=0;in_data=$urandom;
            #0.2;
            if({ready_a,needs_a,out_a,done_a,window_a,meta_a} !== {ready_b,needs_b,out_b,done_b,window_b,meta_b})
                $fatal(1,"IPX_BOUNDS mismatch mode=%0d width=%0d height=%0d cycle=%0d",m,cfg.width,cfg.height,c);
            if(dut.x_in_range_q !== (dut.x_q<cfg.width) || dut.y_in_range_q !== (dut.y_q<cfg.height))
                $fatal(1,"IPX_BOUNDS coordinate invariant");
            checked++;
            @(posedge clk);#0.2;if(step)phase=phase+1'b1;
            @(negedge clk);
            if(done_a)break;
            if(c==19999)$fatal(1,"IPX_BOUNDS timeout");
        end
        frames++;
    end
    $display("PASS IPX_BOUNDS %0d frames %0d cycles all outputs/invariants, stalls and halo",frames,checked);$finish;
end
endmodule
'''
(dest/'tb_ipx_bounds.sv').write_text(tb,encoding='utf-8')
print('Prepared IPX bound flags only in independent probe; no board edits')
