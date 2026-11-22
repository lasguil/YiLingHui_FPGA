"""Static revision/ROM audit only. Never compiles firmware/RTL or runs a test binary."""
from pathlib import Path
import hashlib,json,re

p=Path(__file__).resolve().parents[1]
backup=p/'support/before_wave_source_choice_20261112'
run=p/'tmp/wave_source_choice';run.mkdir(parents=True,exist_ok=True)
def decode(source):
 result=bytearray()
 for bank in range(4):
  body=source.split('module pipeline_luna_ui_text_bank'+str(bank)+'(',1)[1].split('endmodule',1)[0]
  entries={int(i,16):int(v,16)&((1<<256)-1) for i,v in re.findall(r"localparam \[255:0\] INIT_([0-9A-F]+) = 256'h([0-9a-fA-F]{1,80});",body)}
  assert len(entries)==32
  result.extend(b''.join(entries[i].to_bytes(32,'little') for i in range(32)))
 return result
old=decode((backup/'rtl/display/pipeline_luna_ui_text_rom.sv').read_text())
new=decode((p/'rtl/display/pipeline_luna_ui_text_rom.sv').read_text())
labels={82:b'WAVE OFF',83:b'WAVE LITE',84:b'WAVE PRO'}
assert len(old)==len(new)==4096
for message,label in labels.items():assert new[32*message:32*(message+1)]==label+bytes(32-len(label))
assert all(a==b or i//32 in labels for i,(a,b) in enumerate(zip(old,new)))
renderer=(p/'rtl/display/display_renderer.sv').read_text()
assert 'wave_source={ui_data[15],ui_data[16]}' in renderer
assert 'MSG_WAVE_LITE=83, MSG_WAVE_PRO=84' in renderer
control=(p/'software/style_control.c').read_text()
assert 'style_input_core_wave_step(input_state.wave,wave_change)' in control
assert 'style_ui_wave_metadata(input_state.wave)' in control
parser=(p/'software/gesture_uart.c').read_text()
assert 'state->wave==STYLE_WAVE_EXT&&p[0]<=2u' in parser
assert 'case TYPE_GESTURE_PAUSE_SET:' in parser and 'length!=1u||p[0]>1u' in parser
assert 'if(state->paused!=p[0]){state->paused=p[0];state->dirty=1u;}' in parser
def pause_example(sequence,value):
 data=bytes([1,2,sequence&255,sequence>>8,1,0,value]);crc=0xffff
 for b in data:
  crc^=b<<8
  for _ in range(8):crc=((crc<<1)^0x1021 if crc&0x8000 else crc<<1)&0xffff
 return (b'\xa5\x5a'+data+crc.to_bytes(2,'little')).hex(' ')
files=['software/style_input.h','software/style_input.c','software/style_control.c',
 'software/style_ui_protocol.h','software/gesture_uart.h','software/gesture_uart.c',
 'rtl/display/display_renderer.sv','rtl/display/pipeline_luna_ui_text_rom.sv','sim/gesture_uart_host_test.c']
record={
 'status':'SOURCE_READY_STATIC_AUDIT_PASS_COMPILE_DEFERRED_BY_USER',
 'labels':['WAVE OFF','WAVE LITE','WAVE PRO'],'default':0,
 'selection':'existing button cycles; UI_SET field5 allows direct selection',
 'pause_interface':{'type':'0x02','length':1,'hold':1,'resume':0,'only_source':'PRO',
   'hold_seq1_frame':pause_example(1,1),'resume_seq2_frame':pause_example(2,0)},
 'static_audit':['only messages82..84 differ in same4096-byte ROM','metadata bit15/16 routing',
   'core source gate and extension source gate present','absolute PRO pause handler present'],
 'tests':'host test source updated; NOT_COMPILED_NOT_RUN',
 'full_build_started':False,'programmed':False,'compile_deferred_by_user':True,
 'source_sha256':{f:hashlib.sha256((p/f).read_bytes()).hexdigest() for f in files},
}
(run/'SOURCE_RESULT.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
f=p/'TRIAL_BUILD_RESULT.json';data=json.loads(f.read_text())
data['status']=record['status'];data['current_build_available']=False
data['source_changed_after_last_build']=True;data['compile_deferred_by_user']=True
data['wave_source_choice_20261112']=record
data['pending_changes']=['2026-11-11 UI fixes retained','2026-11-12 ISP-green 8x8 detector',
 '2026-11-12 WAVE OFF/LITE/PRO selection and PRO absolute pause/resume receiver']
f.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'status':record['status'],'same_rom_banks':True,'pause_examples':record['pause_interface']},ensure_ascii=False))
