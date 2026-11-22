"""Measure an exact unsigned comparator tree before board integration."""
from pathlib import Path
import xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[1];base=root/'build/render_takeover_20261011'
tree_source='''// Exact 16-bit unsigned comparison. Pair leaves and a balanced tree
// bound the depth to four LUTs, including out-of-range geometry values.
module ipx_lt16_tree(input wire [15:0] a,b,output wire less);
wire [7:0] lt0,eq0;wire [3:0] lt1,eq1;wire [1:0] lt2,eq2;
for(genvar i=0;i<8;i++)begin:g_pair
    EFX_LUT4 #(.LUTMASK(16'h7310)) u_lt(.I0(a[2*i]),.I1(a[2*i+1]),.I2(b[2*i]),.I3(b[2*i+1]),.O(lt0[i]));
    EFX_LUT4 #(.LUTMASK(16'h8421)) u_eq(.I0(a[2*i]),.I1(a[2*i+1]),.I2(b[2*i]),.I3(b[2*i+1]),.O(eq0[i]));
end
for(genvar i=0;i<4;i++)begin:g_four
    EFX_LUT4 #(.LUTMASK(16'hecec)) u_lt(.I0(lt0[2*i]),.I1(lt0[2*i+1]),.I2(eq0[2*i+1]),.I3(1'b0),.O(lt1[i]));
    EFX_LUT4 #(.LUTMASK(16'h8888)) u_eq(.I0(eq0[2*i]),.I1(eq0[2*i+1]),.I2(1'b0),.I3(1'b0),.O(eq1[i]));
end
for(genvar i=0;i<2;i++)begin:g_eight
    EFX_LUT4 #(.LUTMASK(16'hecec)) u_lt(.I0(lt1[2*i]),.I1(lt1[2*i+1]),.I2(eq1[2*i+1]),.I3(1'b0),.O(lt2[i]));
    EFX_LUT4 #(.LUTMASK(16'h8888)) u_eq(.I0(eq1[2*i]),.I1(eq1[2*i+1]),.I2(1'b0),.I3(1'b0),.O(eq2[i]));
end
EFX_LUT4 #(.LUTMASK(16'hecec)) u_sixteen(.I0(lt2[0]),.I1(lt2[1]),.I2(eq2[1]),.I3(1'b0),.O(less));
endmodule
'''
harness='''module compare_probe(input wire clk,input wire [31:0] raw_input,output logic observed);
logic [15:0] a,b;wire less;
always_ff @(posedge clk){a,b}<=raw_input;
DUT
always_ff @(posedge clk)observed<=less;
endmodule
'''
ns='http://www.efinixinc.com/enf_proj';ET.register_namespace('efx',ns);ET.register_namespace('xsi','http://www.w3.org/2001/XMLSchema-instance')
for tag,dut in [('compare_native','assign less=a<b;'),('compare_tree','ipx_lt16_tree dut(.*);')]:
    dest=base/tag;dest.mkdir(exist_ok=True)
    (dest/'ipx_lt16_tree.sv').write_text(tree_source,encoding='utf-8')
    (dest/'compare_probe.sv').write_text(harness.replace('DUT',dut),encoding='utf-8')
    tree=ET.parse(base/'probe_c/display_subsystem_area.xml');proj=tree.getroot();proj.set('name','compare_probe')
    design=proj.find(f'{{{ns}}}design_info');design.find(f'{{{ns}}}top_module').set('name','compare_probe')
    for f in list(design.findall(f'{{{ns}}}design_file')):design.remove(f)
    for i,name in enumerate(['ipx_lt16_tree.sv','compare_probe.sv'],1):design.insert(i,ET.Element(f'{{{ns}}}design_file',name=name,version='default',library='default'))
    proj.find(f'{{{ns}}}constraint_info/{{{ns}}}sdc_file').set('name','compare_probe.sdc')
    (dest/'compare_probe.sdc').write_text('create_clock -period 5.5556 clk\n',encoding='utf-8')
    tree.write(dest/'compare_probe.xml',encoding='utf-8')
tb='''`timescale 1ns/1ps
module tb_compare_tree;
logic [15:0] a=0,b=0;wire less;
ipx_lt16_tree dut(.*);
int checked=0;
task check;#0.1;if(less!==(a<b))$fatal(1,"COMPARE a=%h b=%h",a,b);checked++;endtask
initial begin
    for(int x=0;x<65536;x++)begin
        a=16'(x);b=16'(x);check();
        b=16'(x+1);check();b=16'(x-1);check();
        b=$urandom;check();a=$urandom;check();
    end
    $display("PASS COMPARE_TREE %0d full-width comparisons",checked);$finish;
end
endmodule
'''
(base/'compare_tree/tb_compare_tree.sv').write_text(tb,encoding='utf-8')
print('Created comparator probes: 32 independent input bits and registered 1-bit result')
