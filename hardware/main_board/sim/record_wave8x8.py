"""Read-only source/coverage audit and revision metadata; never invokes tools."""
from pathlib import Path
import hashlib,json,difflib,re

p=Path(__file__).resolve().parents[1]
backup=p/'support/before_wave8x8_20261112'
run=p/'tmp/wave8x8'
old=(backup/'rtl/ti60f225_oob_top.v').read_text()
new=(p/'rtl/ti60f225_oob_top.v').read_text()
old_begin=old.index('// Independent RAW observer.')
new_begin=new.index('// Passive ISP-green 8x8 observer;')
old_end=old.index('wire camera_bayer_y_xor;',old_begin)
new_end=new.index('wire camera_bayer_y_xor;',new_begin)
assert old[:old_begin]==new[:new_begin] and old[old_end:]==new[new_end:],'Unrelated top-level change'
assert '.in_green(isp_g)' in new and '.mode(store_mode_hold)' in new
assert '.mode_60(active_mode_pix==2\'d3)' in new
for name,ports in {
 'wave_roi_stats':{'clk','rst_n','enable','in_vs','in_de','in_green','mode','frame_start','block_valid','block_index','block_mean'},
 'wave_pulse_detector':{'clk','rst_n','enable','frame_start','block_valid','block_index','block_mean','event_toggle','left_toggle','mode_60','event_valid','event_dir','decision_done','debug_state','debug_changed'},
}.items():
 body=re.search(r'\b'+name+r'\s+u_wave_\w+\s*\((.*?)\);',new,re.S).group(1)
 assert set(re.findall(r'\.(\w+)\s*\(',body))==ports,name
assert 'claim_camera' in (p/'software/style_control.c').read_text()
assert 'STYLE_ACTION_WAVE' in (p/'software/style_input.c').read_text()
vectors=json.loads((run/'vectors.json').read_text())
for name in vectors:
 log=(run/(name+'.log')).read_text()
 assert 'PASS WAVE GOLDEN' in log and '** Fatal' not in log and '** Error' not in log,name
frontend=(run/'frontend.log').read_text()
assert 'PASS WAVE FRONTEND' in frontend and frontend.count('PASS WAVE STATS')==4
assert '** Fatal' not in frontend and '** Error' not in frontend
files=['rtl/wave_roi_stats.sv','rtl/wave_pulse_detector.sv','rtl/ti60f225_oob_top.v',
 'software/style_control.c','software/style_input.c','software/style_ui_protocol.h']
record={
 'status':'SOURCE_INTEGRATED_SIMULATION_PASS_COMPILE_DEFERRED_BY_USER',
 'project':str(p),'baseline_status':json.loads((backup/'TRIAL_BUILD_RESULT.json').read_text())['status'],
 'backup':str(backup.relative_to(p)),'reference':'gesture/try_easy_gesture/wave_detector.py',
 'detector_frames':sum(v['frames'] for v in vectors.values()),
 'given_video_frames':sum(v['frames'] for k,v in vectors.items() if k!='integer_edges'),
 'events':{k:v['events'] for k,v in vectors.items()},
 'frontend_cases':['1920x1080 patterned','1920x1080 white','1280x720 patterned','854x480 patterned cropped to848'],
 'top_level_static_contract':'PASS; only observer block differs from backup; ports and ISP source checked',
 'integrated_top_syntax_signoff':'DEFERRED: standalone command had package dependency order error; no complete design compilation',
 'explicit_srl8_instances':131,'declared_register_bits_before_synthesis':349,
 'resource_numbers_are':'structural source counts; not synthesis or routed area results',
 'full_build_started':False,'programmed':False,'compile_deferred_by_user':True,
 'source_sha256':{f:hashlib.sha256((p/f).read_bytes()).hexdigest() for f in files},
 'limitations':['no camera runtime acceptance','no full synthesis or timing signoff','golden FSM comparison uses mode_60=0'],
}
(run/'WAVE8X8_RESULT.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(run/'top_observer.diff').write_text(''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='before_wave8x8',tofile='current')),encoding='utf-8')
f=p/'TRIAL_BUILD_RESULT.json';data=json.loads(f.read_text())
data['status']=record['status'];data['current_build_available']=False
data['source_changed_after_last_build']=True;data['compile_deferred_by_user']=True
data['pending_changes']=['2026-11-11 UI fixes retained','2026-11-12 ISP-green 8x8 occluder sweep integration']
data['wave8x8_20261112']=record
f.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'status':record['status'],'frames':record['detector_frames'],'frontend_cases':4,'observer_only_top_change':True},ensure_ascii=False))
