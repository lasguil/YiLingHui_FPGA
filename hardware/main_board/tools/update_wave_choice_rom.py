"""Edit UI text source only; do not compile HDL or create a bitstream."""
from pathlib import Path
import re,json

root=Path(__file__).resolve().parents[1]
path=root/'rtl/display/pipeline_luna_ui_text_rom.sv'
source=path.read_text(encoding='utf-8')
def module_span(name,text):
 start=text.index('module '+name+'(')
 end=text.index('endmodule',start)+len('endmodule')
 return start,end,text[start:end]
def decode(text):
 data=bytearray()
 for bank in range(4):
  body=module_span('pipeline_luna_ui_text_bank'+str(bank),text)[2]
  entries={int(i,16):int(v,16)&((1<<256)-1) for i,v in re.findall(r"localparam \[255:0\] INIT_([0-9A-F]+) = 256'h([0-9a-fA-F]{1,80});",body)}
  assert set(entries)==set(range(32))
  data.extend(b''.join(entries[i].to_bytes(32,'little') for i in range(32)))
 return data
before=decode(source)
labels={82:b'WAVE OFF',83:b'WAVE LITE',84:b'WAVE PRO'}
for message,label in labels.items():
 bank=message//32;slot=message%32
 old=before[message*32:(message+1)*32]
 prior={83:b'WAVE CORE',84:b'WAVE EXT'}.get(message,b'')
 assert old in (bytes(32),b'WAVE'+bytes(28),label+bytes(32-len(label)),prior+bytes(32-len(prior))),(message,old)
 start,end,body=module_span('pipeline_luna_ui_text_bank'+str(bank),source)
 pattern=r"(localparam \[255:0\] INIT_"+f'{slot:X}'+r" = 256'h)([0-9a-fA-F]{1,80})(;)"
 match=re.search(pattern,body);assert match
 data=label+bytes(32-len(label))
 body=body[:match.start(2)]+f"{int.from_bytes(data,'little'):064X}"+body[match.end(2):]
 source=source[:start]+body+source[end:]
after=decode(source)
for i,(a,b) in enumerate(zip(before,after)):
 assert a==b or i//32 in labels,('unrelated ROM byte',i)
for message,label in labels.items():assert after[message*32:(message+1)*32]==label+bytes(32-len(label))
assert len(after)==len(before)==4096
path.write_text(source,encoding='utf-8')
print('Source ROM updated: WAVE OFF / WAVE LITE / WAVE PRO; same four banks, other slots unchanged.')
