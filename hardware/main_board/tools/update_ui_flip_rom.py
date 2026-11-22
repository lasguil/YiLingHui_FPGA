from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
rom=root/'rtl/display/pipeline_luna_ui_text_rom.sv'
s=rom.read_text(encoding='utf-8')
def span(name,text):
 start=text.index('module '+name+'(');end=text.index('endmodule',start)+len('endmodule');return start,end,text[start:end]
mods=[f'pipeline_luna_ui_text_bank{i}' for i in range(4)]
def decode(name,text):
 body=span(name,text)[2]
 entries={int(i,16):(int(v,16)&((1<<256)-1)) for i,v in re.findall(r"localparam \[255:0\] INIT_([0-9A-F]+) = 256'h([0-9a-fA-F]{1,80});",body)}
 if set(entries)!=set(range(32)):raise SystemExit(f'unexpected INIT coverage in {name}')
 return b''.join(entries[i].to_bytes(32,'little') for i in range(32))
before={m:decode(m,s) for m in mods};slot=17*32
existing=before[mods[2]][slot:slot+32]
if existing not in (bytes(32),b'FLIP'+bytes(28)):raise SystemExit('message 81 slot is neither blank nor the expected FLIP text')
# Ensure the temporary erroneous bank1 edit is absent.
if b'FLIP' in before[mods[1]][16*32:17*32]:raise SystemExit('temporary bank1 edit remains')
# Write through the same little-endian INIT representation used by EFX RAM10.
a,b,body=span(mods[2],s);pat=r"(localparam \[255:0\] INIT_11 = 256'h)([0-9a-fA-F]{1,80})(;)";m=re.search(pat,body)
if not m:raise SystemExit('bank2 INIT_11 missing')
value=int(m.group(2),16)
for i,byte in enumerate(b'FLIP'):
 shift=i*8;value=(value&~(0xff<<shift))|(byte<<shift)
body=body[:m.start(2)]+f'{value:064X}'+body[m.end(2):]
s=s[:a]+body+s[b:]
after={bank:decode(bank,s) for bank in mods}
diff=[]
for bank in mods:
 baseline=bytearray(before[bank])
 if bank==mods[2]:baseline[slot:slot+32]=bytes(32)
 diff.extend((bank,i,x,y) for i,(x,y) in enumerate(zip(baseline,after[bank])) if x!=y)
expected=[(mods[2],slot+i,0,ord(c)) for i,c in enumerate('FLIP')]
if diff!=expected:raise SystemExit(f'unexpected ROM difference: {diff}')
rom.write_text(s,encoding='utf-8')
print('PASS: message id 81 is FLIP; only four bytes differ across the 4096-byte text ROM')
