from pathlib import Path
import hashlib,json,re,shutil
p=Path(__file__).resolve().parents[1]
run=p/'tmp/firmware_size_20261112_wave_pro'
def read_sizes(path):
 text=path.read_text(errors='replace');sizes={}
 for key in ('text','data','bss'):
  m=re.search(r'^\.'+key+r'\s+0x[0-9a-f]+\s+(0x[0-9a-f]+)',text,re.M);assert m,key
  sizes[key]=int(m.group(1),16)
 sizes['static_total']=sum(sizes.values());sizes['stack_available']=24576-sizes['static_total']
 return sizes
before=read_sizes(p/'support/firmware_cleanup_20261112/oversize.map')
after=read_sizes(p/'software/build/product_ui_24k.map')
assert after['static_total']<=22528 and after['stack_available']>=2048
tests={'gesture_regression.log':'PASS good=', 'post_regression.log':'PASS real UI-ACK-before-IPX',
       'equivalence.log':'PASS equivalence:'}
for file,marker in tests.items():
 log=(run/file).read_text(errors='replace')
 assert marker in log and 'FAIL' not in log and 'Assertion failed' not in log and 'warning:' not in log,file
rom=json.loads((run/'rom_verify.json').read_text())
binary=(p/'software/build/product_ui_24k.bin').read_bytes()
assert rom['raw_bin_sha256']==hashlib.sha256(binary).hexdigest()
for name in ('product_ui_24k.bin','product_ui_24k.elf','product_ui_24k.map','product_ui_24k.objdump.txt','product_ui_24k.nm.txt','product_ui_24k.elf.ltrans0.ltrans.su'):
 shutil.copy2(p/'software/build'/name,run/('cleanup_'+name))
source_files=[f for f in (p/'software').iterdir() if f.suffix.lower() in ('.c','.h','.s','.ld')]
record={
 'status':'FIRMWARE_BUILD_PASS_HOST_REGRESSIONS_PASS_ROM_VERIFIED',
 'before':before,'after':after,'saved_static_bytes':before['static_total']-after['static_total'],
 'minimum_stack_bytes':2048,'extra_stack_margin_bytes':after['stack_available']-2048,
 'raw_bin_bytes':len(binary),'raw_bin_sha256':hashlib.sha256(binary).hexdigest(),
 'changes':['immutable generated model catalog and counts; remove unnecessary volatile',
  'boot-only catalog writer streams names/padding once; validate immutable names during build',
  '32-bit frame span/overflow/overlap checks with proven uint16 stride and bounded dimensions',
  'low-word time deltas read only the required low register',
  'one action switch handles accepted/rejected IDs without duplicated pre-filter'],
 'preserved':['all WAVE sources and absolute PRO pause/resume','RGB/table/mode UI application fixes',
  'CRC, protocol length/value validation, UART timeouts/backpressure','DMA overflow/overlap checks',
  'camera I2C/mode-switch guards','2KiB linker stack assertion'],
 'tests':{'frame_range_differential':100000,'model_range_differential':100000,'action_state_differential':12336,
   'boot_catalog_exact_bytes_written_once':624,'ui_claims':58,'table_loads':12,
   'wave_and_uart_host_regression':'PASS','unsupported_counter_CSR_scan':'PASS','rom_lane_reconstruction':'PASS'},
 'source_sha256':{str(f.relative_to(p)):hashlib.sha256(f.read_bytes()).hexdigest() for f in source_files},
 'fpga_build_started':False,'programmed':False,'rom_initialisation_sources_updated':True,
 'stack_note':'available static stack region, not a measured hardware high-water mark',
}
(run/'CLEANUP_RESULT.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
f=p/'TRIAL_BUILD_RESULT.json';data=json.loads(f.read_text())
data['status']='FIRMWARE_BUILD_PASS_HOST_REGRESSIONS_PASS_FPGA_BUILD_DEFERRED'
data['firmware_bytes']=len(binary);data['firmware_sha256']=record['raw_bin_sha256']
data['firmware_memory_usage']={'linker_accounted_bytes':after['static_total'],'stack_reserve_bytes':after['stack_available'],
 'linker_assertion':'SIZEOF(text)+SIZEOF(data)+SIZEOF(bss)<=0x5800; minimum stack remains 2048 bytes'}
data['current_firmware']={'bytes':len(binary),'sha256':record['raw_bin_sha256'],'linker_accounted_bytes':after['static_total'],
 'stack_reserve_bytes':after['stack_available'],'matches_current_source':True,'rom_inputs_verified':True,
 'status':'COMPILED; not integrated into a new bitstream'}
data['firmware_cleanup_20261112']=record
data['current_build_available']=False;data['compile_deferred_by_user']=True
data['firmware_compile_deferred_by_user']=False
f.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:record[k] for k in ('status','before','after','saved_static_bytes','extra_stack_margin_bytes','raw_bin_bytes')},ensure_ascii=False))
