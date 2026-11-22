"""Negative control: restore the old UI dirty gate in a temporary source copy.

The real product source is never changed. The host regression must reject
this old behavior after a UI commit acknowledges a newer desired setting.
"""
from pathlib import Path
import json,os,subprocess
root=Path(__file__).resolve().parents[1]
temp=root/'tmp/post_apply_host'
temp.mkdir(parents=True,exist_ok=True)
source=(root/'software/style_control.c').read_text(encoding='utf-8')
old='    configure_next_post();\n    style_write(STYLE_CONTROL_BASE,SYS_COMMAND,SYS_CLAIM_CAMERA);'
assert source.count(old)==1
legacy=temp/'legacy_control.c'
legacy.write_text(source.replace(old,'    if(ui_controls_dirty)configure_next_post();\n    style_write(STYLE_CONTROL_BASE,SYS_COMMAND,SYS_CLAIM_CAMERA);'),encoding='utf-8')
harness=temp/'legacy_test.c'
harness.write_text('#define STYLE_CONTROL_SOURCE '+json.dumps(legacy.as_posix())+'\n'+(root/'sim/post_apply_host_test.c').read_text(),encoding='utf-8')
env=dict(os.environ,TMP=str(temp),TEMP=str(temp))
command=[r'C:\Program Files\mingw64\bin\gcc.exe','-std=c11','-Os','-DSTYLE_CAMERA_HOST_TEST',
         '-ffunction-sections','-fdata-sections','-Wl,--gc-sections','-I',str(root/'software'),str(harness)]
command += [str(root/'software'/f) for f in ('gesture_uart.c','style_input.c','ch9350_touch.c','ch9350_uart.c','style_fps.c')]
exe=temp/'legacy_test.exe'
subprocess.run(command+['-o',str(exe)],env=env,check=True)
result=subprocess.run([str(exe)],env=env,capture_output=True,text=True)
assert result.returncode==2 and 'ui_param_applied==ui_param_generation' in result.stdout,(result.returncode,result.stdout,result.stderr)
print('PASS negative control: old dirty gate loses IPX parameter update after UI ACK; regression detects it')
