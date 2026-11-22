#!/usr/bin/env python3
"""QA for this debug App only; requires emulator and forwarded HTTP/CDP/UDP ports."""
import argparse, json, subprocess, time, urllib.request
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--adb',default='adb');p.add_argument('--output',type=Path,default=Path('/tmp/ti60-toolchain/lifecycle.json'));a=p.parse_args()
base=Path(__file__).resolve().parent

def adb(*args): return subprocess.run([a.adb,'-s','emulator-5554',*args],check=True,capture_output=True,text=True).stdout

def evaluate(expr):
 out=subprocess.run(['node',str(base/'webview_eval.mjs'),expr],check=True,capture_output=True,text=True)
 return json.loads(out.stdout)['result']['value']

def status():
 request=urllib.request.Request('http://127.0.0.1:18080/api/status',headers={'Host':'127.0.0.1:8080'})
 return json.load(urllib.request.urlopen(request,timeout=5))

def wait(test,seconds=8):
 until=time.monotonic()+seconds
 while time.monotonic()<until:
  s=status()
  if test(s):return s
  time.sleep(.2)
 raise RuntimeError('condition not met: '+json.dumps(s,ensure_ascii=False))

def start(sim): return evaluate("post('/api/session',"+json.dumps(dict(action='start',board='10.0.2.2',port=5001,simulation=sim,timeout_ms=100))+")")

report={}
evaluate("document.fullscreenElement?document.exitFullscreen().then(()=>true):true")
start(True);wait(lambda s:s['complete']>10)
adb('shell','settings','put','system','user_rotation','1');time.sleep(1)
report['rotation']=evaluate("fetch('/api/status').then(s=>s.json()).then(s=>({status:s,image:{width:document.getElementById('video').naturalWidth,height:document.getElementById('video').naturalHeight},viewport:{width:innerWidth,height:innerHeight}}))")
adb('shell','input','keyevent','3');report['paused']=wait(lambda s:not s['running'])
adb('shell','am','start','-n','com.efinity.ti60/.MainActivity');report['resumed']=wait(lambda s:s['running'] and s['age_ms'] is not None and s['age_ms']<200)
start(False);wait(lambda s:s['running'])
adb('shell','svc','wifi','disable');report['wifi_lost']=wait(lambda s:not s['running'])
adb('shell','svc','wifi','enable');report['wifi_restored']=wait(lambda s:s['running'],20)
subprocess.run(['python3',str(base/'mjpeg_v2_source.py'),'--host','127.0.0.1','--port','15001','--seconds','.1','--report','/tmp/ti60-toolchain/lifecycle-source.json'],check=True,capture_output=True)
report['stalled']=wait(lambda s:s['has_frame'] and s['age_ms']>1200)
report['stalled_image']=evaluate("({width:document.getElementById('video').naturalWidth,height:document.getElementById('video').naturalHeight})")
start(True);wait(lambda s:s['complete']>10)
report['fullscreen']=evaluate("document.getElementById('viewer').requestFullscreen().then(()=>({fullscreen:!!document.fullscreenElement}))")
a.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'output':str(a.output),'paused':not report['paused']['running'],'resumed':report['resumed']['running'],'wifi_recovered':report['wifi_restored']['running'],'stalled':report['stalled']['state'],'image':report['stalled_image'],'fullscreen':report['fullscreen']},ensure_ascii=False,indent=2))
