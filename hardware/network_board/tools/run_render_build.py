"""Run one owned build with bounded routing time and archive its evidence."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import time

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('tag')
p.add_argument('--minutes', type=float, default=20)
p.add_argument('--route-minutes', type=float, default=8)
p.add_argument('--pnr-only',action='store_true')
args = p.parse_args()
if not re.fullmatch(r'[a-z0-9_]+', args.tag):
    raise SystemExit('invalid tag')
dest = root / 'build/render_takeover_20261011' / args.tag
dest.mkdir(parents=True, exist_ok=False)
files = list((root / 'rtl').rglob('*')) + list((root / 'software').rglob('*'))
files += [root / n for n in ['ti60f225_oob.xml', 'ti60f225_oob.peri.xml', 'ti60f225_oob.sdc']]
manifest = {str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest()
            for f in files if f.is_file()}
(dest / 'source_hashes.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
for f in files:
    if f.is_file():
        snapshot=dest/'source'/f.relative_to(root)
        snapshot.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(f,snapshot)
start = time.monotonic()
wall_start=time.time()
route_started=None
last_report = 0
reason = None
with (dest / 'driver.log').open('w', encoding='utf-8') as output:
    proc = subprocess.Popen(['cmd.exe', '/d', '/c', 'tools\\run_render_pnr.bat' if args.pnr_only else 'compile.bat'], cwd=root,
                            stdout=output, stderr=subprocess.STDOUT)
    print(f'Owned build PID={proc.pid}, tag={args.tag}', flush=True)
    while proc.poll() is None:
        elapsed = time.monotonic() - start
        routing=root/'outflow/ti60f225_oob.route.out'
        plateau=False
        if routing.exists() and routing.stat().st_mtime>=wall_start:
            if route_started is None:route_started=time.monotonic()
            progress=re.findall(r'Iter\s+(\d+): overlap=(\d+)',routing.read_text(encoding='utf-8',errors='replace'))
            recent=[int(v) for _,v in progress[-6:]]
            # Near-zero conflicts can oscillate while the router repairs the
            # final nets; keep the hard time limit instead of treating 1->2 as
            # a congestion plateau.
            plateau=len(recent)==6 and recent[0]>100 and min(recent)>=0.98*recent[0] and elapsed>=480
        route_limit=route_started is not None and time.monotonic()-route_started>args.route_minutes*60
        if elapsed > args.minutes * 60 or route_limit or plateau:
            reason = ('routing plateau' if plateau else 'routing time limit' if route_limit else 'build time limit')+'; no bit accepted'
            # The PID belongs to the process started directly above. Never
            # enumerate or terminate other engineers\' tool processes.
            subprocess.run(['taskkill.exe', '/PID', str(proc.pid), '/T', '/F'],
                           stdout=output, stderr=subprocess.STDOUT, check=False)
            proc.wait()
            break
        if elapsed - last_report >= 60:
            log = routing if route_started is not None else root / ('outflow/ti60f225_oob.place.out' if args.pnr_only else 'build_compile.log')
            tail = log.read_text(encoding='utf-8', errors='replace')[-1600:] if log.exists() else ''
            lines = [s for s in tail.splitlines() if s.strip()]
            print(f'{elapsed/60:.1f} min: ' + (' | '.join(lines[-3:])[:450]), flush=True)
            last_report = elapsed
        time.sleep(2)
result = {'exit_code': proc.returncode, 'seconds': time.monotonic()-start, 'stopped_reason': reason,
          'routing_seconds':None if route_started is None else time.monotonic()-route_started}
for path in [root/'build_compile.log', root/'build_pnr.log',root/'build_pgm.log',root/'build_accept.json', root/'build/build_inputs.json',root/'build/pnr_reuse.json']:
    if path.exists(): shutil.copy2(path, dest/path.name)
out = dest/'outflow'
out.mkdir()
artifact_times={}
for f in (root/'outflow').iterdir():
    if f.is_file() and (f.suffix in ['.rpt', '.log', '.out', '.sdc', '.xml', '.bit','.vdb','.place','.route','.csv'] or f.name.endswith('.map.v')):
        shutil.copy2(f, out/f.name)
        artifact_times[f.name]={'mtime':f.stat().st_mtime,'from_this_round':f.stat().st_mtime>=wall_start}
(dest/'artifact_times.json').write_text(json.dumps(artifact_times,indent=2),encoding='utf-8')
(dest/'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps(result), flush=True)
raise SystemExit(proc.returncode if not reason else 124)
