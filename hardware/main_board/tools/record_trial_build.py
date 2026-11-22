"""Record truthful evidence for the un-signed-off wave16 trial build."""
from pathlib import Path
import argparse, csv, hashlib, json, re, xml.etree.ElementTree as ET

root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser()
for name in ('bit','hex','pgm','pgm-log','rom-verification','timing-report','route-report','resource-report','firmware','map','map-log'):
    p.add_argument('--'+name,required=True,type=Path)
a=p.parse_args()
def path(x): return x if x.is_absolute() else (root/x).resolve()
files={k:path(getattr(a,k.replace('-','_'))) for k in ('bit','hex','pgm','pgm-log','rom-verification','timing-report','route-report','resource-report','firmware','map','map-log')}
for k,v in files.items():
    if not v.is_file(): raise SystemExit(f'Missing {k}: {v}')
sha=lambda b: hashlib.sha256(b).hexdigest()
if files['pgm'].stat().st_mtime_ns < files['map'].stat().st_mtime_ns: raise SystemExit('PGM predates current map')
if files['route-report'].stat().st_mtime_ns < files['map'].stat().st_mtime_ns: raise SystemExit('Route report predates current map')
if files['timing-report'].stat().st_mtime_ns < files['route-report'].stat().st_mtime_ns: raise SystemExit('STA report predates route')
if files['bit'].stat().st_mtime_ns < files['route-report'].stat().st_mtime_ns: raise SystemExit('Bitstream predates route')
if not re.search(r'(?im)^\s*pgm\s*:\s*PASS\s*$',files['pgm-log'].read_text(errors='ignore')): raise SystemExit('No explicit PGM PASS in fresh log')
report=files['timing-report'].read_text(errors='replace')
part=report.split('---------- 2. Clock Relationship Summary (begin) ----------',1)[1].split('Clock Relationship Summary (end)',1)[0]
setup,hold=part.split('Hold (Min) Clock Relationship',1)
slacks=lambda s:[float(x) for x in re.findall(r'^\S+\s+\S+\s+[-.0-9]+\s+([-.0-9]+)\s+\(',s,re.M)]
sv,hv=slacks(setup),slacks(hold)
if len(sv)!=15 or len(hv)!=15: raise SystemExit(f'Expected 15 timing relationships, got {len(sv)} setup, {len(hv)} hold')
worst_setup,worst_hold=min(sv),min(hv)
if worst_setup < -.200 or worst_hold < -.050: raise SystemExit('Timing beyond authorized trial limits')
rom=json.loads(files['rom-verification'].read_text(encoding='utf-8'))
fw=files['firmware'].read_bytes()
if rom.get('raw_bin_sha256') != sha(fw): raise SystemExit('ROM raw firmware hash mismatch')
if rom.get('model_count')!=26 or len(rom.get('lanes',[]))!=12: raise SystemExit('ROM verification does not cover all expected model/lane inputs')
route=ET.parse(files['route-report']).getroot(); ns={'e':'http://www.efinixinc.com/tool_report'}
values={x.attrib.get('name'):x.attrib.get('value','') for x in route.findall('.//e:group_data',ns)}
def used(name):
    m=re.match(r'\s*([\d,]+)\s*/',values.get(name,'')); return int(m.group(1).replace(',','')) if m else None
# Map CSV top row contains ordered resource columns used by this project’s existing recorder.
rows=list(csv.reader(files['resource-report'].open(newline='',encoding='utf-8-sig')))
top=next((r for r in rows if r and r[0].startswith('ti60f225_oob_top:ti60f225_oob_top')),None)
if top is None: raise SystemExit('Top-level map resources missing')
nums=[int(x) for x in re.findall(r'(?<!\d)(\d+)\(\d+\)',','.join(top))]
if len(nums)<7: raise SystemExit('Cannot parse mapped resource counts')
resource={'FF':nums[0],'SRL':nums[1],'LUT':nums[3],'RAM':nums[5],'DSP':nums[6],
          'routed_XLR':used('XLRs'),'Memory Blocks':used('Memory Blocks'),'DSP Blocks':used('DSP Blocks')}
baseline={'LUT':35510,'FF':19215,'SRL':3624,'RAM':228,'DSP':129}
delta={k:(resource[k]-v) for k,v in baseline.items()}
previous_wave16={'LUT':35470,'FF':19355,'SRL':3624,'RAM':228,'DSP':129,'routed_XLR':57564}
delta_previous={k:(resource[k]-v) for k,v in previous_wave16.items()}
linkmap=path(Path('software/build/product_ui_24k.map')).read_text(errors='replace')
section_size=lambda name: int(re.search(rf'(?m)^\.{name}\s+0x[0-9a-fA-F]+\s+0x([0-9a-fA-F]+)',linkmap).group(1),16)
text_bytes,data_bytes,bss_bytes=(section_size(x) for x in ('text','data','bss'))
linked_bytes=text_bytes+data_bytes+bss_bytes
stack_bytes=24*1024-linked_bytes
if linked_bytes>0x5800 or stack_bytes<2048: raise SystemExit('Firmware map violates 24 KiB / 2 KiB stack reserve')
result={'project':'ti60f225_style_demo_wave16_ui_20261111','status':'TRIAL_BUILD; NOT_SIGNED_OFF; NOT_PROGRAMMED',
 'timing_clean':worst_setup>=0 and worst_hold>=0,'setup_wns_ns':worst_setup,'hold_whs_ns':worst_hold,
 'trial_gate_ns':{'setup_min':-0.2,'hold_min':-0.05},'seed':1,'max_threads':4,
 'bit_path':files['bit'].relative_to(root).as_posix(),'bit_bytes':files['bit'].stat().st_size,'bit_sha256':sha(files['bit'].read_bytes()),
 'hex_path':files['hex'].relative_to(root).as_posix(),'hex_sha256':sha(files['hex'].read_bytes()),
 'pgm_path':files['pgm'].relative_to(root).as_posix(),'pgm_sha256':sha(files['pgm'].read_bytes()),'pgm_pass':True,
 'rom_verification':files['rom-verification'].relative_to(root).as_posix(),'rom_verification_pass':True,
 'firmware_bytes':len(fw),'firmware_sha256':sha(fw),
 'firmware_memory_usage':{'text_bytes':text_bytes,'data_bytes':data_bytes,'bss_bytes':bss_bytes,
                          'linker_accounted_bytes':linked_bytes,'stack_reserve_bytes':stack_bytes,
                          'linker_assertion':'SIZEOF(text)+SIZEOF(data)+SIZEOF(bss)<=0x5800; stack reserve >=2048 bytes'},
 'resources':resource,'resource_delta_vs_morning':delta,
 'resource_delta_vs_previous_wave16':delta_previous,
 'timing_report':files['timing-report'].relative_to(root).as_posix(),'full_sta_report_preserved':True,
 'jtag_program_status':'NOT_PROGRAMMED','jtag_program':{'status':'NOT_PROGRAMMED','bit_sha256':sha(files['bit'].read_bytes())}}
(root/'TRIAL_BUILD_RESULT.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(f"TRIAL_BUILD_RECORDED timing_clean={result['timing_clean']} setup={worst_setup} hold={worst_hold} bit_sha256={result['bit_sha256']}")
