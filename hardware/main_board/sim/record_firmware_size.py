from pathlib import Path
import hashlib,json,re,shutil
p=Path(__file__).resolve().parents[1]
run=p/'tmp/firmware_size_20261112_wave_pro'
def sizes(path):
 text=path.read_text(errors='replace')
 result={}
 for name in ('text','data','bss'):
  m=re.search(r'^\.'+name+r'\s+0x[0-9a-f]+\s+(0x[0-9a-f]+)',text,re.M)
  assert m,name
  result[name]=int(m.group(1),16)
 result['static_total']=sum(result.values());result['stack_available']=24576-result['static_total']
 return result
current=sizes(p/'software/build/product_ui_24k.map')
baseline=sizes(run/'before/product_ui_24k.map')
log=(run/'build.log').read_text(errors='replace')
assert 'Reserve at least 2KB stack' in log and 'ld returned 1 exit status' in log
assert not (p/'software/build/product_ui_24k.elf').exists()
shutil.copy2(p/'software/build/product_ui_24k.map',run/'failed_current_firmware.map')
shutil.copy2(p/'software/build/product_ui_24k.elf.ltrans0.ltrans.su',run/'failed_current_stack_usage.su')
bin_path=p/'software/build/product_ui_24k.bin'
assert hashlib.sha256(bin_path.read_bytes()).hexdigest()==hashlib.sha256((run/'before/product_ui_24k.bin').read_bytes()).hexdigest()
record={'status':'LINK_FAILED_2K_STACK_RESERVE','toolchain_flags':'-Oz -flto -msave-restore; existing build_multi_style_24k.bat',
 'ocr_bytes':24576,'minimum_stack_bytes':2048,'static_limit_bytes':22528,
 'current':current,'baseline':baseline,'static_delta_bytes':current['static_total']-baseline['static_total'],
 'excess_over_static_limit_bytes':current['static_total']-22528,
 'new_elf_generated':False,'new_bin_generated':False,
 'bin_at_software_build':'OLD_BINARY_UNCHANGED_NOT_CURRENT_SOURCE',
 'linker_assertion_modified':False,'fpga_build_started':False,'programmed':False,
 'log':str((run/'build.log').relative_to(p)),'map':str((run/'failed_current_firmware.map').relative_to(p))}
(run/'SIZE_RESULT.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
f=p/'TRIAL_BUILD_RESULT.json';data=json.loads(f.read_text())
data['status']='FIRMWARE_LINK_FAILED_STACK_RESERVE_FPGA_BUILD_DEFERRED'
data['firmware_size_check_20261112']=record
data['current_build_available']=False
data['current_firmware']['status']='PREVIOUS_SOURCE_BINARY; current source link failed'
data['current_firmware']['matches_current_source']=False
f.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps(record,ensure_ascii=False))
